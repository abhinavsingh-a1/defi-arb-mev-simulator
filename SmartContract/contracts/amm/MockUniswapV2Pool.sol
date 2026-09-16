// SPDX-License-Identifier: MIT
pragma solidity ^0.8.37;

import {PoolMath} from "./PoolMath.sol";
import {IERC20Minimal} from "../interfaces/IERC20Minimal.sol";

/// @title MockUniswapV2Pool
/// @notice A standalone, simplified Uniswap-v2-style constant-product pool.
/// @dev Deliberately dependency-free (no OZ ERC20 inheritance for LP shares —
///      internal balance mapping instead) so this repo builds without any
///      package install step. Uses `PoolMath` for all swap-pricing math so
///      the pricing logic is unit-tested independently in `PoolMath.t.sol`.
///      Intended for local Besu deployment as an arb/MEV simulation target —
///      NOT audited, NOT for real funds.
contract MockUniswapV2Pool {
    IERC20Minimal public immutable token0;
    IERC20Minimal public immutable token1;
    uint256 public immutable feeBps; // e.g. 30 = 0.30%

    uint256 public reserve0;
    uint256 public reserve1;

    /// @dev Locked forever in address(0) on first mint, same as Uniswap v2,
    ///      to prevent the "empty pool / totalLiquidity=0" divide-by-zero
    ///      class of attacks on the very first liquidity provider.
    uint256 public constant MINIMUM_LIQUIDITY = 1000;

    uint256 public totalLiquidity;
    mapping(address => uint256) public liquidityOf;

    bool private _locked;

    event Mint(address indexed provider, uint256 amount0, uint256 amount1, uint256 liquidity);
    event Burn(address indexed provider, uint256 amount0, uint256 amount1, uint256 liquidity);
    event Swap(
        address indexed sender,
        address indexed tokenIn,
        uint256 amountIn,
        address tokenOut,
        uint256 amountOut,
        address indexed to
    );
    event Sync(uint256 reserve0, uint256 reserve1);

    error IdenticalTokens();
    error ZeroAddress();
    error ZeroAmount();
    error InsufficientLiquidityMinted();
    error InsufficientLiquidityBurned();
    error InsufficientOutputAmount();
    error InvalidToken();
    error Reentrancy();
    error FeeTooHigh();

    modifier nonReentrant() {
        if (_locked) revert Reentrancy();
        _locked = true;
        _;
        _locked = false;
    }

    constructor(address _token0, address _token1, uint256 _feeBps) {
        if (_token0 == address(0) || _token1 == address(0)) revert ZeroAddress();
        if (_token0 == _token1) revert IdenticalTokens();
        if (_feeBps >= PoolMath.BPS_DENOMINATOR) revert FeeTooHigh();

        token0 = IERC20Minimal(_token0);
        token1 = IERC20Minimal(_token1);
        feeBps = _feeBps;
    }

    // ----------------------------------------------------------------
    // Liquidity provision
    // ----------------------------------------------------------------

    /// @notice Adds liquidity at the caller-specified ratio. Caller must
    ///         have approved this pool for both `amount0Desired` and
    ///         `amount1Desired` beforehand.
    /// @dev For simplicity this mock takes exact amounts rather than
    ///      computing an optimal ratio + slippage bounds like the real
    ///      Uniswap v2 Router does — fine for a simulation target, not
    ///      production LP UX.
    function addLiquidity(
        uint256 amount0Desired,
        uint256 amount1Desired
    ) external nonReentrant returns (uint256 liquidity) {
        if (amount0Desired == 0 || amount1Desired == 0) revert ZeroAmount();

        if (totalLiquidity == 0) {
            liquidity = _sqrt(amount0Desired * amount1Desired) - MINIMUM_LIQUIDITY;
            liquidityOf[address(0)] += MINIMUM_LIQUIDITY;
            totalLiquidity += MINIMUM_LIQUIDITY;
        } else {
            uint256 liquidity0 = (amount0Desired * totalLiquidity) / reserve0;
            uint256 liquidity1 = (amount1Desired * totalLiquidity) / reserve1;
            liquidity = liquidity0 < liquidity1 ? liquidity0 : liquidity1;
        }

        if (liquidity == 0) revert InsufficientLiquidityMinted();

        _pullToken(token0, amount0Desired);
        _pullToken(token1, amount1Desired);

        reserve0 += amount0Desired;
        reserve1 += amount1Desired;

        liquidityOf[msg.sender] += liquidity;
        totalLiquidity += liquidity;

        emit Mint(msg.sender, amount0Desired, amount1Desired, liquidity);
        emit Sync(reserve0, reserve1);
    }

    /// @notice Burns `liquidity` LP shares and returns the underlying tokens
    ///         at the current pool ratio.
    function removeLiquidity(
        uint256 liquidity
    ) external nonReentrant returns (uint256 amount0, uint256 amount1) {
        if (liquidity == 0) revert ZeroAmount();
        if (liquidityOf[msg.sender] < liquidity) revert InsufficientLiquidityBurned();

        amount0 = (liquidity * reserve0) / totalLiquidity;
        amount1 = (liquidity * reserve1) / totalLiquidity;

        if (amount0 == 0 || amount1 == 0) revert InsufficientLiquidityBurned();

        liquidityOf[msg.sender] -= liquidity;
        totalLiquidity -= liquidity;

        reserve0 -= amount0;
        reserve1 -= amount1;

        require(token0.transfer(msg.sender, amount0), "transfer0 failed");
        require(token1.transfer(msg.sender, amount1), "transfer1 failed");

        emit Burn(msg.sender, amount0, amount1, liquidity);
        emit Sync(reserve0, reserve1);
    }

    // ----------------------------------------------------------------
    // Swapping
    // ----------------------------------------------------------------

    /// @notice Swaps an exact input amount of one pool token for the other.
    /// @param tokenIn      Address of token0 or token1 — the token being sold.
    /// @param amountIn     Amount of `tokenIn` to sell. Caller must have approved.
    /// @param minAmountOut Minimum acceptable output (slippage protection).
    /// @param to           Recipient of the output tokens.
    function swap(
        address tokenIn,
        uint256 amountIn,
        uint256 minAmountOut,
        address to
    ) external nonReentrant returns (uint256 amountOut) {
        if (amountIn == 0) revert ZeroAmount();
        if (to == address(0)) revert ZeroAddress();

        bool isToken0 = tokenIn == address(token0);
        if (!isToken0 && tokenIn != address(token1)) revert InvalidToken();

        (uint256 reserveIn, uint256 reserveOut) = isToken0
            ? (reserve0, reserve1)
            : (reserve1, reserve0);

        amountOut = PoolMath.getAmountOut(amountIn, reserveIn, reserveOut, feeBps);
        if (amountOut < minAmountOut) revert InsufficientOutputAmount();

        IERC20Minimal tokenInErc = isToken0 ? token0 : token1;
        IERC20Minimal tokenOutErc = isToken0 ? token1 : token0;

        _pullToken(tokenInErc, amountIn);

        if (isToken0) {
            reserve0 += amountIn;
            reserve1 -= amountOut;
        } else {
            reserve1 += amountIn;
            reserve0 -= amountOut;
        }

        require(tokenOutErc.transfer(to, amountOut), "transfer out failed");

        emit Swap(msg.sender, tokenIn, amountIn, address(tokenOutErc), amountOut, to);
        emit Sync(reserve0, reserve1);
    }

    // ----------------------------------------------------------------
    // Views — thin wrappers around PoolMath for off-chain scanners
    // ----------------------------------------------------------------

    function getReserves() external view returns (uint256, uint256) {
        return (reserve0, reserve1);
    }

    function quote(
        address tokenIn,
        uint256 amountIn
    ) external view returns (uint256 amountOut) {
        bool isToken0 = tokenIn == address(token0);
        if (!isToken0 && tokenIn != address(token1)) revert InvalidToken();

        (uint256 reserveIn, uint256 reserveOut) = isToken0
            ? (reserve0, reserve1)
            : (reserve1, reserve0);

        amountOut = PoolMath.getAmountOut(amountIn, reserveIn, reserveOut, feeBps);
    }

    // ----------------------------------------------------------------
    // Internal helpers
    // ----------------------------------------------------------------

    function _pullToken(IERC20Minimal token, uint256 amount) internal {
        require(token.transferFrom(msg.sender, address(this), amount), "transferFrom failed");
    }

    /// @dev Babylonian method, same integer sqrt Uniswap v2 uses for the
    ///      first-mint liquidity calculation.
    function _sqrt(uint256 y) internal pure returns (uint256 z) {
        if (y > 3) {
            z = y;
            uint256 x = y / 2 + 1;
            while (x < z) {
                z = x;
                x = (y / x + x) / 2;
            }
        } else if (y != 0) {
            z = 1;
        }
    }
}
