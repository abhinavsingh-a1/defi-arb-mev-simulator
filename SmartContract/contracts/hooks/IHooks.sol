// SPDX-License-Identifier: MIT
pragma solidity ^0.8.37;

/// @title IHooks
/// @notice Simplified Uniswap-v4-style hook interface: external contracts
///         can plug into a pool's lifecycle (initialize, add/remove
///         liquidity, swap) to add custom logic — dynamic fees, circuit
///         breakers, custom accounting, etc.
/// @dev Deliberately simplified vs real Uniswap v4 in one specific way:
///      real v4 encodes which hooks a contract implements in the low bits
///      of its own deployed address (checked via `HooksLibrary` bit
///      masks), which lets `PoolManager` skip calling hooks a contract
///      doesn't implement without an extra external call. This version
///      always calls every hook if `hooks != address(0)` and expects a
///      no-op implementation (see `NoOpHooks.sol`) for callbacks a given
///      hook doesn't care about — simpler to read, less gas-optimal.
///
///      The magic-value return pattern (each hook must return its own
///      function selector, like ERC-721's `onERC721Received`) IS kept
///      faithfully — it's what lets a pool detect "this address doesn't
///      actually implement the hook interface correctly" and revert,
///      rather than silently trusting whatever an external call returns.
interface IHooks {
    function beforeInitialize(address sender, uint256 initialSqrtPriceWad) external returns (bytes4);
    function afterInitialize(address sender, uint256 initialSqrtPriceWad, int24 tick) external returns (bytes4);

    function beforeAddLiquidity(
        address sender,
        int24 tickLower,
        int24 tickUpper,
        uint256 liquidityDelta
    ) external returns (bytes4);

    function afterAddLiquidity(
        address sender,
        int24 tickLower,
        int24 tickUpper,
        uint256 liquidityDelta,
        uint256 amount0,
        uint256 amount1
    ) external returns (bytes4);

    function beforeRemoveLiquidity(
        address sender,
        int24 tickLower,
        int24 tickUpper,
        uint256 liquidityDelta
    ) external returns (bytes4);

    function afterRemoveLiquidity(
        address sender,
        int24 tickLower,
        int24 tickUpper,
        uint256 liquidityDelta,
        uint256 amount0,
        uint256 amount1
    ) external returns (bytes4);

    /// @notice Called before a swap executes. May optionally override the
    ///         pool's base fee for this swap only — the dynamic-fee
    ///         mechanism v4 is best known for.
    /// @return selector      Must equal `IHooks.beforeSwap.selector`.
    /// @return feeOverrideBps The fee (bps) to use instead of the pool's
    ///         base fee, if `overrideFee` is true. Ignored otherwise.
    /// @return overrideFee   Whether to apply `feeOverrideBps`.
    function beforeSwap(
        address sender,
        bool zeroForOne,
        uint256 amountIn
    ) external returns (bytes4 selector, uint256 feeOverrideBps, bool overrideFee);

    /// @notice Called after a swap executes, with the pool's storage
    ///         already updated to reflect it. A hook reverting here
    ///         reverts the entire swap (and its state changes) — this is
    ///         what makes it usable as a circuit breaker, e.g.
    ///         `OracleGuardHook`.
    function afterSwap(
        address sender,
        bool zeroForOne,
        uint256 amountIn,
        uint256 amountOut
    ) external returns (bytes4);
}
