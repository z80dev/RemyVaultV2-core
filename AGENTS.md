# Repository Guidelines

## Project Structure & Module Organization
Core contracts live in `src/`: `RemyVault.sol` handles fractionalization, `DerivativeRemyVault.sol` powers derivative vault drops, `DerivativeFactory.sol` plus `RemyVaultNFT.sol` coordinate new collections, and `RemyVaultHook.sol` integrates Uniswap V4. Interfaces and mocks reside in `src/interfaces/` and `src/mock/`, while deployment scripts sit in `scripts/`. Foundry tests mirror contract names under `test/` with shared fixtures in `test/helpers/`, and vendored dependencies (forge-std, Solmate, Uniswap V4) are tracked in `lib/` via `foundry.toml` remappings.

## Build, Test, and Development Commands
- `forge build` compiles Vyper 0.4.x and Solidity targets with the via-IR optimizer defined in `foundry.toml`.
- `forge test` runs the suite; target cases with `--match-contract` and inspect gas with `--gas-report`.
- `forge fmt` formats `.sol` sources; use `ape test` only when validating Ape workflows from `pyproject.toml`.

## Coding Style & Naming Conventions
Write Vyper with 4-space indentation and `snake_case` function names, reserving constants like `UNIT_VALUE` for protocol invariants. Solidity scripts and tests use 4 spaces, `camelCase` functions, and `CapWords` contracts, with NatSpec on any callable surface shared with integrators. Base new tests on `BaseTest` and suffix helper or stub contracts with `Mock` or `Helper` for clarity.

## Testing Guidelines
Every feature needs success, failure, and invariant coverage proving REMY supply equals locked NFTs × unit value. Place scenarios in the matching `*.t.sol` file using `testAction_State_Expectation` naming. Run `forge test --gas-report` before PRs and reserve `--ffi` invocations for documented needs.

## Commit & Pull Request Guidelines
Commits should use short imperative subjects, matching the existing `Add …` and `Implement …` pattern, and include motivation or security notes in the body when helpful. Pull requests must describe the change, link issues, list verification commands, and call out gas or custody impacts. Request protocol-owner review whenever vault ownership or withdrawal flows change.

## Security & Configuration Tips
Verify `vyper --version` reports ≥0.4.3 before compiling. Update `foundry.toml` remappings when adding libraries so imports stay deterministic. Keep deployment secrets in environment variables, and never relax nonreentrant guards or ownership modifiers without documenting the mitigation in `scripts/Deploy*.sol`.

## Agent Notes
- Always run Vyper-related builds/tests via `uv run ...` so the correct compiler is used.
