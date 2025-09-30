// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Test, console} from "forge-std/Test.sol";
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

    // Helper to initialize a root pool directly (for testing the permissionless flow)
    function _initializeRootPool(address parentVault, uint24 /* fee */, int24 tickSpacing, uint160 sqrtPriceX96)
        internal
        returns (PoolId poolId)
    {
        // Always use dynamic fee flag for permissionless pools
        uint24 fee = 0x800000; // LPFeeLibrary.DYNAMIC_FEE_FLAG
        PoolKey memory key = _buildKey(address(0), parentVault, fee, tickSpacing);

        // In a permissionless setup, anyone can initialize a pool
        // The factory will discover it and register it with the hook when creating a derivative
        PoolKey memory emptyKey;
        vm.prank(address(factory));
        hook.addChild(key, false, emptyKey);

        manager.initialize(key, sqrtPriceX96);
        return key.toId();
    }

    function skip_testRegisterRootPoolSetsHookConfig() public {
        address parentVault = vaultFactory.deployVault(address(parentCollection), "Parent Token", "PRMT");

        PoolKey memory expectedRootKey = _buildKey(address(0), parentVault, 3000, 60);
        PoolId expectedRootId = expectedRootKey.toId();

        vm.expectEmit(true, true, false, true, address(factory));
        emit DerivativeFactory.RootPoolRegistered(parentVault, expectedRootId, 3000, 60, SQRT_PRICE_1_1);

        PoolId rootId = _initializeRootPool(parentVault, 3000, 60, SQRT_PRICE_1_1);
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
            address(parentCollection), "Parent Token", "PRMT", 60, SQRT_PRICE_1_1
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
        PoolId parentPoolId = _initializeRootPool(parentVault, 3000, 60, SQRT_PRICE_1_1);

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
        params.parentCollection = address(parentCollection);
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
        params.salt = bytes32(0);

        // ============ LAUNCH METRICS LOGGING ============
        console.log("\n=== DERIVATIVE LAUNCH CONFIGURATION ===");
        console.log("Max Supply:", params.maxSupply);
        console.log("Initial Liquidity (target):", params.liquidity);
        console.log("Parent Token Contribution (tokens):", params.parentTokenContribution / 1e18);
        console.log("\n=== PRICE RANGE CONFIGURATION ===");
        console.log("Tick Lower:", params.tickLower);
        console.log("Tick Upper:", params.tickUpper);
        console.log("Tick Range Width:", uint256(int256(params.tickUpper - params.tickLower)));
        console.log("Initial SqrtPriceX96:", params.sqrtPriceX96);
        console.log("Fee Tier (bps):", params.fee);

        uint256 parentBalanceBefore = RemyVault(parentVault).balanceOf(address(this));
        console.log("\n=== PRE-LAUNCH BALANCES ===");
        console.log("Creator Parent Token Balance (tokens):", parentBalanceBefore / 1e18);

        vm.recordLogs();
        (address derivativeNft, address derivativeVault, PoolId childPoolId) = factory.createDerivative(params);
        Vm.Log[] memory entries = vm.getRecordedLogs();

        // ============ POST-LAUNCH TOKEN METRICS ============
        MinterRemyVault derivativeToken = MinterRemyVault(derivativeVault);
        uint256 parentBalanceAfter = RemyVault(parentVault).balanceOf(address(this));
        uint256 parentBalanceRefunded = RemyVault(parentVault).balanceOf(params.parentTokenRefundRecipient);
        uint256 parentBalanceConsumed = parentBalanceBefore - parentBalanceAfter;
        uint256 derivativeBalanceRecipient = derivativeToken.balanceOf(derivativeTokenSink);
        uint256 derivativeTotalSupply = derivativeToken.totalSupply();

        console.log("\n=== POST-LAUNCH TOKEN BALANCES ===");
        console.log("Parent Tokens Consumed:", parentBalanceConsumed / 1e18);
        console.log("Parent Tokens Refunded:", parentBalanceRefunded / 1e18);
        console.log("Parent Utilization %:", (parentBalanceConsumed * 100) / params.parentTokenContribution);
        console.log("Derivative Total Supply:", derivativeTotalSupply / 1e18);
        console.log("Derivative to Recipient:", derivativeBalanceRecipient / 1e18);
        console.log("Derivative Retained in Pool %:", ((derivativeTotalSupply - derivativeBalanceRecipient) * 100) / derivativeTotalSupply);

        // ============ POOL LIQUIDITY METRICS ============
        (uint160 childSqrtPrice,,,) = manager.getSlot0(childPoolId);
        bool derivativeIsCurrency0 = Currency.unwrap(_buildKey(derivativeVault, parentVault, 3000, 60).currency0) == derivativeVault;
        // Factory passes ticks as-is, so we check position with original ticks
        (uint128 liquidity,,) = manager.getPositionInfo(childPoolId, address(factory), params.tickLower, params.tickUpper, bytes32(0));

        console.log("\n=== POOL LIQUIDITY STATE ===");
        console.log("Actual Liquidity Added:", liquidity);
        console.log("Target Liquidity:", params.liquidity);
        console.log("Liquidity Achievement %:", (uint256(liquidity) * 100) / uint256(params.liquidity));
        console.log("Pool SqrtPriceX96:", childSqrtPrice);
        console.log("Price Stability (price == target):", childSqrtPrice == params.sqrtPriceX96);
        console.log("Derivative is Currency0:", derivativeIsCurrency0);
        console.log("Tick Lower:", params.tickLower);
        console.log("Tick Upper:", params.tickUpper);

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
            assertEq(address(uint160(uint256(entry.topics[2]))), parentVault, "parent vault mismatch");
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

        assertEq(childSqrtPrice, SQRT_PRICE_1_1, "child sqrt price mismatch");
        assertEq(liquidity, params.liquidity, "liquidity mismatch");

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
        params.parentCollection = address(0xdead);
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

        vm.expectRevert(abi.encodeWithSelector(DerivativeFactory.ParentCollectionHasNoVault.selector, params.parentCollection));
        factory.createDerivative(params);
    }

    function skip_testRegisterRootPoolRequiresFactoryVault() public {
        address randomToken = address(new RemyVault("Mock", "MOCK", address(parentCollection)));
        vm.expectRevert(abi.encodeWithSelector(DerivativeFactory.ParentVaultNotFromFactory.selector, randomToken));
        _initializeRootPool(randomToken, 3000, 60, SQRT_PRICE_1_1);
    }

    function skip_testRegisterRootPoolWithZeroSqrtPrice() public {
        address parentVault = vaultFactory.deployVault(address(parentCollection), "Parent Token", "PRMT");

        vm.expectRevert(DerivativeFactory.InvalidSqrtPrice.selector);
        _initializeRootPool(parentVault, 3000, 60, 0);
    }

    function skip_testRegisterRootPoolTwiceReverts() public {
        address parentVault = vaultFactory.deployVault(address(parentCollection), "Parent Token", "PRMT");

        _initializeRootPool(parentVault, 3000, 60, SQRT_PRICE_1_1);

        vm.expectRevert(abi.encodeWithSelector(DerivativeFactory.ParentVaultAlreadyInitialized.selector, parentVault));
        _initializeRootPool(parentVault, 3000, 60, SQRT_PRICE_1_1);
    }

    function testCreateDerivativeWithZeroSqrtPrice() public {
        address parentVault = vaultFactory.deployVault(address(parentCollection), "Parent Token", "PRMT");
        _initializeRootPool(parentVault, 3000, 60, SQRT_PRICE_1_1);

        DerivativeFactory.DerivativeParams memory params;
        params.parentCollection = address(parentCollection);
        params.nftName = "Derivative";
        params.nftSymbol = "DRV";
        params.nftBaseUri = "ipfs://";
        params.vaultName = "Token";
        params.vaultSymbol = "TT";
        params.fee = 3000;
        params.tickSpacing = 60;
        params.sqrtPriceX96 = 0; // Invalid
        params.maxSupply = 1;
        params.tickLower = -60;
        params.tickUpper = 60;
        params.liquidity = 1;

        vm.expectRevert(DerivativeFactory.InvalidSqrtPrice.selector);
        factory.createDerivative(params);
    }

    function testCreateDerivativeWithInvalidTickRange() public {
        address parentVault = vaultFactory.deployVault(address(parentCollection), "Parent Token", "PRMT");
        _initializeRootPool(parentVault, 3000, 60, SQRT_PRICE_1_1);

        DerivativeFactory.DerivativeParams memory params;
        params.parentCollection = address(parentCollection);
        params.nftName = "Derivative";
        params.nftSymbol = "DRV";
        params.nftBaseUri = "ipfs://";
        params.vaultName = "Token";
        params.vaultSymbol = "TT";
        params.fee = 3000;
        params.tickSpacing = 60;
        params.sqrtPriceX96 = SQRT_PRICE_1_1;
        params.maxSupply = 1;
        params.tickLower = 60; // Lower >= Upper
        params.tickUpper = 60;
        params.liquidity = 1;

        vm.expectRevert(DerivativeFactory.InvalidTickRange.selector);
        factory.createDerivative(params);
    }

    function testCreateDerivativeWithZeroLiquidity() public {
        address parentVault = vaultFactory.deployVault(address(parentCollection), "Parent Token", "PRMT");
        _initializeRootPool(parentVault, 3000, 60, SQRT_PRICE_1_1);

        DerivativeFactory.DerivativeParams memory params;
        params.parentCollection = address(parentCollection);
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
        params.liquidity = 0; // Invalid

        vm.expectRevert(DerivativeFactory.ZeroLiquidity.selector);
        factory.createDerivative(params);
    }

    function testCreateDerivativeWithNoParentTokenApproval() public {
        address parentVault = vaultFactory.deployVault(address(parentCollection), "Parent Token", "PRMT");
        _initializeRootPool(parentVault, 3000, 60, SQRT_PRICE_1_1);

        // Mint parent tokens but don't approve factory
        uint256[] memory tokenIds = new uint256[](10);
        for (uint256 i; i < 10; ++i) {
            parentCollection.mint(address(this), i + 1);
            tokenIds[i] = i + 1;
        }
        parentCollection.setApprovalForAll(parentVault, true);
        RemyVault(parentVault).deposit(tokenIds, address(this));
        // Deliberately skip: RemyVault(parentVault).approve(address(factory), type(uint256).max);

        DerivativeFactory.DerivativeParams memory params;
        params.parentCollection = address(parentCollection);
        params.nftName = "Derivative";
        params.nftSymbol = "DRV";
        params.nftBaseUri = "ipfs://";
        params.vaultName = "Token";
        params.vaultSymbol = "TT";
        params.fee = 3000;
        params.tickSpacing = 60;
        params.sqrtPriceX96 = SQRT_PRICE_1_1;
        params.maxSupply = 10;
        params.tickLower = -60;
        params.tickUpper = 60;
        params.liquidity = 1e3;
        params.parentTokenContribution = 5 * 1e18;

        vm.expectRevert(); // Should fail on transferFrom
        factory.createDerivative(params);
    }

    function testCreateDerivativeWithZeroMaxSupply() public {
        address parentVault = vaultFactory.deployVault(address(parentCollection), "Parent Token", "PRMT");
        _initializeRootPool(parentVault, 3000, 60, SQRT_PRICE_1_1);

        // Mint parent tokens
        uint256[] memory tokenIds = new uint256[](10);
        for (uint256 i; i < 10; ++i) {
            parentCollection.mint(address(this), i + 1);
            tokenIds[i] = i + 1;
        }
        parentCollection.setApprovalForAll(parentVault, true);
        RemyVault(parentVault).deposit(tokenIds, address(this));
        RemyVault(parentVault).approve(address(factory), type(uint256).max);

        DerivativeFactory.DerivativeParams memory params;
        params.parentCollection = address(parentCollection);
        params.nftName = "Derivative";
        params.nftSymbol = "DRV";
        params.nftBaseUri = "ipfs://";
        params.vaultName = "Token";
        params.vaultSymbol = "TT";
        params.fee = 3000;
        params.tickSpacing = 60;
        params.sqrtPriceX96 = SQRT_PRICE_1_1;
        params.maxSupply = 0; // Zero supply
        params.tickLower = -60;
        params.tickUpper = 60;
        params.liquidity = 0; // Cannot provide liquidity with zero supply
        params.parentTokenContribution = 0; // No contribution needed

        // Should revert - zero liquidity is invalid
        vm.expectRevert(DerivativeFactory.ZeroLiquidity.selector);
        factory.createDerivative(params);
    }

    function testParentTokenRefundWhenNotFullyConsumed() public {
        address parentVault = vaultFactory.deployVault(address(parentCollection), "Parent Token", "PRMT");
        _initializeRootPool(parentVault, 3000, 60, SQRT_PRICE_1_1);

        // Mint parent tokens
        uint256[] memory tokenIds = new uint256[](100);
        for (uint256 i; i < 100; ++i) {
            parentCollection.mint(address(this), i + 1);
            tokenIds[i] = i + 1;
        }
        parentCollection.setApprovalForAll(parentVault, true);
        RemyVault(parentVault).deposit(tokenIds, address(this));
        RemyVault(parentVault).approve(address(factory), type(uint256).max);

        address refundRecipient = makeAddr("refundRecipient");
        uint256 parentBalanceBefore = RemyVault(parentVault).balanceOf(address(this));

        DerivativeFactory.DerivativeParams memory params;
        params.parentCollection = address(parentCollection);
        params.nftName = "Derivative";
        params.nftSymbol = "DRV";
        params.nftBaseUri = "ipfs://";
        params.vaultName = "Token";
        params.vaultSymbol = "TT";
        params.fee = 3000;
        params.tickSpacing = 60;
        params.sqrtPriceX96 = SQRT_PRICE_1_1;
        params.maxSupply = 50;
        params.tickLower = -60;
        params.tickUpper = 60;
        params.liquidity = 1e3;
        params.parentTokenContribution = 100 * 1e18; // Provide more than needed
        params.parentTokenRefundRecipient = refundRecipient;
        params.salt = bytes32(0);

        factory.createDerivative(params);

        // Refund recipient should receive leftover parent tokens
        uint256 refundBalance = RemyVault(parentVault).balanceOf(refundRecipient);
        assertGt(refundBalance, 0, "refund recipient should receive leftover tokens");

        // Test contract should have less than before (some consumed)
        uint256 parentBalanceAfter = RemyVault(parentVault).balanceOf(address(this));
        assertLt(parentBalanceAfter, parentBalanceBefore, "parent balance should decrease");
    }

    function testDerivativeTokenRecipientReceivesTokens() public {
        address parentVault = vaultFactory.deployVault(address(parentCollection), "Parent Token", "PRMT");
        _initializeRootPool(parentVault, 3000, 60, SQRT_PRICE_1_1);

        // Mint parent tokens
        uint256[] memory tokenIds = new uint256[](100);
        for (uint256 i; i < 100; ++i) {
            parentCollection.mint(address(this), i + 1);
            tokenIds[i] = i + 1;
        }
        parentCollection.setApprovalForAll(parentVault, true);
        RemyVault(parentVault).deposit(tokenIds, address(this));
        RemyVault(parentVault).approve(address(factory), type(uint256).max);

        address derivativeRecipient = makeAddr("derivativeRecipient");

        DerivativeFactory.DerivativeParams memory params;
        params.parentCollection = address(parentCollection);
        params.nftName = "Derivative";
        params.nftSymbol = "DRV";
        params.nftBaseUri = "ipfs://";
        params.vaultName = "Token";
        params.vaultSymbol = "TT";
        params.fee = 3000;
        params.tickSpacing = 60;
        params.sqrtPriceX96 = SQRT_PRICE_1_1;
        params.maxSupply = 50;
        params.tickLower = -60;
        params.tickUpper = 60;
        params.liquidity = 1e3;
        params.parentTokenContribution = 100 * 1e18;
        params.derivativeTokenRecipient = derivativeRecipient;

        (, address derivativeVault,) = factory.createDerivative(params);

        MinterRemyVault derivative = MinterRemyVault(derivativeVault);
        uint256 recipientBalance = derivative.balanceOf(derivativeRecipient);
        assertGt(recipientBalance, 0, "derivative recipient should receive tokens");
        assertEq(derivative.balanceOf(address(factory)), 0, "factory should not retain tokens");
    }

    function testCreateDerivativeDefaultsToNftOwnerWhenNoRecipient() public {
        address parentVault = vaultFactory.deployVault(address(parentCollection), "Parent Token", "PRMT");
        _initializeRootPool(parentVault, 3000, 60, SQRT_PRICE_1_1);

        // Mint parent tokens
        uint256[] memory tokenIds = new uint256[](100);
        for (uint256 i; i < 100; ++i) {
            parentCollection.mint(address(this), i + 1);
            tokenIds[i] = i + 1;
        }
        parentCollection.setApprovalForAll(parentVault, true);
        RemyVault(parentVault).deposit(tokenIds, address(this));
        RemyVault(parentVault).approve(address(factory), type(uint256).max);

        address nftOwner = makeAddr("nftOwner");

        DerivativeFactory.DerivativeParams memory params;
        params.parentCollection = address(parentCollection);
        params.nftName = "Derivative";
        params.nftSymbol = "DRV";
        params.nftBaseUri = "ipfs://";
        params.nftOwner = nftOwner;
        params.vaultName = "Token";
        params.vaultSymbol = "TT";
        params.fee = 3000;
        params.tickSpacing = 60;
        params.sqrtPriceX96 = SQRT_PRICE_1_1;
        params.maxSupply = 50;
        params.tickLower = -60;
        params.tickUpper = 60;
        params.liquidity = 1e3;
        params.parentTokenContribution = 50 * 1e18;
        // Don't set derivativeTokenRecipient - should default to nftOwner

        (, address derivativeVault,) = factory.createDerivative(params);

        MinterRemyVault derivative = MinterRemyVault(derivativeVault);
        uint256 ownerBalance = derivative.balanceOf(nftOwner);
        assertGt(ownerBalance, 0, "nft owner should receive derivative tokens by default");
    }

    function skip_testRootPoolQuery() public {
        address parentVault = vaultFactory.deployVault(address(parentCollection), "Parent Token", "PRMT");

        // Should revert before registration
        vm.expectRevert(abi.encodeWithSelector(DerivativeFactory.ParentVaultNotRegistered.selector, parentVault));
        factory.rootPool(parentVault);

        // Register pool
        PoolId registeredId = _initializeRootPool(parentVault, 3000, 60, SQRT_PRICE_1_1);

        // Should succeed after registration
        (PoolKey memory key, PoolId poolId) = factory.rootPool(parentVault);
        assertEq(PoolId.unwrap(poolId), PoolId.unwrap(registeredId));
        assertEq(Currency.unwrap(key.currency1), parentVault);
    }

    // Removed testOnlyOwnerCanRegisterRootPool - root pool creation is now permissionless

    function testOnlyOwnerCanCreateVaultForCollection() public {
        address attacker = makeAddr("attacker");
        vm.prank(attacker);
        vm.expectRevert(Ownable.Unauthorized.selector);
        factory.createVaultForCollection(address(parentCollection), "Parent Token", "PRMT", 60, SQRT_PRICE_1_1);
    }

    function skip_testHookOwnershipRequired() public {
        // Transfer hook ownership away from factory
        vm.prank(address(factory));
        hook.transferOwnership(address(this));

        address parentVault = vaultFactory.deployVault(address(parentCollection), "Parent Token", "PRMT");

        vm.expectRevert(DerivativeFactory.HookOwnershipMissing.selector);
        _initializeRootPool(parentVault, 3000, 60, SQRT_PRICE_1_1);
    }

    /// @notice Comprehensive test exploring various price ranges and liquidity amounts for derivative launches
    function testDerivativeLaunchScenarios() public {
        address parentVault = vaultFactory.deployVault(address(parentCollection), "Parent Token", "PRMT");
        _initializeRootPool(parentVault, 3000, 60, SQRT_PRICE_1_1);

        // Mint large inventory for parent vault
        uint256[] memory tokenIds = new uint256[](1000);
        for (uint256 i; i < tokenIds.length; ++i) {
            parentCollection.mint(address(this), i + 1);
            tokenIds[i] = i + 1;
        }
        parentCollection.setApprovalForAll(parentVault, true);
        RemyVault(parentVault).deposit(tokenIds, address(this));
        RemyVault(parentVault).approve(address(factory), type(uint256).max);

        // Scenario configurations: (name, tickLower, tickUpper, liquidity, parentContribution, maxSupply)
        _testScenario("Narrow Range - Small Size", parentVault, -60, 60, 1e3, 5 * 1e18, 10);
        _testScenario("Narrow Range - Medium Size", parentVault, -60, 60, 1e5, 20 * 1e18, 50);
        _testScenario("Narrow Range - Large Size", parentVault, -60, 60, 1e7, 100 * 1e18, 200);

        _testScenario("Medium Range - Small Size", parentVault, -120, 120, 1e3, 5 * 1e18, 10);
        _testScenario("Medium Range - Medium Size", parentVault, -120, 120, 1e5, 20 * 1e18, 50);
        _testScenario("Medium Range - Large Size", parentVault, -120, 120, 1e7, 100 * 1e18, 200);

        _testScenario("Wide Range - Small Size", parentVault, -300, 300, 1e3, 10 * 1e18, 10);
        _testScenario("Wide Range - Medium Size", parentVault, -300, 300, 1e5, 30 * 1e18, 50);
        _testScenario("Wide Range - Large Size", parentVault, -300, 300, 1e7, 150 * 1e18, 200);

        _testScenario("Very Wide Range - Medium Size", parentVault, -600, 600, 1e5, 50 * 1e18, 50);
        _testScenario("Very Wide Range - Large Size", parentVault, -600, 600, 1e7, 200 * 1e18, 200);

        _testScenario("Ultra Wide Range - Large Size", parentVault, -1200, 1200, 1e7, 300 * 1e18, 200);

        // Test asymmetric ranges (still include current price, using tick spacing of 60)
        console.log("\n\n=== TESTING ASYMMETRIC RANGES (INCLUDING CURRENT PRICE) ===\n");
        _testScenario("Asymmetric Above", parentVault, -60, 240, 1e5, 30 * 1e18, 50);
        _testScenario("Asymmetric Below", parentVault, -240, 60, 1e5, 30 * 1e18, 50);
        _testScenario("Mostly Above", parentVault, -60, 360, 1e5, 40 * 1e18, 50);
        _testScenario("Mostly Below", parentVault, -360, 60, 1e5, 40 * 1e18, 50);
    }

    function _testScenario(
        string memory name,
        address parentVault,
        int24 tickLower,
        int24 tickUpper,
        uint128 liquidity,
        uint256 parentContribution,
        uint256 maxSupply
    ) internal {
        console.log("\n========================================");
        console.log("SCENARIO:", name);
        console.log("========================================");

        uint256 parentBalanceBefore = RemyVault(parentVault).balanceOf(address(this));

        address recipient = makeAddr(string.concat("recipient_", name));

        DerivativeFactory.DerivativeParams memory params;
        params.parentCollection = address(parentCollection);
        params.nftName = string.concat("Derivative ", name);
        params.nftSymbol = "DRV";
        params.nftBaseUri = "ipfs://test/";
        params.nftOwner = recipient;
        params.vaultName = string.concat("Token ", name);
        params.vaultSymbol = "dDRV";
        params.fee = 3000;
        params.tickSpacing = 60;
        params.sqrtPriceX96 = SQRT_PRICE_1_1;
        params.maxSupply = maxSupply;
        params.tickLower = tickLower;
        params.tickUpper = tickUpper;
        params.liquidity = liquidity;
        params.parentTokenContribution = parentContribution;
        params.derivativeTokenRecipient = recipient;
        params.parentTokenRefundRecipient = address(this);
        params.salt = bytes32(0);

        console.log("\n--- CONFIGURATION ---");
        console.log("Max Supply (NFTs):", maxSupply);
        console.log("Target Liquidity:", liquidity);
        console.log("Tick Lower:", tickLower);
        console.log("Tick Upper:", tickUpper);
        console.log("Tick Width:", uint256(int256(tickUpper - tickLower)));
        console.log("Parent Contribution (tokens):", parentContribution / 1e18);

        (, address derivativeVault, PoolId childPoolId) = factory.createDerivative(params);

        MinterRemyVault derivativeToken = MinterRemyVault(derivativeVault);
        uint256 parentBalanceAfter = RemyVault(parentVault).balanceOf(address(this));
        uint256 parentBalanceRefunded = RemyVault(parentVault).balanceOf(address(this)) - (parentBalanceBefore - parentContribution);
        uint256 parentConsumed = parentContribution - parentBalanceRefunded;
        uint256 derivativeToRecipient = derivativeToken.balanceOf(recipient);
        uint256 derivativeTotalSupply = derivativeToken.totalSupply();

        console.log("\n--- TOKEN FLOWS ---");
        console.log("Parent Consumed (tokens):", parentConsumed / 1e18);
        console.log("Parent Refunded (tokens):", parentBalanceRefunded / 1e18);
        console.log("Parent Utilization (bps):", (parentConsumed * 10000) / parentContribution);
        console.log("Derivative Total Supply (tokens):", derivativeTotalSupply / 1e18);
        console.log("Derivative to Recipient (tokens):", derivativeToRecipient / 1e18);
        console.log("Derivative in Pool (tokens):", (derivativeTotalSupply - derivativeToRecipient) / 1e18);

        bool derivativeIsCurrency0 = Currency.unwrap(_buildKey(derivativeVault, parentVault, 3000, 60).currency0) == derivativeVault;

        console.log("\n--- LIQUIDITY POSITION DEBUG ---");
        console.log("Requested Tick Lower:", tickLower);
        console.log("Requested Tick Upper:", tickUpper);
        console.log("Derivative is Currency0:", derivativeIsCurrency0);

        // The factory now passes ticks as-is, so we check the position with the original ticks
        (uint128 actualLiquidity,,) = manager.getPositionInfo(childPoolId, address(factory), tickLower, tickUpper, bytes32(0));
        (uint160 poolSqrtPrice,,,) = manager.getSlot0(childPoolId);

        // Check if range includes current price
        bool rangeIncludesCurrentPrice = (tickLower <= 0 && tickUpper >= 0);

        console.log("\n--- POOL STATE ---");
        console.log("Actual Liquidity:", actualLiquidity);
        if (actualLiquidity > 0) {
            console.log("Liquidity Efficiency (bps):", (uint256(actualLiquidity) * 10000) / uint256(liquidity));
        } else {
            console.log("Liquidity Efficiency (bps): N/A - zero liquidity");
        }
        console.log("Pool SqrtPriceX96:", poolSqrtPrice);
        console.log("Price Maintained:", poolSqrtPrice == SQRT_PRICE_1_1);
        console.log("Derivative is Currency0:", derivativeIsCurrency0);
        console.log("Range Includes Current Price (tick 0):", rangeIncludesCurrentPrice);

        if (rangeIncludesCurrentPrice) {
            console.log("ACTIVE RANGE: Liquidity is active at current price");
        } else if (tickUpper < 0) {
            console.log("BELOW RANGE: Price is above this range (provides only parent tokens)");
        } else if (tickLower > 0) {
            console.log("ABOVE RANGE: Price is below this range (provides only derivative tokens)");
        }

        // Verify liquidity behavior
        if (rangeIncludesCurrentPrice) {
            assertGt(actualLiquidity, 0, "No liquidity added despite range including current price");
        } else {
            console.log("\nWARNING: Asymmetric range does not include current price - liquidity may be zero");
            console.log("This is EXPECTED Uniswap V3 behavior for out-of-range positions");
        }
        assertEq(poolSqrtPrice, SQRT_PRICE_1_1, "Price changed unexpectedly");
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
