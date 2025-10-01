// SPDX-License-Identifier: MIT

pragma solidity ^0.8.24;

import "forge-std/Test.sol";

import {wNFTFactory} from "../src/wNFTFactory.sol";
import {wNFT} from "../src/wNFT.sol";
import {wNFTHook} from "../src/wNFTHook.sol";
import {MockERC721Simple} from "./helpers/MockERC721Simple.sol";

import {Hooks} from "@uniswap/v4-core/src/libraries/Hooks.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
import {Currency, CurrencyLibrary} from "@uniswap/v4-core/src/types/Currency.sol";
import {PoolManager} from "@uniswap/v4-core/src/PoolManager.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {StateLibrary} from "@uniswap/v4-core/src/libraries/StateLibrary.sol";

contract RemyVaultHookIntegrationTest is Test {
    using PoolIdLibrary for PoolKey;
    using CurrencyLibrary for Currency;
    using StateLibrary for IPoolManager;

    wNFTFactory internal factory;
    MockERC721Simple internal collection;
    PoolManager internal managerImpl;
    IPoolManager internal manager;

    uint160 internal constant CLEAR_HOOK_PERMISSIONS_MASK = ~uint160(0) << 14;

    function setUp() public {
        managerImpl = new PoolManager(address(this));
        manager = IPoolManager(address(managerImpl));

        factory = new wNFTFactory();
        collection = new MockERC721Simple("Remy Collection", "REMY");

        vm.deal(address(this), 100 ether);
    }

    function testDeployVaultTokenAndInitializeHookedPool() public {
        address vaultAddr = factory.deployVault(address(collection));
        wNFT vault = wNFT(vaultAddr);

        uint256 depositCount = 50;
        for (uint256 i = 0; i < depositCount; ++i) {
            collection.mint(address(this), i);
        }

        collection.setApprovalForAll(vaultAddr, true);

        uint256[] memory tokenIds = new uint256[](depositCount);
        for (uint256 i = 0; i < depositCount; ++i) {
            tokenIds[i] = i;
        }

        uint256 mintedAmount = vault.deposit(tokenIds, address(this));
        assertEq(mintedAmount, depositCount * vault.UNIT(), "Unexpected minted amount");
        assertEq(vault.balanceOf(address(this)), mintedAmount, "Vault balance mismatch");

        address hookAddress = address(
            uint160(
                type(uint160).max & CLEAR_HOOK_PERMISSIONS_MASK | Hooks.BEFORE_SWAP_FLAG | Hooks.AFTER_SWAP_FLAG
                    | Hooks.BEFORE_SWAP_RETURNS_DELTA_FLAG | Hooks.AFTER_SWAP_RETURNS_DELTA_FLAG
            )
        );
        vm.label(hookAddress, "wNFTHook");
        deployCodeTo("wNFTHook.sol:wNFTHook", abi.encode(manager, address(this)), hookAddress);
        wNFTHook hook = wNFTHook(hookAddress);
        assertEq(hook.owner(), address(this), "Hook owner not set");

        PoolKey memory rootKey = PoolKey({
            currency0: CurrencyLibrary.ADDRESS_ZERO,
            currency1: Currency.wrap(address(vault)),
            fee: 3000,
            tickSpacing: 60,
            hooks: IHooks(address(hook))
        });

        PoolKey memory emptyKey;
        hook.addChild(rootKey, false, emptyKey);

        uint160 sqrtPriceX96 = uint160(792281625142643375935439503360);
        manager.initialize(rootKey, sqrtPriceX96);

        PoolId poolId = rootKey.toId();
        (uint160 storedSqrtPrice,,,) = manager.getSlot0(poolId);
        assertEq(storedSqrtPrice, sqrtPriceX96, "Pool initialized at incorrect price");

        (bool initialized, bool hasParent,, Currency sharedCurrency, bool sharedIsChild0,) = hook.poolConfig(poolId);
        assertTrue(initialized, "Hook did not mark pool initialized");
        assertFalse(hasParent, "Root pool should not have parent");
        assertEq(Currency.unwrap(sharedCurrency), address(vault), "Shared currency should be Remy token");
        assertEq(sharedIsChild0, false, "Shared token expected on currency1 side");

        uint128 liquidity = manager.getLiquidity(poolId);
        assertEq(liquidity, 0, "Liquidity should be zero immediately after initialize");
    }
}
