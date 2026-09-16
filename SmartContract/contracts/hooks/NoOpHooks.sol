// SPDX-License-Identifier: MIT
pragma solidity ^0.8.37;

import {IHooks} from "./IHooks.sol";

/// @notice Reference IHooks implementation: correctly returns each
///         function's own selector (satisfying the magic-value check) but
///         otherwise does nothing. Useful for exercising the hook-calling
///         plumbing in `MockUniswapV4Pool` without any custom logic
///         getting in the way, and as a template for writing real hooks.
contract NoOpHooks is IHooks {
    function beforeInitialize(address, uint256) external pure returns (bytes4) {
        return IHooks.beforeInitialize.selector;
    }

    function afterInitialize(address, uint256, int24) external pure returns (bytes4) {
        return IHooks.afterInitialize.selector;
    }

    function beforeAddLiquidity(address, int24, int24, uint256) external pure returns (bytes4) {
        return IHooks.beforeAddLiquidity.selector;
    }

    function afterAddLiquidity(
        address,
        int24,
        int24,
        uint256,
        uint256,
        uint256
    ) external pure returns (bytes4) {
        return IHooks.afterAddLiquidity.selector;
    }

    function beforeRemoveLiquidity(address, int24, int24, uint256) external pure returns (bytes4) {
        return IHooks.beforeRemoveLiquidity.selector;
    }

    function afterRemoveLiquidity(
        address,
        int24,
        int24,
        uint256,
        uint256,
        uint256
    ) external pure returns (bytes4) {
        return IHooks.afterRemoveLiquidity.selector;
    }

    function beforeSwap(
        address,
        bool,
        uint256
    ) external pure returns (bytes4, uint256, bool) {
        return (IHooks.beforeSwap.selector, 0, false);
    }

    function afterSwap(address, bool, uint256, uint256) external pure returns (bytes4) {
        return IHooks.afterSwap.selector;
    }
}
