// SPDX-License-Identifier: MIT
pragma solidity ^0.8.37;

/// @title IPriceOracle
/// @notice Minimal interface for a primary on-chain price oracle: an
///         off-chain reporter (e.g. an EIP-712-signed price service)
///         writing to an on-chain adapter, which this interface reads from.
/// @dev This project is intentionally standalone — it doesn't assume any
///      specific upstream protocol's oracle contract. If you're wiring
///      this up against a real oracle adapter (your own or a third
///      party's), implement this interface (or add an adapter that does)
///      so the rest of the oracle module — `OracleAggregator`,
///      `DeviationWatcher` — needs no changes.
interface IPriceOracle {
    /// @notice Returns the latest known price for `assetId` and when it was
    ///         last updated.
    /// @param assetId Opaque identifier for the priced asset (e.g.
    ///        keccak256("ETH/USD")).
    /// @return price WAD-scaled (1e18) price.
    /// @return updatedAt Unix timestamp of the last on-chain price update.
    function getLatestPrice(bytes32 assetId) external view returns (uint256 price, uint256 updatedAt);
}
