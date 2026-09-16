// SPDX-License-Identifier: MIT
pragma solidity ^0.8.37;

/// @notice Minimal ERC20 interface — just what MockUniswapV2Pool needs.
/// @dev Kept dependency-free on purpose so this project can be built/tested
///      standalone without requiring the OpenZeppelin install step.
interface IERC20Minimal {
    function transfer(address to, uint256 amount) external returns (bool);
    function transferFrom(address from, address to, uint256 amount) external returns (bool);
    function balanceOf(address account) external view returns (uint256);
}
