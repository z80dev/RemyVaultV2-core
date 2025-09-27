# Admin Notes

## Vault Versions
- `RemyVault` implements RemyVault V2. It purposefully has **no owner** and exports no admin-only entrypoints. Anyone can deposit NFTs, mint the fungible supply (fixed at `1e18` tokens per NFT), and withdraw against the inventory. Treat it as "WETH for NFTs".
- Code that references legacy RemyVault V1 (e.g., `Migrator.vy`, `RescueRouterV2.vy`, `modules/vault_owner.vy`) interacts with that system strictly through interfaces (`src/interfaces/LegacyRemyVault.vyi`). The actual V1 implementation is **not** vendored in this repository.

## Factories & Ownership
- `RemyVaultFactory` mirrors the vault's permissionless ethos. It performs deterministic `CREATE2` deployments keyed off the ERC-721 collection and keeps lookup tables, but it does **not** retain an owner role.
- `DerivativeFactory` is the only component that enforces ownership. It owns newly minted `RemyVaultNFT` derivatives, registers pools on the Uniswap v4 hook, and can optionally hand control to downstream operators. The owner must also hold the hook to satisfy the `requiresHookOwnership` modifier.

## Legacy Tooling
- Migration helpers call into V1 to unwind deposits, then funnel the NFTs into V2. When running those flows, ensure V1 contracts are deployed on the target network and exposed at the addresses configured in scripts/tests.
- Rescue tooling (`RescueRouterV2.vy`) still toggles V1 state (e.g., `set_active`) before bridging assets into V2. Validate permissions on those pre-existing contracts before attempting production operations.

## Documentation Sync Checklist
- README now describes the vault as ownerless/permissionless and clarifies that factories introduce ownership only where necessary.
- When adding new modules, update this file and link any privileged operations so operations teams understand which addresses require custody.
