// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {BaseTest} from "./BaseTest.t.sol";

import {DerivativeFactory} from "../src/DerivativeFactory.sol";
import {RemyVaultFactory} from "../src/RemyVaultFactory.sol";
import {RemyVaultHook} from "../src/RemyVaultHook.sol";
import {RemyVaultNFT} from "../src/RemyVaultNFT.sol";
import {RemyVault} from "../src/RemyVault.sol";
import {MockERC721Simple} from "./helpers/MockERC721Simple.sol";

import {Hooks} from "@uniswap/v4-core/src/libraries/Hooks.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
import {Currency, CurrencyLibrary} from "@uniswap/v4-core/src/types/Currency.sol";
import {StateLibrary} from "@uniswap/v4-core/src/libraries/StateLibrary.sol";

contract DerivativeFactoryForkTest is BaseTest {
    using PoolIdLibrary for PoolKey;
    using CurrencyLibrary for Currency;
    using StateLibrary for IPoolManager;

    uint160 internal constant SQRT_PRICE_1_1 = 79228162514264337593543950336; // 2^96
    uint160 internal constant CLEAR_HOOK_PERMISSIONS_MASK = ~uint160(0) << 14;
    uint160 internal constant HOOK_FLAGS = Hooks.BEFORE_SWAP_FLAG | Hooks.AFTER_SWAP_FLAG
        | Hooks.BEFORE_SWAP_RETURNS_DELTA_FLAG | Hooks.AFTER_SWAP_RETURNS_DELTA_FLAG;
    uint160 internal constant HOOK_ADDRESS_SEED = uint160(0x4444000000000000000000000000000000000000);
    address internal constant HOOK_ADDRESS =
        address(uint160((HOOK_ADDRESS_SEED & CLEAR_HOOK_PERMISSIONS_MASK) | HOOK_FLAGS));

    address internal constant POOL_MANAGER_ADDRESS = 0x498581fF718922c3f8e6A244956aF099B2652b2b;
    IPoolManager internal constant POOL_MANAGER = IPoolManager(POOL_MANAGER_ADDRESS);

    RemyVaultFactory internal vaultFactory;
    RemyVaultHook internal hook;
    DerivativeFactory internal factory;
    MockERC721Simple internal parentCollection;

    function setUp() public override {
        super.setUp();
        vm.deal(address(this), 1_000_000 ether);

        vaultFactory = new RemyVaultFactory();
        parentCollection = new MockERC721Simple("Parent Collection", "PRNT");

        vm.etch(HOOK_ADDRESS, hex"");
        deployCodeTo("RemyVaultHook.sol:RemyVaultHook", abi.encode(POOL_MANAGER, address(this)), HOOK_ADDRESS);
        hook = RemyVaultHook(HOOK_ADDRESS);

        factory = new DerivativeFactory(vaultFactory, hook, address(this));
        hook.transferOwnership(address(factory));
    }

    function testCreateDerivative_OnBaseFork_ConfiguresPools() public {
        address parentVault = vaultFactory.deployVault(address(parentCollection), "Parent Token", "PRNT");

        PoolId rootPoolId = factory.registerRootPool(parentVault, 3000, 60, SQRT_PRICE_1_1);

        address nftOwner = makeAddr("nftOwner");
        address saleMinter = makeAddr("saleMinter");
        address derivativeTokenRecipient = makeAddr("derivativeTokenRecipient");

        // Provide inventory so the factory can add liquidity.
        uint256[] memory tokenIds = new uint256[](10);
        for (uint256 i; i < tokenIds.length; ++i) {
            uint256 tokenId = i + 1;
            parentCollection.mint(address(this), tokenId);
            tokenIds[i] = tokenId;
        }
        parentCollection.setApprovalForAll(parentVault, true);
        RemyVault(parentVault).deposit(tokenIds, address(this));
        RemyVault(parentVault).approve(address(factory), type(uint256).max);

        DerivativeFactory.DerivativeParams memory params;
        params.parentVault = parentVault;
        params.nftName = "Derivative Collection";
        params.nftSymbol = "DRV";
        params.nftBaseUri = "ipfs://derivative/";
        params.nftOwner = nftOwner;
        params.initialMinter = saleMinter;
        params.vaultName = "Derivative Token";
        params.vaultSymbol = "dDRV";
        params.fee = 3000;
        params.tickSpacing = 60;
        params.sqrtPriceX96 = SQRT_PRICE_1_1;
        params.maxSupply = 50;
        params.tickLower = -120;
        params.tickUpper = 120;
        params.liquidity = 5e5;
        params.parentTokenContribution = 3 * 1e18;
        params.derivativeTokenRecipient = derivativeTokenRecipient;
        params.parentTokenRefundRecipient = address(this);

        (address derivativeNft, address derivativeVault, PoolId childPoolId) = factory.createDerivative(params);

        assertEq(vaultFactory.vaultFor(derivativeNft), derivativeVault, "vault mapping mismatch");
        assertEq(factory.vaultForNft(derivativeNft), derivativeVault, "factory vault lookup mismatch");

        (address infoNft, address infoParent, PoolId infoPoolId) = factory.derivativeForVault(derivativeVault);
        assertEq(infoNft, derivativeNft, "derivative info nft mismatch");
        assertEq(infoParent, parentVault, "derivative info parent mismatch");
        assertEq(PoolId.unwrap(infoPoolId), PoolId.unwrap(childPoolId), "derivative info pool mismatch");

        RemyVaultNFT nft = RemyVaultNFT(derivativeNft);
        assertEq(nft.owner(), nftOwner, "nft owner mismatch");
        assertEq(nft.baseUri(), "ipfs://derivative/", "nft base URI mismatch");
        assertTrue(nft.isMinter(saleMinter), "minter not configured");

        (PoolKey memory storedRootKey, PoolId storedRootId) = factory.rootPool(parentVault);
        assertEq(PoolId.unwrap(storedRootId), PoolId.unwrap(rootPoolId), "root pool id mismatch");
        assertEq(address(storedRootKey.hooks), HOOK_ADDRESS, "root hook mismatch");
        assertTrue(storedRootKey.currency0.isAddressZero(), "root currency0 not eth");
        assertEq(Currency.unwrap(storedRootKey.currency1), parentVault, "root shared currency mismatch");

        (bool rootInitialized, bool rootHasParent,, Currency rootSharedCurrency, bool rootSharedIsChild0,) =
            hook.poolConfig(rootPoolId);
        assertTrue(rootInitialized, "root not configured");
        assertFalse(rootHasParent, "root should not have parent");
        assertEq(Currency.unwrap(rootSharedCurrency), parentVault, "root shared currency not vault");
        assertFalse(rootSharedIsChild0, "root shared orientation unexpected");

        (uint160 rootPrice,,,) = POOL_MANAGER.getSlot0(rootPoolId);
        assertEq(rootPrice, SQRT_PRICE_1_1, "root sqrt price mismatch");

        (
            bool childInitialized,
            bool childHasParent,
            PoolKey memory parentKey,
            Currency childSharedCurrency,
            bool childSharedIsChild0,
            bool childSharedIsParent0
        ) = hook.poolConfig(childPoolId);
        assertTrue(childInitialized, "child not configured");
        assertTrue(childHasParent, "child missing parent");
        assertEq(PoolId.unwrap(parentKey.toId()), PoolId.unwrap(rootPoolId), "parent key mismatch");
        assertEq(Currency.unwrap(childSharedCurrency), parentVault, "child shared currency mismatch");

        PoolKey memory expectedChildKey = _buildChildKey(derivativeVault, parentVault, 3000, 60);
        bool sharedIsCurrency0 = Currency.unwrap(expectedChildKey.currency0) == parentVault;
        assertEq(childSharedIsChild0, sharedIsCurrency0, "child shared orientation mismatch");
        bool parentSharedIsCurrency0 = Currency.unwrap(parentKey.currency0) == parentVault;
        assertEq(childSharedIsParent0, parentSharedIsCurrency0, "parent shared orientation mismatch");

        (uint160 childPrice,,,) = POOL_MANAGER.getSlot0(childPoolId);
        assertEq(childPrice, SQRT_PRICE_1_1, "child sqrt price mismatch");
    }

    function _buildChildKey(address tokenA, address tokenB, uint24 fee, int24 spacing)
        internal
        view
        returns (PoolKey memory key)
    {
        Currency currencyA = Currency.wrap(tokenA);
        Currency currencyB = Currency.wrap(tokenB);
        IHooks hooksInstance = IHooks(address(hook));
        if (Currency.unwrap(currencyA) < Currency.unwrap(currencyB)) {
            key = PoolKey({
                currency0: currencyA,
                currency1: currencyB,
                fee: fee,
                tickSpacing: spacing,
                hooks: hooksInstance
            });
        } else {
            key = PoolKey({
                currency0: currencyB,
                currency1: currencyA,
                fee: fee,
                tickSpacing: spacing,
                hooks: hooksInstance
            });
        }
    }
}
