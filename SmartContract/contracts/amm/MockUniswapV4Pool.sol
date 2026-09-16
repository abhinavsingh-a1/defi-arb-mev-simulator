// SPDX-License-Identifier: MIT
pragma solidity ^0.8.37;

import {TickMath} from "./TickMath.sol";
import {IERC20Minimal} from "../interfaces/IERC20Minimal.sol";
import {IHooks} from "../hooks/IHooks.sol";

/// @title MockUniswapV4Pool (simplified)
/// @notice Same concentrated-liquidity engine as `MockUniswapV3Pool`, with
///         v4's headline feature layered on top: a hooks contract that can
///         plug into the pool's lifecycle and, for swaps, override the fee
///         dynamically per-trade.
/// @dev Explicitly NOT a faithful reproduction of real Uniswap v4's
///      architecture — see the two simplifications below, both stated so
///      this is never mistaken for production-grade or bit-exact v4:
///
///      1. Real v4 is a *singleton*: one `PoolManager` contract holds every
///         pool's state, and swaps settle via "flash accounting" (a
///         lock/unlock callback pattern with net deltas settled at the end
///         of a transaction, avoiding token transfers between every step).
///         This mock keeps the one-pool-per-contract model from
///         `MockUniswapV3Pool` and settles tokens immediately via
///         `transferFrom`/`transfer`, same as v2/v3 here. The singleton
///         design is a gas/architecture optimization; it doesn't change
///         the AMM math or the hook *concept*, which is what this
///         contract is actually demonstrating.
///      2. Real v4 encodes which hooks a contract implements in its
///         deployed address's low bits (see `IHooks.sol`'s notes). This
///         version always calls every hook and expects a no-op response
///         for callbacks a given hook doesn't use.
contract MockUniswapV4Pool {
    IERC20Minimal public immutable token0;
    IERC20Minimal public immutable token1;
    uint256 public immutable feeBps; // base fee; a hook may override per-swap
    int24 public immutable tickSpacing;
    IHooks public immutable hooks; // address(0) = no hooks

    uint256 public sqrtPriceCurrent; // WAD-scaled sqrt(token1/token0)
    int24 public currentTick;
    uint256 public liquidity; // active liquidity covering currentTick

    struct TickInfo {
        uint256 liquidityGross;
        int256 liquidityNet;
        bool initialized;
    }

    mapping(int24 => TickInfo) public ticks;
    int24[] internal _initializedTicks;

    struct Position {
        uint256 liquidity;
    }

    mapping(bytes32 => Position) public positions;

    uint256 internal constant MAX_SWAP_STEPS = 64;

    bool private _locked;

    event Mint(address indexed owner, int24 tickLower, int24 tickUpper, uint256 liquidityDelta, uint256 amount0, uint256 amount1);
    event Burn(address indexed owner, int24 tickLower, int24 tickUpper, uint256 liquidityDelta, uint256 amount0, uint256 amount1);
    event Swap(address indexed sender, bool zeroForOne, uint256 amountIn, uint256 amountOut, uint256 sqrtPriceAfter, int24 tickAfter, uint256 feeBpsUsed);

    error ZeroAddress();
    error IdenticalTokens();
    error InvalidTickRange();
    error ZeroLiquidity();
    error InsufficientOutputAmount();
    error Reentrancy();
    error FeeTooHigh();
    error InsufficientPositionLiquidity();
    error InvalidHookResponse();

    modifier nonReentrant() {
        if (_locked) revert Reentrancy();
        _locked = true;
        _;
        _locked = false;
    }

    constructor(
        address _token0,
        address _token1,
        uint256 _feeBps,
        int24 _tickSpacing,
        int24 _initialTick,
        address _hooks
    ) {
        if (_token0 == address(0) || _token1 == address(0)) revert ZeroAddress();
        if (_token0 == _token1) revert IdenticalTokens();
        if (_feeBps >= 10_000) revert FeeTooHigh();

        token0 = IERC20Minimal(_token0);
        token1 = IERC20Minimal(_token1);
        feeBps = _feeBps;
        tickSpacing = _tickSpacing;
        hooks = IHooks(_hooks);

        currentTick = _initialTick;
        uint256 initialSqrtPrice = TickMath.getSqrtPriceAtTick(_initialTick);

        if (_hooks != address(0)) {
            bytes4 sel = hooks.beforeInitialize(msg.sender, initialSqrtPrice);
            if (sel != IHooks.beforeInitialize.selector) revert InvalidHookResponse();
        }

        sqrtPriceCurrent = initialSqrtPrice;

        if (_hooks != address(0)) {
            bytes4 sel = hooks.afterInitialize(msg.sender, initialSqrtPrice, _initialTick);
            if (sel != IHooks.afterInitialize.selector) revert InvalidHookResponse();
        }
    }

    // ----------------------------------------------------------------
    // Liquidity provision
    // ----------------------------------------------------------------

    function mint(
        int24 tickLower,
        int24 tickUpper,
        uint256 liquidityDelta
    ) external nonReentrant returns (uint256 amount0, uint256 amount1) {
        if (tickLower >= tickUpper) revert InvalidTickRange();
        if (liquidityDelta == 0) revert ZeroLiquidity();

        if (address(hooks) != address(0)) {
            bytes4 sel = hooks.beforeAddLiquidity(msg.sender, tickLower, tickUpper, liquidityDelta);
            if (sel != IHooks.beforeAddLiquidity.selector) revert InvalidHookResponse();
        }

        (amount0, amount1) = _amountsForLiquidity(tickLower, tickUpper, liquidityDelta);

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

        if (address(hooks) != address(0)) {
            bytes4 sel = hooks.afterAddLiquidity(msg.sender, tickLower, tickUpper, liquidityDelta, amount0, amount1);
            if (sel != IHooks.afterAddLiquidity.selector) revert InvalidHookResponse();
        }
    }

    function burn(
        int24 tickLower,
        int24 tickUpper,
        uint256 liquidityDelta
    ) external nonReentrant returns (uint256 amount0, uint256 amount1) {
        bytes32 key = _positionKey(msg.sender, tickLower, tickUpper);
        if (positions[key].liquidity < liquidityDelta) revert InsufficientPositionLiquidity();

        if (address(hooks) != address(0)) {
            bytes4 sel = hooks.beforeRemoveLiquidity(msg.sender, tickLower, tickUpper, liquidityDelta);
            if (sel != IHooks.beforeRemoveLiquidity.selector) revert InvalidHookResponse();
        }

        (amount0, amount1) = _amountsForLiquidity(tickLower, tickUpper, liquidityDelta);

        positions[key].liquidity -= liquidityDelta;

        _updateTick(tickLower, liquidityDelta, true, false);
        _updateTick(tickUpper, liquidityDelta, false, false);

        if (currentTick >= tickLower && currentTick < tickUpper) {
            liquidity -= liquidityDelta;
        }

        if (amount0 > 0) require(token0.transfer(msg.sender, amount0), "transfer0 failed");
        if (amount1 > 0) require(token1.transfer(msg.sender, amount1), "transfer1 failed");

        emit Burn(msg.sender, tickLower, tickUpper, liquidityDelta, amount0, amount1);

        if (address(hooks) != address(0)) {
            bytes4 sel = hooks.afterRemoveLiquidity(msg.sender, tickLower, tickUpper, liquidityDelta, amount0, amount1);
            if (sel != IHooks.afterRemoveLiquidity.selector) revert InvalidHookResponse();
        }
    }

    // ----------------------------------------------------------------
    // Swapping
    // ----------------------------------------------------------------

    /// @dev Same stack-depth fix as `MockUniswapV3Pool`: loop state lives
    ///      in one memory struct instead of several local variables.
    struct SwapState {
        uint256 amountRemaining;
        uint256 amountOut;
        uint256 sqrtCurrent;
        int24 tick;
        uint256 activeLiquidity;
    }

    function swap(
        bool zeroForOne,
        uint256 amountIn,
        uint256 minAmountOut,
        address to
    ) external nonReentrant returns (uint256 amountOut) {
        if (amountIn == 0) revert ZeroLiquidity();

        IERC20Minimal tokenIn = zeroForOne ? token0 : token1;
        IERC20Minimal tokenOut = zeroForOne ? token1 : token0;

        uint256 effectiveFeeBps = feeBps;
        if (address(hooks) != address(0)) {
            (bytes4 sel, uint256 feeOverrideBps, bool overrideFee) = hooks.beforeSwap(msg.sender, zeroForOne, amountIn);
            if (sel != IHooks.beforeSwap.selector) revert InvalidHookResponse();
            if (overrideFee) {
                if (feeOverrideBps >= 10_000) revert FeeTooHigh();
                effectiveFeeBps = feeOverrideBps;
            }
        }

        _pullToken(tokenIn, amountIn);

        uint256 amountInAfterFee = amountIn - (amountIn * effectiveFeeBps) / 10_000;

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
            // of the fee charged on it — same fix as MockUniswapV3Pool.sol
            // (see its comment here for the full explanation). Applied
            // proactively here since this contract copied the same
            // swap() structure, rather than waiting for the same bug to
            // surface in this pool's own tests.
            uint256 consumedAfterFee = amountInAfterFee - s.amountRemaining;
            uint256 consumedPreFee = (consumedAfterFee * 10_000) / (10_000 - effectiveFeeBps);
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

        emit Swap(msg.sender, zeroForOne, amountIn, amountOut, s.sqrtCurrent, s.tick, effectiveFeeBps);

        if (address(hooks) != address(0)) {
            // Called AFTER all pool storage above is updated, so a hook
            // can read the post-swap state (or just use the amountIn/
            // amountOut it's given directly) and revert the whole
            // transaction — including the transfers above — if it doesn't
            // like the outcome. This is what makes a circuit-breaker hook
            // like `OracleGuardHook` actually work.
            bytes4 sel = hooks.afterSwap(msg.sender, zeroForOne, amountIn, amountOut);
            if (sel != IHooks.afterSwap.selector) revert InvalidHookResponse();
        }
    }

    function _swapStep(SwapState memory s, bool zeroForOne) internal view returns (bool) {
        if (s.activeLiquidity == 0) {
            (int24 nextTick, bool found) = _nextInitializedTick(s.tick, zeroForOne);
            if (!found) return false;
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

        return false;
    }

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
                amountInStep = TickMath.wmul(L, TickMath.reciprocalWad(sqrtNext) - TickMath.reciprocalWad(sqrtCurrent));
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
            amountOutStep = TickMath.wmul(L, TickMath.reciprocalWad(sqrtCurrent) - TickMath.reciprocalWad(sqrtNext));
        }
    }

    function _crossTick(int24 tick, bool zeroForOne, uint256 activeLiquidity) internal view returns (uint256) {
        int256 net = ticks[tick].liquidityNet;
        int256 signedLiquidity = int256(activeLiquidity);
        signedLiquidity = zeroForOne ? signedLiquidity - net : signedLiquidity + net;
        require(signedLiquidity >= 0, "negative liquidity after cross");
        return uint256(signedLiquidity);
    }

    // ----------------------------------------------------------------
    // Internal: liquidity <-> amounts
    // ----------------------------------------------------------------

    function _amountsForLiquidity(
        int24 tickLower,
        int24 tickUpper,
        uint256 L
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
    // Internal: tick bookkeeping
    // ----------------------------------------------------------------

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
