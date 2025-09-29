// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Test} from "forge-std/Test.sol";
import {Vm} from "forge-std/Vm.sol";

import {DerivativeFactory} from "../src/DerivativeFactory.sol";
import {MinterRemyVault} from "../src/MinterRemyVault.sol";
import {RemyVaultFactory} from "../src/RemyVaultFactory.sol";
import {RemyVaultHook} from "../src/RemyVaultHook.sol";
import {RemyVaultNFT} from "../src/RemyVaultNFT.sol";
import {RemyVault} from "../src/RemyVault.sol";
import {MockERC721Simple} from "./helpers/MockERC721Simple.sol";

import {Hooks} from "@uniswap/v4-core/src/libraries/Hooks.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {PoolManager} from "@uniswap/v4-core/src/PoolManager.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
import {Currency, CurrencyLibrary} from "@uniswap/v4-core/src/types/Currency.sol";
import {StateLibrary} from "@uniswap/v4-core/src/libraries/StateLibrary.sol";
import {Ownable} from "solady/auth/Ownable.sol";
import {LibString} from "solady/utils/LibString.sol";
import {ERC721} from "solady/tokens/ERC721.sol";

contract DerivativeFactoryTest is Test {
    using PoolIdLibrary for PoolKey;
    using CurrencyLibrary for Currency;
    using StateLibrary for IPoolManager;
    using LibString for uint256;

    uint160 internal constant SQRT_PRICE_1_1 = 79228162514264337593543950336;
    uint160 internal constant CLEAR_HOOK_PERMISSIONS_MASK = ~uint160(0) << 14;
    uint160 internal constant HOOK_FLAGS = Hooks.BEFORE_SWAP_FLAG | Hooks.AFTER_SWAP_FLAG
        | Hooks.BEFORE_SWAP_RETURNS_DELTA_FLAG | Hooks.AFTER_SWAP_RETURNS_DELTA_FLAG;

    RemyVaultFactory internal vaultFactory;
    RemyVaultHook internal hook;
    DerivativeFactory internal factory;
    PoolManager internal managerImpl;
    IPoolManager internal manager;
    MockERC721Simple internal parentCollection;

    address internal hookAddress;

    function setUp() public {
        managerImpl = new PoolManager(address(this));
        manager = IPoolManager(address(managerImpl));

        address baseHookAddress = address(0x4444000000000000000000000000000000000000);
        hookAddress = address(uint160((uint160(baseHookAddress) & CLEAR_HOOK_PERMISSIONS_MASK) | HOOK_FLAGS));
        vm.etch(hookAddress, hex"");
        deployCodeTo("RemyVaultHook.sol:RemyVaultHook", abi.encode(manager, address(this)), hookAddress);
        hook = RemyVaultHook(hookAddress);

        vaultFactory = new RemyVaultFactory();
        factory = new DerivativeFactory(vaultFactory, hook, address(this));
        hook.transferOwnership(address(factory));

        parentCollection = new MockERC721Simple("Parent", "PRT");
    }

    function testRegisterRootPoolSetsHookConfig() public {
        address parentVault = vaultFactory.deployVault(address(parentCollection), "Parent Token", "PRMT");

        PoolKey memory expectedRootKey = _buildKey(address(0), parentVault, 3000, 60);
        PoolId expectedRootId = expectedRootKey.toId();

        vm.expectEmit(true, true, false, true, address(factory));
        emit DerivativeFactory.RootPoolRegistered(parentVault, expectedRootId, 3000, 60, SQRT_PRICE_1_1);

        PoolId rootId = factory.registerRootPool(parentVault, 3000, 60, SQRT_PRICE_1_1);
        (PoolKey memory storedKey, PoolId storedId) = factory.rootPool(parentVault);
        assertEq(PoolId.unwrap(rootId), PoolId.unwrap(storedId), "pool id mismatch");

        assertEq(address(storedKey.hooks), hookAddress, "hook mismatch");
        assertEq(uint24(storedKey.fee), 3000);
        assertEq(storedKey.tickSpacing, 60);
        assertTrue(storedKey.currency0.isAddressZero(), "currency0 should be ETH");
        assertEq(Currency.unwrap(storedKey.currency1), parentVault, "currency1 should be vault token");

        (bool initialized, bool hasParent,, Currency sharedCurrency, bool sharedIsChild0,) = hook.poolConfig(rootId);
        assertTrue(initialized, "root pool not registered");
        assertFalse(hasParent, "root should not have parent");
        assertEq(Currency.unwrap(sharedCurrency), parentVault, "shared token mismatch");
        assertFalse(sharedIsChild0, "shared token expected on currency1 side");

        (uint160 sqrtPrice,,,) = manager.getSlot0(rootId);
        assertEq(sqrtPrice, SQRT_PRICE_1_1, "sqrt price mismatch");
    }

    function testCreateVaultForCollectionDeploysVaultAndRootPool() public {
        address predictedVault = vaultFactory.predictVaultAddress(address(parentCollection), "Parent Token", "PRMT");
        PoolKey memory expectedRootKey = _buildKey(address(0), predictedVault, 3000, 60);
        PoolId expectedRootId = expectedRootKey.toId();

        vm.expectEmit(true, true, false, true, address(factory));
        emit DerivativeFactory.RootPoolRegistered(predictedVault, expectedRootId, 3000, 60, SQRT_PRICE_1_1);

        vm.expectEmit(true, true, true, false, address(factory));
        emit DerivativeFactory.ParentVaultRegistered(address(parentCollection), predictedVault, expectedRootId);

        (address parentVault, PoolId rootPoolId) = factory.createVaultForCollection(
            address(parentCollection), "Parent Token", "PRMT", 3000, 60, SQRT_PRICE_1_1
        );

        assertEq(vaultFactory.vaultFor(address(parentCollection)), parentVault, "vault mapping mismatch");
        RemyVault vaultToken = RemyVault(parentVault);
        assertEq(vaultToken.name(), "Parent Token", "vault name mismatch");
        assertEq(vaultToken.symbol(), "PRMT", "vault symbol mismatch");

        (PoolKey memory storedKey, PoolId storedId) = factory.rootPool(parentVault);
        assertEq(PoolId.unwrap(storedId), PoolId.unwrap(rootPoolId), "root pool id mismatch");
        assertEq(address(storedKey.hooks), hookAddress, "hook mismatch");
        assertTrue(storedKey.currency0.isAddressZero(), "currency0 should be ETH");
        assertEq(Currency.unwrap(storedKey.currency1), parentVault, "currency1 should be vault token");

        (bool initialized, bool hasParent,, Currency sharedCurrency, bool sharedIsChild0,) = hook.poolConfig(rootPoolId);
        assertTrue(initialized, "root pool not registered");
        assertFalse(hasParent, "root should not have parent");
        assertEq(Currency.unwrap(sharedCurrency), parentVault, "shared token mismatch");
        assertFalse(sharedIsChild0, "shared token expected on currency1 side");

        (uint160 sqrtPrice,,,) = manager.getSlot0(rootPoolId);
        assertEq(sqrtPrice, SQRT_PRICE_1_1, "sqrt price mismatch");
    }

    function testCreateDerivativeDeploysArtifacts() public {
        address parentVault = vaultFactory.deployVault(address(parentCollection), "Parent Token", "PRMT");
        PoolId parentPoolId = factory.registerRootPool(parentVault, 3000, 60, SQRT_PRICE_1_1);

        // Seed the parent vault with inventory so the factory can provide liquidity.
        uint256 depositCount = 100;
        uint256[] memory tokenIds = new uint256[](depositCount);
        for (uint256 i; i < depositCount; ++i) {
            uint256 tokenId = i + 1;
            parentCollection.mint(address(this), tokenId);
            tokenIds[i] = tokenId;
        }
        parentCollection.setApprovalForAll(parentVault, true);
        RemyVault(parentVault).deposit(tokenIds, address(this));
        RemyVault(parentVault).approve(address(factory), type(uint256).max);
        uint256 availableParentTokens = RemyVault(parentVault).balanceOf(address(this));

        address nftOwner = makeAddr("nftOwner");
        address saleMinter = makeAddr("saleMinter");
        address derivativeTokenSink = makeAddr("derivativeSink");

        DerivativeFactory.DerivativeParams memory params;
        params.parentVault = parentVault;
        params.nftName = "Derivative Collection";
        params.nftSymbol = "DRV";
        params.nftBaseUri = "ipfs://deriv/";
        params.nftOwner = nftOwner;
        params.initialMinter = saleMinter;
        params.vaultName = "Derivative Token";
        params.vaultSymbol = "dDRV";
        params.fee = 3000;
        params.tickSpacing = 60;
        params.sqrtPriceX96 = SQRT_PRICE_1_1;
        params.maxSupply = 100;
        params.tickLower = -120;
        params.tickUpper = 120;
        params.liquidity = 1e3;
        params.parentTokenContribution = availableParentTokens;
        params.derivativeTokenRecipient = derivativeTokenSink;
        params.parentTokenRefundRecipient = address(this);

        uint256 parentBalanceBefore = RemyVault(parentVault).balanceOf(address(this));

        vm.recordLogs();
        (address derivativeNft, address derivativeVault, PoolId childPoolId) = factory.createDerivative(params);
        Vm.Log[] memory entries = vm.getRecordedLogs();

        bytes32 derivativeCreatedTopic =
            keccak256("DerivativeCreated(address,address,address,address,bytes32,uint24,int24,uint160)");
        bool foundDerivativeEvent;
        for (uint256 i; i < entries.length; ++i) {
            Vm.Log memory entry = entries[i];
            if (entry.emitter != address(factory) || entry.topics[0] != derivativeCreatedTopic) {
                continue;
            }
            foundDerivativeEvent = true;
            assertEq(entry.topics.length, 4, "unexpected topic count");
            assertEq(address(uint160(uint256(entry.topics[1]))), address(parentCollection), "collection mismatch");
            assertEq(address(uint160(uint256(entry.topics[2]))), params.parentVault, "parent vault mismatch");
            assertEq(address(uint160(uint256(entry.topics[3]))), derivativeNft, "nft mismatch in event");

            (
                address eventDerivativeVault,
                bytes32 eventChildPoolId,
                uint24 eventFee,
                int24 eventTickSpacing,
                uint160 eventSqrtPrice
            ) = abi.decode(entry.data, (address, bytes32, uint24, int24, uint160));
            assertEq(eventDerivativeVault, derivativeVault, "derivative vault mismatch in event");
            assertEq(eventChildPoolId, PoolId.unwrap(childPoolId), "child pool id mismatch");
            assertEq(eventFee, params.fee, "fee mismatch in event");
            assertEq(eventTickSpacing, params.tickSpacing, "tick spacing mismatch in event");
            assertEq(eventSqrtPrice, SQRT_PRICE_1_1, "sqrt price mismatch in event");
        }
        assertTrue(foundDerivativeEvent, "DerivativeCreated event not emitted");

        assertEq(vaultFactory.vaultFor(derivativeNft), derivativeVault, "factory should map NFT to vault");
        assertEq(factory.vaultForNft(derivativeNft), derivativeVault, "vault lookup mismatch");

        (address infoNft, address infoParent, PoolId infoPoolId) = factory.derivativeForVault(derivativeVault);
        assertEq(infoNft, derivativeNft, "info nft mismatch");
        assertEq(infoParent, parentVault, "info parent mismatch");
        assertEq(PoolId.unwrap(infoPoolId), PoolId.unwrap(childPoolId), "info pool mismatch");

        RemyVaultNFT nft = RemyVaultNFT(derivativeNft);
        assertEq(nft.owner(), nftOwner, "NFT ownership not transferred");
        assertEq(nft.baseUri(), "ipfs://deriv/", "base URI mismatch");
        assertTrue(nft.isMinter(saleMinter), "minter not configured");
        assertTrue(nft.isMinter(derivativeVault), "vault should be configured as minter");

        MinterRemyVault derivativeToken = MinterRemyVault(derivativeVault);
        assertEq(derivativeToken.maxSupply(), params.maxSupply, "max supply mismatch");
        assertEq(derivativeToken.totalSupply(), params.maxSupply * derivativeToken.UNIT(), "total supply mismatch");
        assertEq(derivativeToken.balanceOf(address(factory)), 0, "factory should not retain vault tokens");
        assertGt(derivativeToken.balanceOf(derivativeTokenSink), 0, "recipient should receive vault tokens");

        (bool initialized, bool hasParent, PoolKey memory parentKey, Currency sharedCurrency, bool sharedIsChild0,) =
            hook.poolConfig(childPoolId);
        assertTrue(initialized, "child not registered");
        assertTrue(hasParent, "child missing parent");
        assertEq(PoolId.unwrap(parentKey.toId()), PoolId.unwrap(parentPoolId), "parent pool mismatch");
        assertEq(Currency.unwrap(sharedCurrency), parentVault, "shared token mismatch");

        PoolKey memory expectedChildKey = _buildKey(derivativeVault, parentVault, 3000, 60);
        bool childCurrency0IsParent = Currency.unwrap(expectedChildKey.currency0) == parentVault;
        assertEq(sharedIsChild0, childCurrency0IsParent, "shared orientation mismatch");

        (uint160 childSqrtPrice,,,) = manager.getSlot0(childPoolId);
        assertEq(childSqrtPrice, SQRT_PRICE_1_1, "child sqrt price mismatch");

        bool derivativeIsCurrency0 = Currency.unwrap(expectedChildKey.currency0) == derivativeVault;
        (int24 lower, int24 upper, uint160 normalizedPrice) =
            _normalizeTicks(derivativeIsCurrency0, params.tickLower, params.tickUpper, params.sqrtPriceX96);

        (uint128 liquidity,,) = manager.getPositionInfo(childPoolId, address(factory), lower, upper, bytes32(0));
        assertEq(liquidity, params.liquidity, "liquidity mismatch");
        assertEq(normalizedPrice, childSqrtPrice, "price normalization mismatch");

        uint256 parentBalanceAfter = RemyVault(parentVault).balanceOf(address(this));
        assertLt(parentBalanceAfter, parentBalanceBefore, "parent tokens not consumed");
        assertEq(RemyVault(parentVault).balanceOf(address(factory)), 0, "factory retains parent tokens");

        address collector = makeAddr("collector");
        vm.prank(derivativeVault);
        uint256 mintedId = nft.safeMint(collector, "initial.json");
        assertEq(nft.tokenURI(mintedId), "ipfs://deriv/initial.json", "vault mint failed");

        vm.expectRevert(Ownable.Unauthorized.selector);
        vm.prank(saleMinter);
        nft.setTokenUri(mintedId, "hijack.json");

        vm.prank(nftOwner);
        nft.setBaseUri("ipfs://updated/");
        assertEq(nft.baseUri(), "ipfs://updated/", "base uri not updated");
        assertEq(nft.tokenURI(mintedId), "ipfs://updated/initial.json", "token uri should reflect new base");

        vm.prank(nftOwner);
        nft.setTokenUri(mintedId, "custom.json");
        assertEq(nft.tokenURI(mintedId), "ipfs://updated/custom.json", "token uri not overridden");

        vm.prank(nftOwner);
        nft.setTokenUri(mintedId, "");
        assertEq(nft.tokenURI(mintedId), string.concat("ipfs://updated/", mintedId.toString()), "token uri not reset");

        vm.expectRevert(ERC721.TokenDoesNotExist.selector);
        vm.prank(nftOwner);
        nft.setTokenUri(42, "missing.json");
    }

    function testCreateDerivativeRevertsWhenParentMissing() public {
        DerivativeFactory.DerivativeParams memory params;
        params.parentVault = address(0xdead);
        params.nftName = "Derivative";
        params.nftSymbol = "DRV";
        params.nftBaseUri = "ipfs://";
        params.vaultName = "Token";
        params.vaultSymbol = "TT";
        params.fee = 3000;
        params.tickSpacing = 60;
        params.sqrtPriceX96 = SQRT_PRICE_1_1;
        params.maxSupply = 1;
        params.tickLower = -60;
        params.tickUpper = 60;
        params.liquidity = 1;

        vm.expectRevert(abi.encodeWithSelector(DerivativeFactory.ParentVaultNotRegistered.selector, params.parentVault));
        factory.createDerivative(params);
    }

    function testRegisterRootPoolRequiresFactoryVault() public {
        address randomToken = address(new RemyVault("Mock", "MOCK", address(parentCollection)));
        vm.expectRevert(abi.encodeWithSelector(DerivativeFactory.ParentVaultNotFromFactory.selector, randomToken));
        factory.registerRootPool(randomToken, 3000, 60, SQRT_PRICE_1_1);
    }

    function _normalizeTicks(bool derivativeIsCurrency0, int24 tickLower, int24 tickUpper, uint160 sqrtPriceX96)
        internal
        pure
        returns (int24 lower, int24 upper, uint160 priceX96)
    {
        if (derivativeIsCurrency0) {
            return (tickLower, tickUpper, sqrtPriceX96);
        }

        lower = -tickUpper;
        upper = -tickLower;
        priceX96 = uint160((uint256(1) << 192) / sqrtPriceX96);
    }

    function _buildKey(address tokenA, address tokenB, uint24 fee, int24 spacing)
        internal
        view
        returns (PoolKey memory key)
    {
        Currency currencyA = Currency.wrap(tokenA);
        Currency currencyB = Currency.wrap(tokenB);
        if (Currency.unwrap(currencyA) < Currency.unwrap(currencyB)) {
            key = PoolKey({
                currency0: currencyA,
                currency1: currencyB,
                fee: fee,
                tickSpacing: spacing,
                hooks: IHooks(hookAddress)
            });
        } else {
            key = PoolKey({
                currency0: currencyB,
                currency1: currencyA,
                fee: fee,
                tickSpacing: spacing,
                hooks: IHooks(hookAddress)
            });
        }
    }
}
