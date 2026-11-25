# morpho-contracts-helper

Helper contracts for working with [Morpho](https://morpho.org) markets and vaults alongside API3 data feeds, plus the TypeChain bindings to use them from TypeScript.

The package bundles:

- on-chain helpers for deploying Morpho VaultV2 vaults, reading market data, and liquidating positions after an API3 feed update;
- test utilities (mock Chainlink-compatible price feeds and mintable ERC-20 tokens) for setting up Morpho markets on test networks;
- the ABIs and TypeChain types for all of the above.

## Contracts

| Contract | File | Purpose |
|---|---|---|
| `LiquidationHelper` | [`contracts/LiqHelper.sol`](contracts/LiqHelper.sol) | Pushes API3 signed-data updates to `Api3ServerV1`, then calls `Morpho.liquidate` in the same transaction and sends the leftover loan tokens and the seized collateral to the caller. Can tip `block.coinbase`. |
| `MorphoVaultV2DeployHelper` | [`contracts/MorphoVaultV2DeployHelper.sol`](contracts/MorphoVaultV2DeployHelper.sol) | Deploys and configures a Morpho VaultV2 with a `MorphoMarketV1AdapterV2` in one call: adapter registry, caps, abdicated gates, optional liquidity market, timelocks, then hands curator and owner roles to the given addresses. |
| `MorphoMarketDataFetcher` | [`contracts/MorphoMarketDataFetcher.sol`](contracts/MorphoMarketDataFetcher.sol) | View-only. Returns a market's params, loan/collateral token metadata, `MorphoChainlinkOracleV2` configuration, feed prices and the dead-address supply in one call. |
| `ManualChainlinkMockFeed`, `ManualChainlinkMockFeedFactory` | [`contracts/OracleFactory.sol`](contracts/OracleFactory.sol) | **Testing only.** Chainlink `AggregatorV3Interface` mock with a manual mode and three simulated price curves (trending up, trending down, crash and recover). |
| `Token`, `TokenFactory` | [`contracts/TokenFactory.sol`](contracts/TokenFactory.sol) | **Testing only.** Ownable, mintable, pausable, burnable ERC-20 with EIP-2612 permit, and a factory that deploys and indexes them. |
| `DComp` | [`contracts/DComp.sol`](contracts/DComp.sol) | 1:1 wrapper for COMP (dCOMP) with a depositor whitelist and owner-controlled delegation of the wrapped COMP's voting power. Ethereum mainnet only: the COMP address is hard-coded. |

### Vendored code

`contracts/external/` and `contracts/vendor/` hold third-party interfaces and libraries (Morpho, API3, Compound, OpenZeppelin) that the contracts above compile against.

`contracts/external/Multicall3.sol` is a copy of the canonical [Multicall3](https://github.com/mds1/multicall). It is here only for its ABI and types; use the canonical deployment at `0xcA11bde05977b3631167028862bE2a173976CA11` instead of deploying it from this repository.

### Mock feed simulation modes

`ManualChainlinkMockFeed` reports a price computed from its base price, `basisPoints` and the time since `simStartTime`:

| Mode | Value | Behaviour |
|---|---|---|
| `MANUAL` | 0 | Returns the price set with `setPrice`. |
| `TRENDING_UP` | 1 | Compounds up by `basisPoints` every 5 minutes. |
| `TRENDING_DOWN` | 2 | Compounds down by `basisPoints` every 5 minutes. |
| `CRASH_AND_RECOVER` | 3 | Grows by `basisPoints` per hour for 23 hours, crashes linearly to 75% of the base price in hour 23, recovers to the base price in hour 24, then stays flat. |

Owners can switch modes with `setMode`, change the base price with `setBasePrice` (in simulation modes this restarts the curve), restart with `restartSimulation`, and add owners with `addOwner`. Owners cannot be removed.

## Using the package

```sh
pnpm add morpho-contracts-helper
```

The package exports the TypeChain (ethers v6) factories and types for every contract:

```ts
import { ethers } from 'ethers';
import { MorphoMarketDataFetcher__factory } from 'morpho-contracts-helper';

const fetcher = MorphoMarketDataFetcher__factory.connect(fetcherAddress, provider);
const market = await fetcher.getMarketDetails(marketId, ethers.ZeroAddress);
console.log(market.loanToken.symbol, market.collateralToken.symbol, market.oracle.currentPrice);
```

## Development

Requires Node.js and pnpm.

```sh
pnpm install
pnpm build          # compiles the contracts, generates TypeChain types, builds dist/
pnpm build:hardhat  # compiles the contracts and generates TypeChain types only
```

Contracts compile with Solidity 0.8.12 and 0.8.27 (see [`hardhat.config.cts`](hardhat.config.cts)). The repository has no test suite yet.
