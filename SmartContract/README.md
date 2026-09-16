# defi-arb-mev-simulator

A standalone Solidity toolkit for DeFi trading mechanics: constant-product
and concentrated-liquidity AMM math (v2- and v3-style), a v4-style hooks
engine with dynamic fees, oracle-deviation detection against a real
Chainlink-standard feed, and (in later phases) MEV/liquidation-bot
simulation — built to demonstrate hands-on understanding of how DEXs,
oracles, and arbitrage/MEV actually work at the contract level, not just
how to call an SDK.

**Topics:** `defi` `mev` `amm` `solidity` `foundry` `uniswap-v3`
`uniswap-v4` `arbitrage` `oracle` `chainlink` `liquidation` `ethereum`

## Current build state

| Phase | Status | What it covers |
|---|---|---|
| 1 — AMM math | ✅ Done | `PoolMath.sol` — constant-product swap math, price impact, slippage, effective price |
| 2 — Mock pools | ✅ Done | `MockUniswapV2Pool.sol` (reserve-based) + `MockUniswapV3Pool.sol` (tick-based concentrated liquidity) |
| 3 — Oracle deviation | ✅ Done | `OracleAggregator.sol` + `DeviationWatcher.sol` — AMM spot price vs a primary oracle + a real Chainlink-standard secondary feed |
| 3.5 — v4-style hooks | ✅ Done | `MockUniswapV4Pool.sol` + `IHooks.sol` + `OracleGuardHook.sol` — dynamic fees and an oracle-backed circuit-breaker hook |
| 4 — Liquidation/arb scanner vs a CDP/lending vault | ⏳ Not started | Needs a standalone mock vault contract |
| 5 — MEV simulation (sandwich, flash-loan oracle attack) | ⏳ Not started | |
| 6 — Dashboard/backend | ⏳ Not started | |

## Toolchain versions

Kept at the latest stable as of each update — check these are still current
before assuming they are:

- **Solidity:** `0.8.37` (pragma + `foundry.toml`'s `solc_version`)
- **ethers.js:** `^6.16.0`
- **forge-std:** tracked via `forge install foundry-rs/forge-std` (always latest at install time, no pin in this repo)
- **Node:** `>=18` (the real-time price pusher uses the global `fetch` API)

**Note on EVM version:** Solidity ≥0.8.25 defaults to targeting the Cancun
hardfork. If you deploy to a private/local network that doesn't support
Cancun opcodes (MCOPY, transient storage), uncomment `evm_version` in
`foundry.toml` and set it to whatever hardfork that network supports.

## Project structure

```
defi-arb-mev-simulator/
├── contracts/
│   ├── amm/
│   │   ├── PoolMath.sol            # constant-product swap math (library)
│   │   ├── TickMath.sol            # WAD-scaled sqrt-price-at-tick math (library)
│   │   ├── MockUniswapV2Pool.sol   # stateful reserve-based pool
│   │   ├── MockUniswapV3Pool.sol   # tick-based concentrated-liquidity pool
│   │   └── MockUniswapV4Pool.sol   # v3 engine + v4-style hooks & dynamic fees
│   ├── hooks/
│   │   ├── IHooks.sol              # simplified v4-style hook interface
│   │   ├── NoOpHooks.sol           # reference no-op hook implementation
│   │   └── OracleGuardHook.sol     # oracle-deviation circuit-breaker hook
│   ├── oracle/
│   │   ├── IPriceOracle.sol        # generic primary-oracle interface
│   │   ├── AggregatorV3Interface.sol # the real Chainlink feed interface
│   │   ├── MockChainlinkFeed.sol   # AggregatorV3Interface-compatible test feed
│   │   ├── OracleAggregator.sol    # reads primary + secondary price, reports deviation
│   │   └── DeviationWatcher.sol    # AMM price vs oracle price, threshold alerting
│   ├── mocks/
│   │   ├── MockERC20.sol           # minimal mintable ERC20 for tests
│   │   └── MockPrimaryOracle.sol   # reference/test implementation of IPriceOracle
│   └── interfaces/
│       └── IERC20Minimal.sol       # dependency-free ERC20 interface
├── test/                           # Foundry tests, one file per contract
│   ├── PoolMath.t.sol
│   ├── MockUniswapV2Pool.t.sol
│   ├── MockUniswapV3Pool.t.sol     # includes TickMathTest
│   ├── MockUniswapV4Pool.t.sol     # hook plumbing, dynamic fees, invalid-hook rejection
│   ├── OracleGuardHook.t.sol       # end-to-end: pool + hook + real oracle module
│   ├── OracleAggregator.t.sol
│   └── DeviationWatcher.t.sol
├── bot/
│   └── oracle-service/
│       └── realtime-price-pusher.js  # fetches a real live price, pushes to MockChainlinkFeed
├── script/                         # (not yet created) Foundry deploy scripts
├── backend/                        # (not yet created) dashboard API
├── frontend/                       # (not yet created) dashboard UI
├── foundry.toml
├── remappings.txt
├── package.json
├── .env.example
├── .gitignore
└── README.md
```

## Setup

```bash
# Solidity / Foundry
forge install foundry-rs/forge-std
forge build
forge test -vvv

# Node bots (real-time oracle pusher, future scanners)
npm install
cp .env.example .env   # fill in RPC_URL / PRIVATE_KEY / CHAINLINK_FEED_ADDRESS
npm run push-realtime-price
```

Point `RPC_URL` at any local EVM node (Anvil, Hardhat, or your own — no
specific network is assumed).

## Design notes / known simplifications

- **`TickMath.sol`** uses WAD (1e18) fixed point instead of real Uniswap
  v3's Q64.96 — easier to read, less precise at extreme ticks. Fine for
  demo price ranges near the current price.
- **`MockUniswapV3Pool.sol` / `MockUniswapV4Pool.sol`** have no
  fee-growth-per-position accounting and no tick bitmap (linear-scanned
  array of initialized ticks — fine at demo scale, not mainnet gas costs).
- **`MockUniswapV4Pool.sol`** is *not* a faithful reproduction of real v4's
  architecture: real v4 is a singleton `PoolManager` settling via flash
  accounting (lock/unlock, net deltas). This mock keeps the one-pool-per-
  contract model and settles tokens immediately, same as v2/v3 here — the
  gas/architecture optimization is skipped, but the hook *concept* (and the
  magic-value selector-return validation pattern) is kept faithfully.
- **`IHooks.sol`** always calls every hook if one is attached, rather than
  encoding hook permissions in the contract's deployed address (real v4's
  gas-optimized approach). Simpler to read, less gas-optimal.
- **`OracleAggregator.sol`** reads its secondary feed through the actual
  `AggregatorV3Interface` — the real Chainlink interface — so swapping
  `MockChainlinkFeed` for a live Chainlink feed address requires no code
  changes anywhere that depends on this contract.
- **`DeviationWatcher.poke()`** is permissionless by design — meant to be
  driven by an off-chain keeper loop, but anyone can trigger a check.
- **`realtime-price-pusher.js`** fetches an actual live price from
  CoinGecko's public API (free, no key) — a genuine independent source,
  not a simulation. It's still a single public REST endpoint, though: a
  production system would poll multiple independent sources.

## Why this exists

Built as a portfolio project demonstrating trading-specific DeFi mechanics
— AMM math, hook-based dynamic fees and circuit breakers, and real
oracle-deviation detection — as original, from-scratch Solidity rather
than SDK usage. See the phase table above for what's implemented vs
planned.
