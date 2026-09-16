// SPDX-License-Identifier: MIT
pragma solidity ^0.8.37;

import {TickMath} from "./TickMath.sol";
import {IERC20Minimal} from "../interfaces/IERC20Minimal.sol";

/// @title MockUniswapV3Pool (simplified)
/// @notice A simplified concentrated-liquidity AMM: liquidity providers pick
///         a [tickLower, tickUpper) price range, and only ranges covering
///         the current price are "active" and earn/absorb trade flow.
/// @dev Simplifications vs real Uniswap v3, stated explicitly so this is
///      never mistaken for production-precision code:
///        - WAD (1e18) fixed point instead of Q64.96 (see TickMath.sol)
///        - No fee-growth-per-position accounting — this pool charges a
///          flat `feeBps` that stays in the pool as extra output (LPs
///          benefit pro-rata via reserves growth, not via a claimable
///          fee-growth counter like real v3)
///        - No tick bitmap; initialized ticks are tracked in a dynamic
///          array and scanned linearly. Fine for a handful of positions in
///          a demo/test environment, not for mainnet gas costs.
///        - Tokens are pulled via `transferFrom` up front (no callback
///          pattern / flash-swap support)
///      Deployed as an arb/MEV simulation target alongside
///      `MockUniswapV2Pool`, so a scanner can compare AMM designs against
///      the same oracle-priced asset.
contract MockUniswapV3Pool {
    using TickMath for uint256;

    IERC20Minimal public immutable token0;
    IERC20Minimal public immutable token1;
    uint256 public immutable feeBps;
    int24 public immutable tickSpacing;

    uint256 public sqrtPriceCurrent; // WAD-scaled sqrt(token1/token0)
    int24 public currentTick;
    uint256 public liquidity; // active liquidity covering currentTick

    struct TickInfo {
        uint256 liquidityGross; // total liquidity referencing this tick (for cleanup)
        int256 liquidityNet; // net liquidity added when crossing left-to-right (increasing tick)
        bool initialized;
    }

    mapping(int24 => TickInfo) public ticks;
    int24[] internal _initializedTicks; // unsorted; linear-scanned (demo scale only)

    struct Position {
        uint256 liquidity;
    }

    // keccak256(owner, tickLower, tickUpper) => Position
    mapping(bytes32 => Position) public positions;

    uint256 internal constant MAX_SWAP_STEPS = 64;

    bool private _locked;

    event Mint(address indexed owner, int24 tickLower, int24 tickUpper, uint256 liquidityDelta, uint256 amount0, uint256 amount1);
    event Burn(address indexed owner, int24 tickLower, int24 tickUpper, uint256 liquidityDelta, uint256 amount0, uint256 amount1);
    event Swap(address indexed sender, bool zeroForOne, uint256 amountIn, uint256 amountOut, uint256 sqrtPriceAfter, int24 tickAfter);

    error ZeroAddress();
    error IdenticalTokens();
    error InvalidTickRange();
    error ZeroLiquidity();
    error InsufficientOutputAmount();
    error Reentrancy();
    error FeeTooHigh();
    error InsufficientPositionLiquidity();
    error TooManySwapSteps();

    modifier nonReentrant() {
        if (_locked) revert Reentrancy();
        _locked = true;
        _;
        _locked = false;
    }

    /// @param _initialTick Starting tick — sets the pool's initial price.
    constructor(
        address _token0,
        address _token1,
        uint256 _feeBps,
        int24 _tickSpacing,
        int24 _initialTick
    ) {
        if (_token0 == address(0) || _token1 == address(0)) revert ZeroAddress();
        if (_token0 == _token1) revert IdenticalTokens();
        if (_feeBps >= 10_000) revert FeeTooHigh();

        token0 = IERC20Minimal(_token0);
        token1 = IERC20Minimal(_token1);
        feeBps = _feeBps;
        tickSpacing = _tickSpacing;

        currentTick = _initialTick;
        sqrtPriceCurrent = TickMath.getSqrtPriceAtTick(_initialTick);
    }

    // ----------------------------------------------------------------
    // Liquidity provision
    // ----------------------------------------------------------------

    /// @notice Adds `liquidityDelta` units of liquidity to the range
    ///         [tickLower, tickUpper). Caller must approve both tokens
    ///         for the (over-)estimated amount beforehand.
    function mint(
        int24 tickLower,
        int24 tickUpper,
        uint256 liquidityDelta
    ) external nonReentrant returns (uint256 amount0, uint256 amount1) {
        if (tickLower >= tickUpper) revert InvalidTickRange();
        if (liquidityDelta == 0) revert ZeroLiquidity();

        (amount0, amount1) = _amountsForLiquidity(tickLower, tickUpper, liquidityDelta, true);

        if (amount0 > 0) _pullToken(token0, amount0);
        if (amount1 > 0) _pullToken(token1, amount1);

        _updateTick(tickLower, liquidityDelta, true, true);
        _updateTick(tickUpper, liquidityDelta, false, true);

        bytes32 key = _positionKey(msg.sender, tickLower, tickUpper);
        positions[key].liquidity += liquidityDelta;

        if (currentTick >= tickLower && currentTick < tickUpper) {
            liquidity += liquidityDelta;
        }

        emit Mint(msg.sender, tickLower, tickUpper, liquidityDelta, amount0, amount1);
    }

    /// @notice Removes `liquidityDelta` units from the caller's position in
    ///         [tickLower, tickUpper) and returns the underlying tokens.
    function burn(
        int24 tickLower,
        int24 tickUpper,
        uint256 liquidityDelta
    ) external nonReentrant returns (uint256 amount0, uint256 amount1) {
        bytes32 key = _positionKey(msg.sender, tickLower, tickUpper);
        if (positions[key].liquidity < liquidityDelta) revert InsufficientPositionLiquidity();

        (amount0, amount1) = _amountsForLiquidity(tickLower, tickUpper, liquidityDelta, false);

        positions[key].liquidity -= liquidityDelta;

        _updateTick(tickLower, liquidityDelta, true, false);
        _updateTick(tickUpper, liquidityDelta, false, false);

        if (currentTick >= tickLower && currentTick < tickUpper) {
            liquidity -= liquidityDelta;
        }

        if (amount0 > 0) require(token0.transfer(msg.sender, amount0), "transfer0 failed");
        if (amount1 > 0) require(token1.transfer(msg.sender, amount1), "transfer1 failed");

        emit Burn(msg.sender, tickLower, tickUpper, liquidityDelta, amount0, amount1);
    }

    // ----------------------------------------------------------------
    // Swapping
    // ----------------------------------------------------------------

    /// @dev Bundles the swap loop's mutable state into one struct so the
    ///      EVM only needs a single stack slot (a memory pointer) for it,
    ///      instead of five-plus separate local variables. This is what
    ///      actually fixes a "stack too deep" error here — reaching for
    ///      `--via-ir` would also work, but restructuring the variables is
    ///      the more direct fix the compiler itself suggests, and keeps
    ///      the contract compiling under the default (non-IR) pipeline.
    struct SwapState {
        uint256 amountRemaining;
        uint256 amountOut;
        uint256 sqrtCurrent;
        int24 tick;
        uint256 activeLiquidity;
    }

    /// @notice Swaps an exact input amount, walking across tick boundaries
    ///         as needed until the full amount is consumed.
    /// @param zeroForOne  true = selling token0 for token1 (price decreases)
    /// @param amountIn    exact amount of the input token to sell
    /// @param minAmountOut slippage protection on the output amount
    function swap(
        bool zeroForOne,
        uint256 amountIn,
        uint256 minAmountOut,
        address to
    ) external nonReentrant returns (uint256 amountOut) {
        if (amountIn == 0) revert ZeroLiquidity();

        IERC20Minimal tokenIn = zeroForOne ? token0 : token1;
        IERC20Minimal tokenOut = zeroForOne ? token1 : token0;

        _pullToken(tokenIn, amountIn);

        // Apply the flat fee up front: fee stays in the pool (accrues to LPs
        // via reserve growth), only the post-fee amount is actually swapped.
        uint256 amountInAfterFee = amountIn - (amountIn * feeBps) / 10_000;

        SwapState memory s = SwapState({
            amountRemaining: amountInAfterFee,
            amountOut: 0,
            sqrtCurrent: sqrtPriceCurrent,
            tick: currentTick,
            activeLiquidity: liquidity
        });

        for (uint256 step; step < MAX_SWAP_STEPS; step++) {
            if (s.amountRemaining == 0) break;
            if (!_swapStep(s, zeroForOne)) break;
        }

        if (s.amountRemaining > 0) {
            // Refund the unfilled portion, INCLUDING a proportional refund
            // of the fee charged on it. A fee should only apply to volume
            // that actually executed — the earlier version of this
            // contract charged the full fee up front and only refunded
            // the already-fee-adjusted leftover, which meant a swap that
            // filled 0% (e.g. against a pool with no liquidity at all)
            // still cost the trader the fee for nothing. Caught by
            // test_swap_withNoLiquidity_refundsAndReturnsZero actually
            // running against a live pool, not found by inspection.
            uint256 consumedAfterFee = amountInAfterFee - s.amountRemaining;
            uint256 consumedPreFee = (consumedAfterFee * 10_000) / (10_000 - feeBps);
            if (consumedPreFee > amountIn) consumedPreFee = amountIn; // integer-division rounding guard
            uint256 refundAmount = amountIn - consumedPreFee;
            if (refundAmount > 0) {
                require(tokenIn.transfer(msg.sender, refundAmount), "refund failed");
            }
        }

        amountOut = s.amountOut;
        if (amountOut < minAmountOut) revert InsufficientOutputAmount();

        sqrtPriceCurrent = s.sqrtCurrent;
        currentTick = s.tick;
        liquidity = s.activeLiquidity;

        require(tokenOut.transfer(to, amountOut), "transfer out failed");

        emit Swap(msg.sender, zeroForOne, amountIn, amountOut, s.sqrtCurrent, s.tick);
    }

    /// @dev Advances `s` by one swap step, mutating it in place. Returns
    ///      false when there's nothing left to do (no liquidity anywhere
    ///      further in this direction) so the caller's loop should stop;
    ///      true otherwise (whether or not a tick was crossed).
    ///      Split out from `swap()` specifically to keep that function's
    ///      stack frame small — see `SwapState`.
    function _swapStep(SwapState memory s, bool zeroForOne) internal view returns (bool) {
        if (s.activeLiquidity == 0) {
            // No liquidity active at this price — jump straight to the next
            // initialized tick in the swap direction with no amount
            // consumed, then cross it.
            (int24 nextTick, bool found) = _nextInitializedTick(s.tick, zeroForOne);
            if (!found) return false; // no more liquidity anywhere in this direction
            s.tick = nextTick;
            s.sqrtCurrent = TickMath.getSqrtPriceAtTick(s.tick);
            s.activeLiquidity = _crossTick(s.tick, zeroForOne, s.activeLiquidity);
            return true;
        }

        (int24 boundaryTick, bool boundaryFound) = _nextInitializedTick(s.tick, zeroForOne);
        uint256 sqrtTarget = boundaryFound
            ? TickMath.getSqrtPriceAtTick(boundaryTick)
            : (zeroForOne ? TickMath.getSqrtPriceAtTick(TickMath.MIN_TICK) : TickMath.getSqrtPriceAtTick(TickMath.MAX_TICK));

        (uint256 sqrtNext, uint256 amountInStep, uint256 amountOutStep, bool reachedTarget) =
            _computeSwapStep(s.sqrtCurrent, sqrtTarget, s.activeLiquidity, s.amountRemaining, zeroForOne);

        s.sqrtCurrent = sqrtNext;
        s.amountRemaining -= amountInStep;
        s.amountOut += amountOutStep;

        if (reachedTarget && boundaryFound) {
            s.tick = boundaryTick;
            s.activeLiquidity = _crossTick(s.tick, zeroForOne, s.activeLiquidity);
            return true;
        }

        // Fully filled within this range, no need to cross — signal the
        // caller's loop to stop by driving amountRemaining to 0 is already
        // done by _computeSwapStep in this branch, but return false too so
        // the loop doesn't spend an extra iteration checking it.
        return false;
    }

    // ----------------------------------------------------------------
    // Internal: swap step math
    // ----------------------------------------------------------------

    /// @dev Computes one swap step within a single tick range (no crossing).
    ///      Formulas (WAD fixed point, price = token1/token0):
    ///        zeroForOne (token0 in, price decreases):
    ///          sqrtNext = L * sqrtCurrent / (L + amountIn * sqrtCurrent)
    ///          amountOut(token1) = L * (sqrtCurrent - sqrtNext)
    ///        !zeroForOne (token1 in, price increases):
    ///          sqrtNext = sqrtCurrent + amountIn / L
    ///          amountOut(token0) = L * (1/sqrtCurrent - 1/sqrtNext)
    ///      If the unclamped sqrtNext would cross sqrtTarget, clamp to
    ///      sqrtTarget and recompute the amountIn actually consumed.
    function _computeSwapStep(
        uint256 sqrtCurrent,
        uint256 sqrtTarget,
        uint256 L,
        uint256 amountRemaining,
        bool zeroForOne
    ) internal pure returns (uint256 sqrtNext, uint256 amountInStep, uint256 amountOutStep, bool reachedTarget) {
        if (zeroForOne) {
            uint256 denom = L + TickMath.wmul(amountRemaining, sqrtCurrent);
            uint256 sqrtNextUnclamped = TickMath.wdiv(TickMath.wmul(L, sqrtCurrent), denom);

            if (sqrtNextUnclamped <= sqrtTarget) {
                sqrtNext = sqrtTarget;
                reachedTarget = true;
                amountInStep = TickMath.wmul(
                    L,
                    TickMath.reciprocalWad(sqrtNext) - TickMath.reciprocalWad(sqrtCurrent)
                );
            } else {
                sqrtNext = sqrtNextUnclamped;
                reachedTarget = false;
                amountInStep = amountRemaining;
            }
            amountOutStep = TickMath.wmul(L, sqrtCurrent - sqrtNext);
        } else {
            uint256 sqrtNextUnclamped = sqrtCurrent + TickMath.wdiv(amountRemaining, L);

            if (sqrtNextUnclamped >= sqrtTarget) {
                sqrtNext = sqrtTarget;
                reachedTarget = true;
                amountInStep = TickMath.wmul(L, sqrtNext - sqrtCurrent);
            } else {
                sqrtNext = sqrtNextUnclamped;
                reachedTarget = false;
                amountInStep = amountRemaining;
            }
            amountOutStep = TickMath.wmul(
                L,
                TickMath.reciprocalWad(sqrtCurrent) - TickMath.reciprocalWad(sqrtNext)
            );
        }
    }

    /// @dev Applies a tick's liquidityNet when price crosses it, following
    ///      the convention that liquidityNet is defined for crossing
    ///      left-to-right (increasing tick): add net when moving up
    ///      (!zeroForOne), subtract net when moving down (zeroForOne).
    function _crossTick(int24 tick, bool zeroForOne, uint256 activeLiquidity) internal view returns (uint256) {
        int256 net = ticks[tick].liquidityNet;
        int256 signedLiquidity = int256(activeLiquidity);
        signedLiquidity = zeroForOne ? signedLiquidity - net : signedLiquidity + net;
        // Liquidity should never legitimately go negative if ticks were
        // updated consistently in mint/burn — an explicit check here
        // (rather than relying on the int256->uint256 cast, which does NOT
        // revert on negative values) turns a silent accounting bug into a
        // loud, debuggable one.
        require(signedLiquidity >= 0, "negative liquidity after cross");
        return uint256(signedLiquidity);
    }

    // ----------------------------------------------------------------
    // Internal: liquidity <-> amounts
    // ----------------------------------------------------------------

    /// @dev Standard v3 range-liquidity formulas, WAD fixed point:
    ///        price below range:  all token0
    ///        price above range:  all token1
    ///        price inside range: split at current price
    function _amountsForLiquidity(
        int24 tickLower,
        int24 tickUpper,
        uint256 L,
        bool /* roundUp - omitted for simplicity in this mock */
    ) internal view returns (uint256 amount0, uint256 amount1) {
        uint256 sqrtLower = TickMath.getSqrtPriceAtTick(tickLower);
        uint256 sqrtUpper = TickMath.getSqrtPriceAtTick(tickUpper);
        uint256 sqrtP = sqrtPriceCurrent;

        if (currentTick < tickLower) {
            amount0 = TickMath.wmul(L, TickMath.reciprocalWad(sqrtLower) - TickMath.reciprocalWad(sqrtUpper));
        } else if (currentTick >= tickUpper) {
            amount1 = TickMath.wmul(L, sqrtUpper - sqrtLower);
        } else {
            amount0 = TickMath.wmul(L, TickMath.reciprocalWad(sqrtP) - TickMath.reciprocalWad(sqrtUpper));
            amount1 = TickMath.wmul(L, sqrtP - sqrtLower);
        }
    }

    // ----------------------------------------------------------------
    // Internal: tick bookkeeping (linear-scan, demo scale)
    // ----------------------------------------------------------------

    /// @param isLower Whether `tick` is the lower bound of the position
    ///        being touched (lower ticks get +delta net, upper ticks -delta,
    ///        per the standard "net liquidity crossing left-to-right"
    ///        convention).
    /// @param adding  true for mint (add liquidity), false for burn (remove
    ///        it). Kept as a separate flag from `isLower` — conflating the
    ///        two was an earlier bug here: burn needs to invert both
    ///        liquidityGross *and* liquidityNet relative to mint, not just
    ///        flip which tick is "lower".
    function _updateTick(int24 tick, uint256 liquidityDelta, bool isLower, bool adding) internal {
        TickInfo storage info = ticks[tick];

        if (!info.initialized) {
            info.initialized = true;
            _initializedTicks.push(tick);
        }

        int256 signedDelta = isLower ? int256(liquidityDelta) : -int256(liquidityDelta);

        if (adding) {
            info.liquidityGross += liquidityDelta;
            info.liquidityNet += signedDelta;
        } else {
            info.liquidityGross -= liquidityDelta;
            info.liquidityNet -= signedDelta;
        }

        if (info.liquidityGross == 0) {
            info.initialized = false;
            _removeFromInitializedList(tick);
        }
    }

    function _removeFromInitializedList(int24 tick) internal {
        uint256 len = _initializedTicks.length;
        for (uint256 i; i < len; i++) {
            if (_initializedTicks[i] == tick) {
                _initializedTicks[i] = _initializedTicks[len - 1];
                _initializedTicks.pop();
                break;
            }
        }
    }

    /// @dev Linear scan for the nearest initialized tick strictly beyond
    ///      `fromTick` in the swap direction. O(n) in number of initialized
    ///      ticks — fine for a handful of positions, not mainnet-scale.
    function _nextInitializedTick(int24 fromTick, bool zeroForOne) internal view returns (int24 result, bool found) {
        uint256 len = _initializedTicks.length;
        bool haveCandidate;

        for (uint256 i; i < len; i++) {
            int24 t = _initializedTicks[i];
            if (zeroForOne) {
                if (t < fromTick && (!haveCandidate || t > result)) {
                    result = t;
                    haveCandidate = true;
                }
            } else {
                if (t > fromTick && (!haveCandidate || t < result)) {
                    result = t;
                    haveCandidate = true;
                }
            }
        }
        found = haveCandidate;
    }

    function _positionKey(address owner, int24 tickLower, int24 tickUpper) internal pure returns (bytes32) {
        return keccak256(abi.encodePacked(owner, tickLower, tickUpper));
    }

    function _pullToken(IERC20Minimal token, uint256 amount) internal {
        require(token.transferFrom(msg.sender, address(this), amount), "transferFrom failed");
    }

    // ----------------------------------------------------------------
    // Views
    // ----------------------------------------------------------------

    function getInitializedTicks() external view returns (int24[] memory) {
        return _initializedTicks;
    }

    function positionLiquidity(address owner, int24 tickLower, int24 tickUpper) external view returns (uint256) {
        return positions[_positionKey(owner, tickLower, tickUpper)].liquidity;
    }
}
