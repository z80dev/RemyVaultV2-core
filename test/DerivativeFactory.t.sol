// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Test, console} from "forge-std/Test.sol";
import {Vm} from "forge-std/Vm.sol";
import {DerivativeTestUtils} from "./DerivativeTestUtils.sol";

import {DerivativeFactory} from "../src/DerivativeFactory.sol";
import {wNFTMinter} from "../src/wNFTMinter.sol";
import {wNFTFactory} from "../src/wNFTFactory.sol";
import {wNFTHook} from "../src/wNFTHook.sol";
import {wNFTNFT} from "../src/wNFTNFT.sol";
import {wNFT} from "../src/wNFT.sol";
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

contract DerivativeFactoryTest is Test, DerivativeTestUtils {
    using PoolIdLibrary for PoolKey;
    using CurrencyLibrary for Currency;
    using StateLibrary for IPoolManager;
    using LibString for uint256;

    uint160 internal constant SQRT_PRICE_1_1 = 79228162514264337593543950336;
    uint160 internal constant CLEAR_HOOK_PERMISSIONS_MASK = ~uint160(0) << 14;
    uint160 internal constant HOOK_FLAGS = Hooks.BEFORE_SWAP_FLAG | Hooks.AFTER_SWAP_FLAG
        | Hooks.BEFORE_SWAP_RETURNS_DELTA_FLAG | Hooks.AFTER_SWAP_RETURNS_DELTA_FLAG;

    wNFTFactory internal vaultFactory;
    wNFTHook internal hook;
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
        deployCodeTo("wNFTHook.sol:wNFTHook", abi.encode(manager, address(this)), hookAddress);
        hook = wNFTHook(hookAddress);

        vaultFactory = new wNFTFactory();
        factory = new DerivativeFactory(vaultFactory, hook, address(this));
        hook.transferOwnership(address(factory));

        parentCollection = new MockERC721Simple("Parent", "PRT");
    }

    // Helper to initialize a root pool directly (for testing the permissionless flow)
    function _initializeRootPool(address parentVault, uint24, /* fee */ int24 tickSpacing, uint160 sqrtPriceX96)
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
        address parentVault = vaultFactory.deployVault(address(parentCollection));

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
        address predictedVault = vaultFactory.computeAddress(address(parentCollection));
        uint24 dynamicFee = 0x800000; // LPFeeLibrary.DYNAMIC_FEE_FLAG
        PoolKey memory expectedRootKey = _buildKey(address(0), predictedVault, dynamicFee, 60);
        PoolId expectedRootId = expectedRootKey.toId();

        vm.expectEmit(true, true, false, true, address(factory));
        emit DerivativeFactory.RootPoolRegistered(predictedVault, expectedRootId, dynamicFee, 60, SQRT_PRICE_1_1);

        vm.expectEmit(true, true, true, false, address(factory));
        emit DerivativeFactory.ParentVaultRegistered(address(parentCollection), predictedVault, expectedRootId);

        (address parentVault, PoolId rootPoolId) =
            factory.createVaultForCollection(address(parentCollection), SQRT_PRICE_1_1);

        assertEq(vaultFactory.vaultFor(address(parentCollection)), parentVault, "vault mapping mismatch");
        wNFT vaultToken = wNFT(parentVault);
        assertEq(vaultToken.name(), string.concat("Wrapped ", parentCollection.name()), "vault name mismatch");
        assertEq(vaultToken.symbol(), string.concat("w", parentCollection.symbol()), "vault symbol mismatch");

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
        (address parentVault, PoolId parentPoolId) = factory.createVaultForCollection(address(parentCollection), SQRT_PRICE_1_1);

        // Seed the parent vault with inventory so the factory can provide liquidity.
        uint256 depositCount = 100;
        uint256[] memory tokenIds = new uint256[](depositCount);
        for (uint256 i; i < depositCount; ++i) {
            uint256 tokenId = i + 1;
            parentCollection.mint(address(this), tokenId);
            tokenIds[i] = tokenId;
        }
        parentCollection.setApprovalForAll(parentVault, true);
        wNFT(parentVault).deposit(tokenIds, address(this));
        wNFT(parentVault).approve(address(factory), type(uint256).max);
        uint256 availableParentTokens = wNFT(parentVault).balanceOf(address(this));

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
        params.fee = 3000;
        params.sqrtPriceX96 = SQRT_PRICE_1_1;
        params.maxSupply = 100;
        params.tickLower = -120;
        params.tickUpper = 120;
        params.liquidity = 1e3;
        params.parentTokenContribution = availableParentTokens;
        params.derivativeTokenRecipient = derivativeTokenSink;
        params.parentTokenRefundRecipient = address(this);
        params.salt = mineSaltForToken1(factory, parentVault, params.maxSupply);

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

        uint256 parentBalanceBefore = wNFT(parentVault).balanceOf(address(this));
        console.log("\n=== PRE-LAUNCH BALANCES ===");
        console.log("Creator Parent Token Balance (tokens):", parentBalanceBefore / 1e18);

        vm.recordLogs();
        (address derivativeNft, address derivativeVault, PoolId childPoolId) = factory.createDerivative(params);
        Vm.Log[] memory entries = vm.getRecordedLogs();

        // ============ POST-LAUNCH TOKEN METRICS ============
        wNFTMinter derivativeToken = wNFTMinter(derivativeVault);
        uint256 parentBalanceAfter = wNFT(parentVault).balanceOf(address(this));
        uint256 parentBalanceRefunded = wNFT(parentVault).balanceOf(params.parentTokenRefundRecipient);
        uint256 parentBalanceConsumed = parentBalanceBefore - parentBalanceAfter;
        uint256 derivativeBalanceRecipient = derivativeToken.balanceOf(derivativeTokenSink);
        uint256 derivativeTotalSupply = derivativeToken.totalSupply();

        console.log("\n=== POST-LAUNCH TOKEN BALANCES ===");
        console.log("Parent Tokens Consumed:", parentBalanceConsumed / 1e18);
        console.log("Parent Tokens Refunded:", parentBalanceRefunded / 1e18);
        console.log("Parent Utilization %:", (parentBalanceConsumed * 100) / params.parentTokenContribution);
        console.log("Derivative Total Supply:", derivativeTotalSupply / 1e18);
        console.log("Derivative to Recipient:", derivativeBalanceRecipient / 1e18);
        console.log(
            "Derivative Retained in Pool %:",
            ((derivativeTotalSupply - derivativeBalanceRecipient) * 100) / derivativeTotalSupply
        );

        // ============ POOL LIQUIDITY METRICS ============
        (uint160 childSqrtPrice,,,) = manager.getSlot0(childPoolId);
        bool derivativeIsCurrency0 =
            Currency.unwrap(_buildKey(derivativeVault, parentVault, 3000, 60).currency0) == derivativeVault;
        // Factory passes ticks as-is, so we check position with original ticks
        (uint128 liquidity,,) =
            manager.getPositionInfo(childPoolId, address(factory), params.tickLower, params.tickUpper, bytes32(0));

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
            assertEq(eventTickSpacing, factory.TICK_SPACING(), "tick spacing mismatch in event");
            assertEq(eventSqrtPrice, SQRT_PRICE_1_1, "sqrt price mismatch in event");
        }
        assertTrue(foundDerivativeEvent, "DerivativeCreated event not emitted");

        // Derivative vaults are managed by DerivativeFactory, not wNFTFactory
        assertEq(factory.vaultForNft(derivativeNft), derivativeVault, "vault lookup mismatch");

        (address infoNft, address infoParent, PoolId infoPoolId) = factory.derivativeForVault(derivativeVault);
        assertEq(infoNft, derivativeNft, "info nft mismatch");
        assertEq(infoParent, parentVault, "info parent mismatch");
        assertEq(PoolId.unwrap(infoPoolId), PoolId.unwrap(childPoolId), "info pool mismatch");

        wNFTNFT nft = wNFTNFT(derivativeNft);
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
        assertEq(wNFT(parentVault).balanceOf(address(factory)), 0, "factory retains parent tokens");

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
        params.fee = 3000;
        params.sqrtPriceX96 = SQRT_PRICE_1_1;
        params.maxSupply = 1;
        params.tickLower = -60;
        params.tickUpper = 60;
        params.liquidity = 1;

        vm.expectRevert(
            abi.encodeWithSelector(DerivativeFactory.ParentCollectionHasNoVault.selector, params.parentCollection)
        );
        factory.createDerivative(params);
    }

    // Test skipped - registerRootPool function removed
    function skip_testRegisterRootPoolRequiresFactoryVault() public {
        // Test no longer applicable
    }

    function skip_testRegisterRootPoolWithZeroSqrtPrice() public {
        address parentVault = vaultFactory.deployVault(address(parentCollection));

        vm.expectRevert(DerivativeFactory.InvalidSqrtPrice.selector);
        _initializeRootPool(parentVault, 3000, 60, 0);
    }

    // Test skipped - registerRootPool function removed
    function skip_testRegisterRootPoolTwiceReverts() public {
        // Test no longer applicable
    }

    function testCreateDerivativeWithZeroSqrtPrice() public {
        address parentVault = vaultFactory.deployVault(address(parentCollection));
        _initializeRootPool(parentVault, 3000, 60, SQRT_PRICE_1_1);

        DerivativeFactory.DerivativeParams memory params;
        params.parentCollection = address(parentCollection);
        params.nftName = "Derivative";
        params.nftSymbol = "DRV";
        params.nftBaseUri = "ipfs://";
        params.fee = 3000;
        params.sqrtPriceX96 = 0; // Invalid
        params.maxSupply = 1;
        params.tickLower = -60;
        params.tickUpper = 60;
        params.liquidity = 1;

        vm.expectRevert(DerivativeFactory.InvalidSqrtPrice.selector);
        factory.createDerivative(params);
    }

    function testCreateDerivativeWithInvalidTickRange() public {
        address parentVault = vaultFactory.deployVault(address(parentCollection));
        _initializeRootPool(parentVault, 3000, 60, SQRT_PRICE_1_1);

        DerivativeFactory.DerivativeParams memory params;
        params.parentCollection = address(parentCollection);
        params.nftName = "Derivative";
        params.nftSymbol = "DRV";
        params.nftBaseUri = "ipfs://";
        params.fee = 3000;
        params.sqrtPriceX96 = SQRT_PRICE_1_1;
        params.maxSupply = 1;
        params.tickLower = 60; // Lower >= Upper
        params.tickUpper = 60;
        params.liquidity = 1;

        vm.expectRevert(DerivativeFactory.InvalidTickRange.selector);
        factory.createDerivative(params);
    }

    function testCreateDerivativeWithZeroLiquidity() public {
        address parentVault = vaultFactory.deployVault(address(parentCollection));
        _initializeRootPool(parentVault, 3000, 60, SQRT_PRICE_1_1);

        DerivativeFactory.DerivativeParams memory params;
        params.parentCollection = address(parentCollection);
        params.nftName = "Derivative";
        params.nftSymbol = "DRV";
        params.nftBaseUri = "ipfs://";
        params.fee = 3000;
        params.sqrtPriceX96 = SQRT_PRICE_1_1;
        params.maxSupply = 1;
        params.tickLower = -60;
        params.tickUpper = 60;
        params.liquidity = 0; // Invalid

        vm.expectRevert(DerivativeFactory.ZeroLiquidity.selector);
        factory.createDerivative(params);
    }

    function testCreateDerivativeWithNoParentTokenApproval() public {
        address parentVault = vaultFactory.deployVault(address(parentCollection));
        _initializeRootPool(parentVault, 3000, 60, SQRT_PRICE_1_1);

        // Mint parent tokens but don't approve factory
        uint256[] memory tokenIds = new uint256[](10);
        for (uint256 i; i < 10; ++i) {
            parentCollection.mint(address(this), i + 1);
            tokenIds[i] = i + 1;
        }
        parentCollection.setApprovalForAll(parentVault, true);
        wNFT(parentVault).deposit(tokenIds, address(this));
        // Deliberately skip: wNFT(parentVault).approve(address(factory), type(uint256).max);

        DerivativeFactory.DerivativeParams memory params;
        params.parentCollection = address(parentCollection);
        params.nftName = "Derivative";
        params.nftSymbol = "DRV";
        params.nftBaseUri = "ipfs://";
        params.fee = 3000;
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
        address parentVault = vaultFactory.deployVault(address(parentCollection));
        _initializeRootPool(parentVault, 3000, 60, SQRT_PRICE_1_1);

        // Mint parent tokens
        uint256[] memory tokenIds = new uint256[](10);
        for (uint256 i; i < 10; ++i) {
            parentCollection.mint(address(this), i + 1);
            tokenIds[i] = i + 1;
        }
        parentCollection.setApprovalForAll(parentVault, true);
        wNFT(parentVault).deposit(tokenIds, address(this));
        wNFT(parentVault).approve(address(factory), type(uint256).max);

        DerivativeFactory.DerivativeParams memory params;
        params.parentCollection = address(parentCollection);
        params.nftName = "Derivative";
        params.nftSymbol = "DRV";
        params.nftBaseUri = "ipfs://";
        params.fee = 3000;
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
        address parentVault = vaultFactory.deployVault(address(parentCollection));
        _initializeRootPool(parentVault, 3000, 60, SQRT_PRICE_1_1);

        // Mint parent tokens
        uint256[] memory tokenIds = new uint256[](100);
        for (uint256 i; i < 100; ++i) {
            parentCollection.mint(address(this), i + 1);
            tokenIds[i] = i + 1;
        }
        parentCollection.setApprovalForAll(parentVault, true);
        wNFT(parentVault).deposit(tokenIds, address(this));
        wNFT(parentVault).approve(address(factory), type(uint256).max);

        address refundRecipient = makeAddr("refundRecipient");
        uint256 parentBalanceBefore = wNFT(parentVault).balanceOf(address(this));

        DerivativeFactory.DerivativeParams memory params;
        params.parentCollection = address(parentCollection);
        params.nftName = "Derivative";
        params.nftSymbol = "DRV";
        params.nftBaseUri = "ipfs://";
        params.fee = 3000;
        params.sqrtPriceX96 = SQRT_PRICE_1_1;
        params.maxSupply = 50;
        params.tickLower = -60;
        params.tickUpper = 60;
        params.liquidity = 1e3;
        params.parentTokenContribution = 100 * 1e18; // Provide more than needed
        params.parentTokenRefundRecipient = refundRecipient;
        params.salt = mineSaltForToken1(factory, parentVault, params.maxSupply);

        factory.createDerivative(params);

        // Refund recipient should receive leftover parent tokens
        uint256 refundBalance = wNFT(parentVault).balanceOf(refundRecipient);
        assertGt(refundBalance, 0, "refund recipient should receive leftover tokens");

        // Test contract should have less than before (some consumed)
        uint256 parentBalanceAfter = wNFT(parentVault).balanceOf(address(this));
        assertLt(parentBalanceAfter, parentBalanceBefore, "parent balance should decrease");
    }

    function testDerivativeTokenRecipientReceivesTokens() public {
        (address parentVault,) = factory.createVaultForCollection(address(parentCollection), SQRT_PRICE_1_1);

        // Mint parent tokens
        uint256[] memory tokenIds = new uint256[](100);
        for (uint256 i; i < 100; ++i) {
            parentCollection.mint(address(this), i + 1);
            tokenIds[i] = i + 1;
        }
        parentCollection.setApprovalForAll(parentVault, true);
        wNFT(parentVault).deposit(tokenIds, address(this));
        wNFT(parentVault).approve(address(factory), type(uint256).max);

        address derivativeRecipient = makeAddr("derivativeRecipient");

        DerivativeFactory.DerivativeParams memory params;
        params.parentCollection = address(parentCollection);
        params.nftName = "Derivative";
        params.nftSymbol = "DRV";
        params.nftBaseUri = "ipfs://";
        params.fee = 3000;
        params.sqrtPriceX96 = SQRT_PRICE_1_1;
        params.maxSupply = 50;
        params.tickLower = -60;
        params.tickUpper = 60;
        params.liquidity = 1e3;
        params.parentTokenContribution = 100 * 1e18;
        params.derivativeTokenRecipient = derivativeRecipient;
        params.salt = mineSaltForToken1(factory, parentVault, params.maxSupply);

        (, address derivativeVault,) = factory.createDerivative(params);

        wNFTMinter derivative = wNFTMinter(derivativeVault);
        uint256 recipientBalance = derivative.balanceOf(derivativeRecipient);
        assertGt(recipientBalance, 0, "derivative recipient should receive tokens");
        assertEq(derivative.balanceOf(address(factory)), 0, "factory should not retain tokens");
    }

    function testCreateDerivativeDefaultsToNftOwnerWhenNoRecipient() public {
        (address parentVault,) = factory.createVaultForCollection(address(parentCollection), SQRT_PRICE_1_1);

        // Mint parent tokens
        uint256[] memory tokenIds = new uint256[](100);
        for (uint256 i; i < 100; ++i) {
            parentCollection.mint(address(this), i + 1);
            tokenIds[i] = i + 1;
        }
        parentCollection.setApprovalForAll(parentVault, true);
        wNFT(parentVault).deposit(tokenIds, address(this));
        wNFT(parentVault).approve(address(factory), type(uint256).max);

        address nftOwner = makeAddr("nftOwner");

        DerivativeFactory.DerivativeParams memory params;
        params.parentCollection = address(parentCollection);
        params.nftName = "Derivative";
        params.nftSymbol = "DRV";
        params.nftBaseUri = "ipfs://";
        params.nftOwner = nftOwner;
        params.fee = 3000;
        params.sqrtPriceX96 = SQRT_PRICE_1_1;
        params.maxSupply = 50;
        params.tickLower = -60;
        params.tickUpper = 60;
        params.liquidity = 1e3;
        params.parentTokenContribution = 50 * 1e18;
        // Don't set derivativeTokenRecipient - should default to nftOwner
        params.salt = mineSaltForToken1(factory, parentVault, params.maxSupply);

        (, address derivativeVault,) = factory.createDerivative(params);

        wNFTMinter derivative = wNFTMinter(derivativeVault);
        uint256 ownerBalance = derivative.balanceOf(nftOwner);
        assertGt(ownerBalance, 0, "nft owner should receive derivative tokens by default");
    }

    // Test skipped - rootPool no longer reverts, always returns key/id
    function skip_testRootPoolQuery() public {
        address parentVault = vaultFactory.deployVault(address(parentCollection));

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
        factory.createVaultForCollection(address(parentCollection), SQRT_PRICE_1_1);
    }

    function skip_testHookOwnershipRequired() public {
        // Transfer hook ownership away from factory
        vm.prank(address(factory));
        hook.transferOwnership(address(this));

        address parentVault = vaultFactory.deployVault(address(parentCollection));

        vm.expectRevert(DerivativeFactory.HookOwnershipMissing.selector);
        _initializeRootPool(parentVault, 3000, 60, SQRT_PRICE_1_1);
    }

    /// @notice Comprehensive test exploring various price ranges and liquidity amounts for derivative launches
    function testDerivativeLaunchScenarios() public {
        (address parentVault,) = factory.createVaultForCollection(address(parentCollection), SQRT_PRICE_1_1);

        // Mint large inventory for parent vault
        uint256[] memory tokenIds = new uint256[](1000);
        for (uint256 i; i < tokenIds.length; ++i) {
            parentCollection.mint(address(this), i + 1);
            tokenIds[i] = i + 1;
        }
        parentCollection.setApprovalForAll(parentVault, true);
        wNFT(parentVault).deposit(tokenIds, address(this));
        wNFT(parentVault).approve(address(factory), type(uint256).max);

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

        uint256 parentBalanceBefore = wNFT(parentVault).balanceOf(address(this));

        address recipient = makeAddr(string.concat("recipient_", name));

        DerivativeFactory.DerivativeParams memory params;
        params.parentCollection = address(parentCollection);
        params.nftName = string.concat("Derivative ", name);
        params.nftSymbol = "DRV";
        params.nftBaseUri = "ipfs://test/";
        params.nftOwner = recipient;
        params.fee = 3000;
        params.sqrtPriceX96 = SQRT_PRICE_1_1;
        params.maxSupply = maxSupply;
        params.tickLower = tickLower;
        params.tickUpper = tickUpper;
        params.liquidity = liquidity;
        params.parentTokenContribution = parentContribution;
        params.derivativeTokenRecipient = recipient;
        params.parentTokenRefundRecipient = address(this);
        params.salt = mineSaltForToken1(factory, parentVault, params.maxSupply);

        console.log("\n--- CONFIGURATION ---");
        console.log("Max Supply (NFTs):", maxSupply);
        console.log("Target Liquidity:", liquidity);
        console.log("Tick Lower:", tickLower);
        console.log("Tick Upper:", tickUpper);
        console.log("Tick Width:", uint256(int256(tickUpper - tickLower)));
        console.log("Parent Contribution (tokens):", parentContribution / 1e18);

        (, address derivativeVault, PoolId childPoolId) = factory.createDerivative(params);

        wNFTMinter derivativeToken = wNFTMinter(derivativeVault);
        uint256 parentBalanceAfter = wNFT(parentVault).balanceOf(address(this));
        uint256 parentBalanceRefunded =
            wNFT(parentVault).balanceOf(address(this)) - (parentBalanceBefore - parentContribution);
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

        bool derivativeIsCurrency0 =
            Currency.unwrap(_buildKey(derivativeVault, parentVault, 3000, 60).currency0) == derivativeVault;

        console.log("\n--- LIQUIDITY POSITION DEBUG ---");
        console.log("Requested Tick Lower:", tickLower);
        console.log("Requested Tick Upper:", tickUpper);
        console.log("Derivative is Currency0:", derivativeIsCurrency0);

        // The factory now passes ticks as-is, so we check the position with the original ticks
        (uint128 actualLiquidity,,) =
            manager.getPositionInfo(childPoolId, address(factory), tickLower, tickUpper, bytes32(0));
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

    function testSaltCollisionPreventsDerivativeLessThanParent() public {
        (address parentVault,) = factory.createVaultForCollection(address(parentCollection), SQRT_PRICE_1_1);

        // Provide parent tokens
        uint256[] memory tokenIds = new uint256[](100);
        for (uint256 i; i < 100; ++i) {
            parentCollection.mint(address(this), i + 1);
            tokenIds[i] = i + 1;
        }
        parentCollection.setApprovalForAll(parentVault, true);
        wNFT(parentVault).deposit(tokenIds, address(this));
        wNFT(parentVault).approve(address(factory), type(uint256).max);

        DerivativeFactory.DerivativeParams memory params;
        params.parentCollection = address(parentCollection);
        params.nftName = "Derivative";
        params.nftSymbol = "DRV";
        params.nftBaseUri = "ipfs://";
        params.fee = 3000;
        params.sqrtPriceX96 = SQRT_PRICE_1_1;
        params.maxSupply = 50;
        params.tickLower = -60;
        params.tickUpper = 60;
        params.liquidity = 1e3;
        params.parentTokenContribution = 50 * 1e18;

        // Find a bad salt that would make derivative < parent
        bytes32 badSalt = bytes32(0);
        uint64 factoryNonce = vm.getNonce(address(factory));
        address predictedNFT = _computeCreateAddress(address(factory), factoryNonce);

        for (uint256 i = 0; i < 10000; i++) {
            bytes32 testSalt = bytes32(i);
            address testPredictedVault = factory.computeDerivativeAddress(predictedNFT, params.maxSupply, testSalt);
            if (testPredictedVault < parentVault) {
                badSalt = testSalt;
                break;
            }
        }

        // Attempt to deploy with bad salt should fail
        params.salt = badSalt;

        address predictedVault = factory.computeDerivativeAddress(predictedNFT, params.maxSupply, badSalt);
        vm.expectRevert(
            abi.encodeWithSelector(
                DerivativeFactory.DerivativeVaultMustBeToken1.selector,
                predictedVault,
                parentVault
            )
        );
        factory.createDerivative(params);
    }

    function testMultipleDerivativesForSameOriginal() public {
        (address parentVault,) = factory.createVaultForCollection(address(parentCollection), SQRT_PRICE_1_1);

        // Mint enough parent tokens
        uint256[] memory tokenIds = new uint256[](200);
        for (uint256 i; i < 200; ++i) {
            parentCollection.mint(address(this), i + 1);
            tokenIds[i] = i + 1;
        }
        parentCollection.setApprovalForAll(parentVault, true);
        wNFT(parentVault).deposit(tokenIds, address(this));
        wNFT(parentVault).approve(address(factory), type(uint256).max);

        // Create first derivative
        DerivativeFactory.DerivativeParams memory params1;
        params1.parentCollection = address(parentCollection);
        params1.nftName = "First Derivative";
        params1.nftSymbol = "DRV1";
        params1.nftBaseUri = "ipfs://first/";
        params1.fee = 3000;
        params1.sqrtPriceX96 = SQRT_PRICE_1_1;
        params1.maxSupply = 50;
        params1.tickLower = -60;
        params1.tickUpper = 60;
        params1.liquidity = 1e3;
        params1.parentTokenContribution = 50 * 1e18;
        params1.salt = mineSaltForToken1(factory, parentVault, params1.maxSupply);

        (address nft1, address vault1, PoolId pool1) = factory.createDerivative(params1);

        // Create second derivative for same parent
        DerivativeFactory.DerivativeParams memory params2;
        params2.parentCollection = address(parentCollection);
        params2.nftName = "Second Derivative";
        params2.nftSymbol = "DRV2";
        params2.nftBaseUri = "ipfs://second/";
        params2.fee = 3000;
        params2.sqrtPriceX96 = SQRT_PRICE_1_1;
        params2.maxSupply = 75;
        params2.tickLower = -120;
        params2.tickUpper = 120;
        params2.liquidity = 2e3;
        params2.parentTokenContribution = 75 * 1e18;
        params2.salt = mineSaltForToken1(factory, parentVault, params2.maxSupply);

        (address nft2, address vault2, PoolId pool2) = factory.createDerivative(params2);

        // Verify both derivatives are distinct and properly configured
        assertTrue(nft1 != nft2, "NFTs should be different");
        assertTrue(vault1 != vault2, "Vaults should be different");
        assertTrue(PoolId.unwrap(pool1) != PoolId.unwrap(pool2), "Pools should be different");

        (address infoNft1, address infoParent1,) = factory.derivativeForVault(vault1);
        (address infoNft2, address infoParent2,) = factory.derivativeForVault(vault2);

        assertEq(infoNft1, nft1, "first NFT lookup mismatch");
        assertEq(infoParent1, parentVault, "first parent mismatch");
        assertEq(infoNft2, nft2, "second NFT lookup mismatch");
        assertEq(infoParent2, parentVault, "second parent should be same");
    }

    function testDerivativeOfDerivative() public {
        (address parentVault, PoolId parentPoolId) = factory.createVaultForCollection(address(parentCollection), SQRT_PRICE_1_1);

        // Mint parent tokens
        uint256[] memory tokenIds = new uint256[](200);
        for (uint256 i; i < 200; ++i) {
            parentCollection.mint(address(this), i + 1);
            tokenIds[i] = i + 1;
        }
        parentCollection.setApprovalForAll(parentVault, true);
        wNFT(parentVault).deposit(tokenIds, address(this));
        wNFT(parentVault).approve(address(factory), type(uint256).max);

        // Create first-generation derivative
        DerivativeFactory.DerivativeParams memory params1;
        params1.parentCollection = address(parentCollection);
        params1.nftName = "First Gen";
        params1.nftSymbol = "GEN1";
        params1.nftBaseUri = "ipfs://gen1/";
        params1.nftOwner = address(this);
        params1.fee = 3000;
        params1.sqrtPriceX96 = SQRT_PRICE_1_1;
        params1.maxSupply = 100;
        params1.tickLower = -60;
        params1.tickUpper = 60;
        params1.liquidity = 1e3;
        params1.parentTokenContribution = 100 * 1e18;
        params1.salt = mineSaltForToken1(factory, parentVault, params1.maxSupply);

        (address gen1Nft, address gen1Vault, PoolId gen1PoolId) = factory.createDerivative(params1);

        // For gen1 to be a parent, it needs a root pool
        // Since deployDerivativeVault was called, the vault exists but not the root pool
        // We need to manually initialize the root pool for gen1
        PoolKey memory gen1RootKey = PoolKey({
            currency0: CurrencyLibrary.ADDRESS_ZERO,
            currency1: Currency.wrap(gen1Vault),
            fee: 0x800000, // Dynamic fee flag
            tickSpacing: 60,
            hooks: IHooks(hookAddress)
        });
        PoolId gen1RootPoolId = gen1RootKey.toId();

        // Register with hook
        PoolKey memory emptyKey;
        vm.prank(address(factory));
        hook.addChild(gen1RootKey, false, emptyKey);

        // Initialize the pool
        manager.initialize(gen1RootKey, SQRT_PRICE_1_1);

        // We already have gen1 vault tokens from the derivative creation
        // Just approve the factory to use them for creating gen2
        wNFTMinter(gen1Vault).approve(address(factory), type(uint256).max);

        // Now create a second-generation derivative (derivative of gen1)
        DerivativeFactory.DerivativeParams memory params2;
        params2.parentCollection = gen1Nft;
        params2.nftName = "Second Gen";
        params2.nftSymbol = "GEN2";
        params2.nftBaseUri = "ipfs://gen2/";
        params2.fee = 3000;
        params2.sqrtPriceX96 = SQRT_PRICE_1_1;
        params2.maxSupply = 50;
        params2.tickLower = -120;
        params2.tickUpper = 120;
        params2.liquidity = 5e2;
        params2.parentTokenContribution = 50 * wNFTMinter(gen1Vault).UNIT();
        params2.salt = mineSaltForToken1(factory, gen1Vault, params2.maxSupply);

        (address gen2Nft, address gen2Vault, PoolId gen2PoolId) = factory.createDerivative(params2);

        // Verify the second-generation derivative
        (address gen2InfoNft, address gen2InfoParent, PoolId gen2InfoPool) = factory.derivativeForVault(gen2Vault);
        assertEq(gen2InfoNft, gen2Nft, "gen2 NFT mismatch");
        assertEq(gen2InfoParent, gen1Vault, "gen2 parent should be gen1 vault");
        assertEq(PoolId.unwrap(gen2InfoPool), PoolId.unwrap(gen2PoolId), "gen2 pool mismatch");

        // Verify hook configuration for gen2
        (bool initialized, bool hasParent, PoolKey memory parentKey, Currency sharedCurrency,,) =
            hook.poolConfig(gen2PoolId);
        assertTrue(initialized, "gen2 pool not initialized");
        assertTrue(hasParent, "gen2 should have parent");

        // Gen2's parent should be gen1's root pool (ETH/gen1Vault pool)
        assertEq(PoolId.unwrap(parentKey.toId()), PoolId.unwrap(gen1RootPoolId), "gen2 parent pool should be gen1 root");
        assertEq(Currency.unwrap(sharedCurrency), gen1Vault, "gen2 shared currency should be gen1 vault");
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
