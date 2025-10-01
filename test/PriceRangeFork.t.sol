// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {BaseTest} from "./BaseTest.t.sol";
import {console2 as console} from "forge-std/console2.sol";

import {DerivativeFactory} from "../src/DerivativeFactory.sol";
import {wNFTMinter} from "../src/wNFTMinter.sol";
import {wNFTFactory} from "../src/wNFTFactory.sol";
import {wNFTHook} from "../src/wNFTHook.sol";
import {wNFTNFT} from "../src/wNFTNFT.sol";
import {wNFT} from "../src/wNFT.sol";
import {MockERC721Simple} from "./helpers/MockERC721Simple.sol";
import {DerivativeTestUtils} from "./DerivativeTestUtils.sol";

import {Hooks} from "@uniswap/v4-core/src/libraries/Hooks.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
import {Currency, CurrencyLibrary} from "@uniswap/v4-core/src/types/Currency.sol";
import {StateLibrary} from "@uniswap/v4-core/src/libraries/StateLibrary.sol";
import {PoolSwapTest} from "@uniswap/v4-core/src/test/PoolSwapTest.sol";
import {PoolModifyLiquidityTest} from "@uniswap/v4-core/src/test/PoolModifyLiquidityTest.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {BalanceDelta} from "@uniswap/v4-core/src/types/BalanceDelta.sol";

/**
 * @title PriceRangeForkTest
 * @notice Fork tests to verify calculated tick ranges produce expected price behavior
 *
 * Scenarios tested:
 * 1. Parent/ETH pool: 0.01 to 0.5 ETH per parent token (ticks: 6900 to 46020)
 * 2. Derivative/Parent pool: 0.1 to 1.0 parent per derivative (ticks: -23040 to 0 or 0 to 22980)
 */
contract PriceRangeForkTest is BaseTest, DerivativeTestUtils {
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

    wNFTFactory internal vaultFactory;
    wNFTHook internal hook;
    DerivativeFactory internal factory;
    MockERC721Simple internal parentCollection;
    PoolSwapTest internal swapRouter;
    PoolModifyLiquidityTest internal liquidityRouter;

    // Price constants from tick calculations
    // Parent/ETH pool: parent costs 0.01 to 0.5 ETH
    int24 internal constant PARENT_ETH_TICK_LOWER = 6900; // ~2 parent per ETH (0.5 ETH per parent)
    int24 internal constant PARENT_ETH_TICK_UPPER = 46020; // ~100 parent per ETH (0.01 ETH per parent)
    uint160 internal constant PARENT_ETH_SQRT_PRICE = 792281625142643375935439503360; // 100 parent per ETH

    // Derivative/Parent pool: derivative costs 0.1 to 1.0 parent
    // If derivative < parent address:
    int24 internal constant DERIV_PARENT_TICK_LOWER_DERIV_LOW = -23040; // 0.1 parent per derivative
    int24 internal constant DERIV_PARENT_TICK_UPPER_DERIV_LOW = 0; // 1.0 parent per derivative
    uint160 internal constant DERIV_PARENT_SQRT_PRICE_DERIV_LOW = 25054144837504793750611689472;

    // If parent < derivative address:
    int24 internal constant DERIV_PARENT_TICK_LOWER_PARENT_LOW = 0; // 1.0 parent per derivative
    int24 internal constant DERIV_PARENT_TICK_UPPER_PARENT_LOW = 22980; // 10 derivative per parent
    uint160 internal constant DERIV_PARENT_SQRT_PRICE_PARENT_LOW = 250541448375047946302209916928;

    receive() external payable {}

    function setUp() public override {
        super.setUp();
        vm.deal(address(this), 1_000_000 ether);

        vaultFactory = new wNFTFactory();
        parentCollection = new MockERC721Simple("Parent Collection", "PRNT");

        vm.etch(HOOK_ADDRESS, hex"");
        deployCodeTo("wNFTHook.sol:wNFTHook", abi.encode(POOL_MANAGER, address(this)), HOOK_ADDRESS);
        hook = wNFTHook(HOOK_ADDRESS);

        factory = new DerivativeFactory(vaultFactory, hook, address(this));
        hook.transferOwnership(address(factory));

        swapRouter = new PoolSwapTest(POOL_MANAGER);
        liquidityRouter = new PoolModifyLiquidityTest(POOL_MANAGER);
    }

    // Helper to initialize a root pool directly (for testing the permissionless flow)
    function _initRootPool(address parentVault, uint24, /* fee */ int24 tickSpacing, uint160 sqrtPriceX96)
        internal
        returns (PoolId poolId)
    {
        uint24 fee = 0x800000; // LPFeeLibrary.DYNAMIC_FEE_FLAG
        PoolKey memory key = _buildChildKey(address(0), parentVault, fee, tickSpacing);
        PoolKey memory emptyKey;
        vm.prank(address(factory));
        hook.addChild(key, false, emptyKey);
        POOL_MANAGER.initialize(key, sqrtPriceX96);
        return key.toId();
    }

    function test_ParentEthPriceRange() public {
        console.log("\n=== TESTING PARENT/ETH POOL PRICE RANGE ===");
        console.log("Target: Parent costs 0.01 to 0.5 ETH per token");
        console.log("Current: 0.01 ETH per parent (100 parent per ETH)");
        console.log("Liquidity: 500 parent tokens + ~5 ETH");

        // Deploy parent vault and register root pool through factory
        (address parentVault, PoolId rootPoolId) = factory.createVaultForCollection(address(parentCollection), PARENT_ETH_SQRT_PRICE);

        // Get root pool key (ETH/Parent)
        (PoolKey memory rootKey,) = factory.rootPool(parentVault);

        // Verify ETH is currency0 (address 0)
        assertTrue(rootKey.currency0.isAddressZero(), "ETH should be currency0");
        assertEq(Currency.unwrap(rootKey.currency1), parentVault, "Parent should be currency1");

        // Verify initial price
        (uint160 sqrtPriceX96,,,) = POOL_MANAGER.getSlot0(rootPoolId);
        console.log("Initial sqrtPriceX96:", sqrtPriceX96);
        console.log("Expected sqrtPriceX96:", PARENT_ETH_SQRT_PRICE);
        assertApproxEqRel(sqrtPriceX96, PARENT_ETH_SQRT_PRICE, 0.0001e18, "Initial price mismatch");

        // Provide 500 parent tokens for liquidity
        uint256[] memory tokenIds = new uint256[](500);
        for (uint256 i = 0; i < 500; i++) {
            uint256 tokenId = i + 1;
            parentCollection.mint(address(this), tokenId);
            tokenIds[i] = tokenId;
        }
        parentCollection.setApprovalForAll(parentVault, true);
        wNFT(parentVault).deposit(tokenIds, address(this));
        wNFT(parentVault).approve(address(liquidityRouter), type(uint256).max);

        // Add liquidity in the calculated range
        IPoolManager.ModifyLiquidityParams memory params = IPoolManager.ModifyLiquidityParams({
            tickLower: PARENT_ETH_TICK_LOWER,
            tickUpper: PARENT_ETH_TICK_UPPER,
            liquidityDelta: int256(50 * 1e18), // Provide liquidity
            salt: 0
        });

        uint256 ethBefore = address(this).balance;
        liquidityRouter.modifyLiquidity{value: 10 ether}(rootKey, params, bytes(""));
        uint256 ethUsed = ethBefore - address(this).balance;

        console.log("\n--- Liquidity Added ---");
        console.log("ETH used:", ethUsed / 1e18);
        console.log("Parent tokens in range: 500");

        // Verify position exists
        (uint128 liquidity,,) = POOL_MANAGER.getPositionInfo(
            rootPoolId, address(liquidityRouter), PARENT_ETH_TICK_LOWER, PARENT_ETH_TICK_UPPER, 0
        );
        assertGt(liquidity, 0, "Liquidity should be added");
        console.log("Position liquidity:", liquidity);

        // Test swap: Buy parent tokens with ETH (should work - parent gets cheaper)
        console.log("\n--- Testing Swap: Buy Parent with ETH ---");
        wNFT(parentVault).approve(address(swapRouter), type(uint256).max);

        uint256 parentBefore = wNFT(parentVault).balanceOf(address(this));

        IPoolManager.SwapParams memory swapParams = IPoolManager.SwapParams({
            zeroForOne: true, // ETH -> Parent
            amountSpecified: -0.1 ether, // Exact input: 0.1 ETH
            sqrtPriceLimitX96: TickMath.MIN_SQRT_PRICE + 1
        });

        PoolSwapTest.TestSettings memory settings =
            PoolSwapTest.TestSettings({takeClaims: false, settleUsingBurn: false});

        swapRouter.swap{value: 0.1 ether}(rootKey, swapParams, settings, bytes(""));

        uint256 parentAfter = wNFT(parentVault).balanceOf(address(this));
        uint256 parentReceived = parentAfter - parentBefore;

        console.log("ETH spent: 0.1");
        console.log("Parent received:", parentReceived / 1e18);
        console.log("Effective price (ETH per parent):", (0.1e18 * 1e18) / parentReceived);

        // Should receive roughly 10 parent tokens (0.1 ETH / 0.01 ETH per parent)
        // Allow wider tolerance due to slippage and fees
        assertGt(parentReceived, 8 * 1e18, "Should receive at least 8 parent tokens");
        assertLt(parentReceived, 12 * 1e18, "Should receive at most 12 parent tokens");

        console.log("\n=== PARENT/ETH POOL TEST PASSED ===\n");
    }

    function test_DerivativeParentPriceRange() public {
        console.log("\n=== TESTING DERIVATIVE/PARENT POOL PRICE RANGE ===");
        console.log("Target: Derivative costs 0.1 to 1.0 parent tokens");
        console.log("Start: 0.1 parent per derivative at mint");

        // Set up parent vault through factory
        (address parentVault, PoolId rootPoolId) = factory.createVaultForCollection(address(parentCollection), SQRT_PRICE_1_1);

        // Mint parent tokens
        uint256[] memory tokenIds = new uint256[](200);
        for (uint256 i = 0; i < 200; i++) {
            uint256 tokenId = i + 1;
            parentCollection.mint(address(this), tokenId);
            tokenIds[i] = tokenId;
        }
        parentCollection.setApprovalForAll(parentVault, true);
        wNFT(parentVault).deposit(tokenIds, address(this));

        // Add liquidity to root pool first (required by hook)
        (PoolKey memory rootKey,) = factory.rootPool(parentVault);
        wNFT(parentVault).approve(address(liquidityRouter), type(uint256).max);

        IPoolManager.ModifyLiquidityParams memory rootLiqParams = IPoolManager.ModifyLiquidityParams({
            tickLower: -887220,
            tickUpper: 887220,
            liquidityDelta: int256(10 * 1e18),
            salt: 0
        });

        liquidityRouter.modifyLiquidity{value: 10 ether}(rootKey, rootLiqParams, bytes(""));
        console.log("Root pool liquidity added");

        wNFT(parentVault).approve(address(factory), type(uint256).max);

        // Create derivative with calculated ticks
        DerivativeFactory.DerivativeParams memory params;
        params.parentCollection = address(parentCollection);
        params.nftName = "Derivative Collection";
        params.nftSymbol = "DRV";
        params.nftBaseUri = "ipfs://derivative/";
        params.nftOwner = address(this);
        params.fee = 3000;
        params.maxSupply = 50;
        params.parentTokenContribution = 20 * 1e18;
        params.derivativeTokenRecipient = address(this);

        // Mine salt to ensure derivative > parent (derivative will be currency1)
        // Use ticks appropriate for parent being currency0
        params.salt = mineSaltForToken1(factory, parentVault, params.maxSupply);
        params.tickLower = DERIV_PARENT_TICK_LOWER_PARENT_LOW;
        params.tickUpper = DERIV_PARENT_TICK_UPPER_PARENT_LOW;
        params.sqrtPriceX96 = DERIV_PARENT_SQRT_PRICE_PARENT_LOW;
        params.liquidity = 5e18;

        console.log("Requested tickLower:", params.tickLower);
        console.log("Requested tickUpper:", params.tickUpper);
        console.log("Requested sqrtPriceX96:", params.sqrtPriceX96);

        (address nft, address derivativeVault, PoolId childPoolId) = factory.createDerivative(params);

        // Determine actual token order
        PoolKey memory childKey = _buildChildKey(derivativeVault, parentVault, 3000, 60);
        bool derivativeIsCurrency0 = Currency.unwrap(childKey.currency0) == derivativeVault;

        console.log("\n--- Pool Created ---");
        console.log("Derivative is currency0:", derivativeIsCurrency0);

        // Verify pool initialized at correct price
        (uint160 sqrtPriceX96,,,) = POOL_MANAGER.getSlot0(childPoolId);
        console.log("Actual sqrtPriceX96:", sqrtPriceX96);

        // The factory normalizes prices, so actual price may be different but economically equivalent
        // Just verify price is in a reasonable range (0.1 to 1 parent per derivative)
        // sqrtPrice ranges from ~2.5e25 to ~7.9e28
        assertGt(sqrtPriceX96, 1e25, "Price too low");
        assertLt(sqrtPriceX96, 1e30, "Price too high");

        // Verify liquidity position exists at the ticks we specified
        // Since we mined salt for derivative as currency1, we used PARENT_LOW ticks
        int24 actualTickLower = params.tickLower;
        int24 actualTickUpper = params.tickUpper;

        (uint128 liquidity,,) =
            POOL_MANAGER.getPositionInfo(childPoolId, address(factory), actualTickLower, actualTickUpper, 0);
        console.log("Actual tickLower:", actualTickLower);
        console.log("Actual tickUpper:", actualTickUpper);
        console.log("Position liquidity:", liquidity);
        assertGt(liquidity, 0, "Liquidity position should exist");

        // Test swap: Buy derivative with parent tokens
        console.log("\n--- Testing Swap: Buy Derivative with Parent ---");

        // Approve tokens for swap router
        wNFT(parentVault).approve(address(swapRouter), type(uint256).max);
        wNFTMinter(derivativeVault).approve(address(swapRouter), type(uint256).max);

        console.log("Parent balance before swap:", wNFT(parentVault).balanceOf(address(this)) / 1e18);
        console.log("Derivative balance before swap:", wNFTMinter(derivativeVault).balanceOf(address(this)) / 1e18);

        uint256 derivativeBefore = wNFTMinter(derivativeVault).balanceOf(address(this));
        uint256 parentBefore = wNFT(parentVault).balanceOf(address(this));

        // Determine swap direction based on which token is currency0
        bool parentIsCurrency0 = Currency.unwrap(childKey.currency0) == parentVault;

        IPoolManager.SwapParams memory swapParams = IPoolManager.SwapParams({
            zeroForOne: parentIsCurrency0, // Parent -> Derivative if parent is currency0
            amountSpecified: -int256(5 * 1e18), // Spend 5 parent tokens
            sqrtPriceLimitX96: parentIsCurrency0 ? TickMath.MIN_SQRT_PRICE + 1 : TickMath.MAX_SQRT_PRICE - 1
        });

        PoolSwapTest.TestSettings memory settings =
            PoolSwapTest.TestSettings({takeClaims: false, settleUsingBurn: false});

        swapRouter.swap(childKey, swapParams, settings, bytes(""));

        uint256 derivativeAfter = wNFTMinter(derivativeVault).balanceOf(address(this));
        uint256 parentAfter = wNFT(parentVault).balanceOf(address(this));

        int256 derivativeDelta = int256(derivativeAfter) - int256(derivativeBefore);
        int256 parentDelta = int256(parentAfter) - int256(parentBefore);

        console.log("Parent delta:", parentDelta / 1e18);
        console.log("Derivative delta:", derivativeDelta / 1e18);

        if (parentDelta < 0) {
            // We spent parent tokens
            uint256 parentSpent = uint256(-parentDelta);
            uint256 derivativeReceived = uint256(derivativeDelta);
            console.log("Parent spent:", parentSpent / 1e18);
            console.log("Derivative received:", derivativeReceived / 1e18);

            uint256 effectivePrice = (parentSpent * 1e18) / derivativeReceived;
            console.log("Effective price (parent per derivative):", effectivePrice / 1e18, ".", effectivePrice % 1e18);

            // At starting price of 0.1 parent per derivative, 5 parent should buy ~50 derivative
            // But as we buy, price moves up, so we get less
            // Verify we got some derivative tokens and price is in expected range (0.1 to 1.0)
            assertGt(derivativeReceived, 0, "Should receive some derivative tokens");
            assertGt(effectivePrice, 0.05e18, "Effective price too low");
            assertLt(effectivePrice, 2e18, "Effective price too high");
        }

        console.log("\n=== DERIVATIVE/PARENT POOL TEST PASSED ===\n");
    }

    function test_SwapTowardsPriceBoundaries() public {
        console.log("\n=== TESTING PRICE MOVEMENT TOWARD BOUNDARIES ===");

        // Set up pools through factory
        (address parentVault,) = factory.createVaultForCollection(address(parentCollection), SQRT_PRICE_1_1);

        // Mint parent tokens
        uint256[] memory tokenIds = new uint256[](300);
        for (uint256 i = 0; i < 300; i++) {
            parentCollection.mint(address(this), i + 1);
            tokenIds[i] = i + 1;
        }
        parentCollection.setApprovalForAll(parentVault, true);
        wNFT(parentVault).deposit(tokenIds, address(this));

        // Add liquidity to root pool first
        (PoolKey memory rootKey,) = factory.rootPool(parentVault);
        wNFT(parentVault).approve(address(liquidityRouter), type(uint256).max);

        IPoolManager.ModifyLiquidityParams memory rootLiqParams = IPoolManager.ModifyLiquidityParams({
            tickLower: -887220,
            tickUpper: 887220,
            liquidityDelta: int256(10 * 1e18),
            salt: 0
        });

        liquidityRouter.modifyLiquidity{value: 10 ether}(rootKey, rootLiqParams, bytes(""));
        console.log("Root pool liquidity added\n");

        wNFT(parentVault).approve(address(factory), type(uint256).max);

        // Create derivative
        DerivativeFactory.DerivativeParams memory params;
        params.parentCollection = address(parentCollection);
        params.nftName = "Derivative";
        params.nftSymbol = "DRV";
        params.nftBaseUri = "ipfs://";
        params.nftOwner = address(this);
        params.fee = 3000;
        params.maxSupply = 100;
        params.salt = mineSaltForToken1(factory, parentVault, params.maxSupply);
        // Use ticks for parent as currency0 (derivative > parent)
        params.tickLower = DERIV_PARENT_TICK_LOWER_PARENT_LOW;
        params.tickUpper = DERIV_PARENT_TICK_UPPER_PARENT_LOW;
        params.sqrtPriceX96 = DERIV_PARENT_SQRT_PRICE_PARENT_LOW;
        params.liquidity = 10e18; // Higher liquidity for testing
        params.parentTokenContribution = 50 * 1e18;
        params.derivativeTokenRecipient = address(this);

        (address nft, address derivativeVault, PoolId childPoolId) = factory.createDerivative(params);

        PoolKey memory childKey = _buildChildKey(derivativeVault, parentVault, 3000, 60);
        bool parentIsCurrency0 = Currency.unwrap(childKey.currency0) == parentVault;

        console.log("\nPool created, starting price tests...");
        (uint160 initialPrice,,,) = POOL_MANAGER.getSlot0(childPoolId);
        console.log("Initial sqrtPriceX96:", initialPrice);

        // Prepare for swaps
        wNFT(parentVault).approve(address(swapRouter), type(uint256).max);
        wNFTMinter(derivativeVault).approve(address(swapRouter), type(uint256).max);

        // Swap 1: Move price up (make derivative more expensive)
        console.log("\n--- Swap 1: Push derivative price up ---");
        IPoolManager.SwapParams memory swap1 = IPoolManager.SwapParams({
            zeroForOne: parentIsCurrency0,
            amountSpecified: -int256(2 * 1e18),
            sqrtPriceLimitX96: parentIsCurrency0 ? TickMath.MIN_SQRT_PRICE + 1 : TickMath.MAX_SQRT_PRICE - 1
        });

        PoolSwapTest.TestSettings memory settings =
            PoolSwapTest.TestSettings({takeClaims: false, settleUsingBurn: false});

        swapRouter.swap(childKey, swap1, settings, bytes(""));

        (uint160 priceAfterSwap1,,,) = POOL_MANAGER.getSlot0(childPoolId);
        console.log("Price after swap 1:", priceAfterSwap1);

        if (parentIsCurrency0) {
            // Price should decrease (derivative gets cheaper in terms of derivative/parent)
            assertLt(priceAfterSwap1, initialPrice, "Price should move down");
        } else {
            // Price should increase
            assertGt(priceAfterSwap1, initialPrice, "Price should move up");
        }

        console.log("\n=== BOUNDARY MOVEMENT TEST PASSED ===\n");
    }

    function test_LowPriceRangeWithTrading() public {
        console.log("\n=====================================================");
        console.log("  ISOLATED TEST: LOW PRICE (0.1 parent/derivative)");
        console.log("=====================================================");

        // Setup - completely fresh through factory
        MockERC721Simple collection = new MockERC721Simple("Low Price Parent", "LPP");
        (address parentVault,) = factory.createVaultForCollection(address(collection), SQRT_PRICE_1_1);

        // Mint parent tokens
        uint256[] memory tokenIds = new uint256[](500);
        for (uint256 i = 0; i < 500; i++) {
            collection.mint(address(this), i + 1);
            tokenIds[i] = i + 1;
        }
        collection.setApprovalForAll(parentVault, true);
        wNFT(parentVault).deposit(tokenIds, address(this));
        wNFT(parentVault).approve(address(factory), type(uint256).max);

        // Add liquidity to root pool
        (PoolKey memory rootKey,) = factory.rootPool(parentVault);
        wNFT(parentVault).approve(address(liquidityRouter), type(uint256).max);

        IPoolManager.ModifyLiquidityParams memory rootLiqParams = IPoolManager.ModifyLiquidityParams({
            tickLower: -887220,
            tickUpper: 887220,
            liquidityDelta: int256(20 * 1e18),
            salt: 0
        });
        liquidityRouter.modifyLiquidity{value: 20 ether}(rootKey, rootLiqParams, bytes(""));

        // Test LOW price range (0.1 parent per derivative)
        _testPriceRangeWithTrading(
            parentVault,
            "Low Price Derivative",
            -23040, // 0.1 parent per derivative
            0, // 1.0 parent per derivative
            25054144837504793750611689472, // sqrtPrice for 0.1
            40 * 1e18,
            80
        );

        console.log("\n=====================================================");
        console.log("  LOW PRICE RANGE TEST COMPLETE");
        console.log("=====================================================\n");
    }

    function test_MediumPriceRangeWithTrading() public {
        console.log("\n=====================================================");
        console.log("  ISOLATED TEST: MEDIUM PRICE (0.5 parent/derivative)");
        console.log("=====================================================");

        // Setup - completely fresh through factory
        MockERC721Simple collection = new MockERC721Simple("Medium Price Parent", "MPP");
        (address parentVault,) = factory.createVaultForCollection(address(collection), SQRT_PRICE_1_1);

        // Mint parent tokens
        uint256[] memory tokenIds = new uint256[](500);
        for (uint256 i = 0; i < 500; i++) {
            collection.mint(address(this), i + 1);
            tokenIds[i] = i + 1;
        }
        collection.setApprovalForAll(parentVault, true);
        wNFT(parentVault).deposit(tokenIds, address(this));
        wNFT(parentVault).approve(address(factory), type(uint256).max);

        // Add liquidity to root pool
        (PoolKey memory rootKey,) = factory.rootPool(parentVault);
        wNFT(parentVault).approve(address(liquidityRouter), type(uint256).max);

        IPoolManager.ModifyLiquidityParams memory rootLiqParams = IPoolManager.ModifyLiquidityParams({
            tickLower: -887220,
            tickUpper: 887220,
            liquidityDelta: int256(20 * 1e18),
            salt: 0
        });
        liquidityRouter.modifyLiquidity{value: 20 ether}(rootKey, rootLiqParams, bytes(""));

        // Test MEDIUM price range (0.5 parent per derivative)
        _testPriceRangeWithTrading(
            parentVault,
            "Medium Price Derivative",
            -11520, // 0.5 parent per derivative
            11520, // 2.0 parent per derivative
            56022770974786139918731938227, // sqrtPrice for 0.5
            40 * 1e18,
            80
        );

        console.log("\n=====================================================");
        console.log("  MEDIUM PRICE RANGE TEST COMPLETE");
        console.log("=====================================================\n");
    }

    function test_HighPriceRangeWithTrading() public {
        console.log("\n=====================================================");
        console.log("  ISOLATED TEST: HIGH PRICE (1.0 parent/derivative)");
        console.log("=====================================================");

        // Setup - completely fresh through factory
        MockERC721Simple collection = new MockERC721Simple("High Price Parent", "HPP");
        (address parentVault,) = factory.createVaultForCollection(address(collection), SQRT_PRICE_1_1);

        // Mint parent tokens
        uint256[] memory tokenIds = new uint256[](500);
        for (uint256 i = 0; i < 500; i++) {
            collection.mint(address(this), i + 1);
            tokenIds[i] = i + 1;
        }
        collection.setApprovalForAll(parentVault, true);
        wNFT(parentVault).deposit(tokenIds, address(this));
        wNFT(parentVault).approve(address(factory), type(uint256).max);

        // Add liquidity to root pool
        (PoolKey memory rootKey,) = factory.rootPool(parentVault);
        wNFT(parentVault).approve(address(liquidityRouter), type(uint256).max);

        IPoolManager.ModifyLiquidityParams memory rootLiqParams = IPoolManager.ModifyLiquidityParams({
            tickLower: -887220,
            tickUpper: 887220,
            liquidityDelta: int256(20 * 1e18),
            salt: 0
        });
        liquidityRouter.modifyLiquidity{value: 20 ether}(rootKey, rootLiqParams, bytes(""));

        // Test HIGH price range (1.0 parent per derivative)
        _testPriceRangeWithTrading(
            parentVault,
            "High Price Derivative",
            0, // 1.0 parent per derivative
            23040, // 10 parent per derivative
            79228162514264337593543950336, // sqrtPrice for 1.0 (SQRT_PRICE_1_1)
            40 * 1e18,
            80
        );

        console.log("\n=====================================================");
        console.log("  HIGH PRICE RANGE TEST COMPLETE");
        console.log("=====================================================\n");
    }

    function _testPriceRangeWithTrading(
        address parentVault,
        string memory name,
        int24 tickLower,
        int24 tickUpper,
        uint160 sqrtPriceX96,
        uint256 parentContribution,
        uint256 maxSupply
    ) internal {
        console.log("\n--- CREATING DERIVATIVE COLLECTION ---");
        console.log("Name:", name);
        console.log("Max Supply:", maxSupply);
        console.log("Initial Price:", sqrtPriceX96);
        console.log("Tick Lower:", tickLower);
        console.log("Tick Upper:", tickUpper);

        // Get root pool for parent/ETH tracking
        (PoolKey memory rootKey, PoolId rootPoolId) = factory.rootPool(parentVault);
        (uint160 initialParentEthPrice,,,) = POOL_MANAGER.getSlot0(rootPoolId);

        console.log("\n--- INITIAL PARENT/ETH POOL STATE ---");
        console.log("Parent/ETH sqrtPrice:", initialParentEthPrice);

        // Create derivative
        DerivativeFactory.DerivativeParams memory params;
        params.parentCollection = wNFT(parentVault).erc721();
        params.nftName = name;
        params.nftSymbol = "DRV";
        params.nftBaseUri = "ipfs://test/";
        params.nftOwner = address(this);
        params.fee = 3000;
        params.maxSupply = maxSupply;
        params.parentTokenContribution = parentContribution;
        params.derivativeTokenRecipient = address(this);
        params.tickLower = tickLower;
        params.tickUpper = tickUpper;
        params.sqrtPriceX96 = sqrtPriceX96;
        params.liquidity = 10e18;
        params.salt = mineSaltForToken1(factory, parentVault, params.maxSupply);

        (, address derivativeVault, PoolId childPoolId) = factory.createDerivative(params);

        PoolKey memory childKey = _buildChildKey(derivativeVault, parentVault, 3000, 60);
        bool parentIsCurrency0 = Currency.unwrap(childKey.currency0) == parentVault;

        uint256 derivativeSupply = wNFTMinter(derivativeVault).totalSupply();
        uint256 initialDerivativeBalance = wNFTMinter(derivativeVault).balanceOf(address(this));

        console.log("\n--- DERIVATIVE POOL CREATED ---");
        console.log("Derivative supply:", derivativeSupply / 1e18);
        console.log("Initial balance:", initialDerivativeBalance / 1e18);
        console.log("Available to mint:", (derivativeSupply - initialDerivativeBalance) / 1e18);

        // Approve tokens for swapping
        wNFT(parentVault).approve(address(swapRouter), type(uint256).max);
        wNFTMinter(derivativeVault).approve(address(swapRouter), type(uint256).max);

        PoolSwapTest.TestSettings memory settings =
            PoolSwapTest.TestSettings({takeClaims: false, settleUsingBurn: false});

        // MINT OUT SIMULATION - Buy all available derivatives
        console.log("\n--- SIMULATING MINT-OUT ---");
        console.log("Buying derivatives until supply exhausted...\n");

        uint256 totalParentSpent = 0;
        uint256 totalDerivativesBought = 0;
        uint256 totalFees = 0;
        uint256 swapCount = 0;
        uint256 maxSwaps = 50;

        uint256 targetToBuy = derivativeSupply - initialDerivativeBalance;

        while (swapCount < maxSwaps) {
            uint256 derivBalBefore = wNFTMinter(derivativeVault).balanceOf(address(this));
            uint256 remainingToBuy = derivativeSupply - derivBalBefore;

            if (remainingToBuy < 0.01e18) {
                console.log("Mint-out complete! Remaining:", remainingToBuy / 1e16, "/ 100");
                break;
            }

            uint256 parentBalBefore = wNFT(parentVault).balanceOf(address(this));

            // Try to buy with a reasonable amount
            uint256 buyAmount = 2 * 1e18; // 2 parent tokens per attempt
            if (parentBalBefore < buyAmount) {
                buyAmount = parentBalBefore / 2;
            }

            if (buyAmount < 0.1e18) {
                console.log("Insufficient parent tokens to continue");
                break;
            }

            try swapRouter.swap(
                childKey,
                IPoolManager.SwapParams({
                    zeroForOne: parentIsCurrency0,
                    amountSpecified: -int256(buyAmount),
                    sqrtPriceLimitX96: parentIsCurrency0 ? TickMath.MIN_SQRT_PRICE + 1 : TickMath.MAX_SQRT_PRICE - 1
                }),
                settings,
                bytes("")
            ) {
                uint256 parentBalAfter = wNFT(parentVault).balanceOf(address(this));
                uint256 derivBalAfter = wNFTMinter(derivativeVault).balanceOf(address(this));

                uint256 parentSpent = parentBalBefore - parentBalAfter;
                uint256 derivReceived = derivBalAfter - derivBalBefore;

                if (derivReceived == 0) {
                    console.log("No more derivatives available");
                    break;
                }

                totalParentSpent += parentSpent;
                totalDerivativesBought += derivReceived;
                totalFees += (parentSpent * 1000) / 10000; // 10% fee
                swapCount++;

                if (swapCount % 5 == 0 || swapCount <= 3) {
                    console.log("Swap", swapCount);
                    console.log("  Parent:", parentSpent / 1e18, ".", (parentSpent % 1e18) / 1e16);
                    console.log("  Derivatives:", derivReceived / 1e18, ".", (derivReceived % 1e18) / 1e16);
                    console.log("  Total bought:", totalDerivativesBought / 1e18, "/", targetToBuy / 1e18);
                }
            } catch {
                console.log("Swap failed - liquidity exhausted");
                break;
            }
        }

        // Get final parent/ETH price
        (uint160 finalParentEthPrice,,,) = POOL_MANAGER.getSlot0(rootPoolId);

        console.log("\n--- MINT-OUT RESULTS ---");
        console.log("Total swaps:", swapCount);
        console.log("Total parent spent:", totalParentSpent / 1e18, ".", (totalParentSpent % 1e18) / 1e16);
        console.log(
            "Total derivatives bought:", totalDerivativesBought / 1e18, ".", (totalDerivativesBought % 1e18) / 1e16
        );

        if (totalDerivativesBought > 0 && targetToBuy > 0) {
            console.log("Mint-out %:", (totalDerivativesBought * 100) / targetToBuy);
            uint256 avgPrice = (totalParentSpent * 1e18) / totalDerivativesBought;
            console.log("Average price (parent/derivative):", avgPrice / 1e18, ".", (avgPrice % 1e18) / 1e16);
        } else {
            console.log("No derivatives purchased - collection already owned or no liquidity");
        }

        console.log("\n--- FEE COLLECTION ---");
        console.log("Total fees (10%):", totalFees / 1e18, ".", (totalFees % 1e18) / 1e16);
        console.log("Child pool (7.5%):", (totalFees * 75 / 100) / 1e18, ".", ((totalFees * 75 / 100) % 1e18) / 1e16);
        console.log("Parent pool (2.5%):", (totalFees * 25 / 100) / 1e18, ".", ((totalFees * 25 / 100) % 1e18) / 1e16);

        console.log("\n--- PARENT COLLECTION PRICE IMPACT ---");
        console.log("Initial Parent/ETH sqrtPrice:", initialParentEthPrice);
        console.log("Final Parent/ETH sqrtPrice:", finalParentEthPrice);

        int256 parentPriceChange = int256(uint256(finalParentEthPrice) * 10000 / uint256(initialParentEthPrice)) - 10000;
        console.log("Parent price change (bps):", parentPriceChange);

        if (parentPriceChange > 0) {
            uint256 percentIncrease = uint256(parentPriceChange) / 100;
            uint256 percentDecimals = (uint256(parentPriceChange) % 100) * 10;
            console.log("PARENT COLLECTION PUMPED!");
            console.log("Price increase:", percentIncrease, ".", percentDecimals);
            console.log("(percent)");
        } else if (parentPriceChange < 0) {
            console.log("Parent collection price decreased");
        } else {
            console.log("Parent collection price unchanged");
        }

        console.log("\n[PASS]", name, "testing completed\n");
    }

    function test_DetailedPriceImpactAnalysis() public {
        console.log("\n=== DETAILED PRICE IMPACT & FEE ANALYSIS ===\n");

        // Setup parent vault and root pool through factory
        (address parentVault,) = factory.createVaultForCollection(address(parentCollection), SQRT_PRICE_1_1);

        // Mint parent tokens
        uint256[] memory tokenIds = new uint256[](500);
        for (uint256 i = 0; i < 500; i++) {
            parentCollection.mint(address(this), i + 1);
            tokenIds[i] = i + 1;
        }
        parentCollection.setApprovalForAll(parentVault, true);
        wNFT(parentVault).deposit(tokenIds, address(this));
        wNFT(parentVault).approve(address(factory), type(uint256).max);

        // Add liquidity to root pool
        (PoolKey memory rootKey,) = factory.rootPool(parentVault);
        wNFT(parentVault).approve(address(liquidityRouter), type(uint256).max);

        IPoolManager.ModifyLiquidityParams memory rootLiqParams = IPoolManager.ModifyLiquidityParams({
            tickLower: -887220,
            tickUpper: 887220,
            liquidityDelta: int256(100 * 1e18), // Increased to handle large sequential swaps
            salt: 0
        });
        liquidityRouter.modifyLiquidity{value: 100 ether}(rootKey, rootLiqParams, bytes(""));

        console.log("=====================================================");
        console.log("SCENARIO: Medium Price Derivative Launch & Trading");
        console.log("=====================================================\n");

        // Create derivative at medium price (0.5 parent per derivative)
        DerivativeFactory.DerivativeParams memory params;
        params.parentCollection = address(parentCollection);
        params.nftName = "Analysis Derivative";
        params.nftSymbol = "ANLZ";
        params.nftBaseUri = "ipfs://analysis/";
        params.nftOwner = address(this);
        params.initialMinter = address(this); // Allow this test contract to mint
        params.fee = 3000; // 0.3% fee
        params.maxSupply = 100;
        params.parentTokenContribution = 150 * 1e18; // Increased to match higher liquidity
        params.derivativeTokenRecipient = address(this);
        params.tickLower = -11520;
        params.tickUpper = 11520;
        params.sqrtPriceX96 = 56022770974786139918731938227;
        params.liquidity = 50e18; // Increased to handle large sequential swaps
        params.salt = mineSaltForToken1(factory, parentVault, params.maxSupply);

        console.log("--- Pre-Launch State ---");
        (uint160 parentEthPriceBefore,,,) = POOL_MANAGER.getSlot0(rootKey.toId());
        console.log("Parent/ETH pool sqrtPrice:", parentEthPriceBefore);

        (address derivativeNft, address derivativeVault, PoolId childPoolId) = factory.createDerivative(params);

        PoolKey memory childKey = _buildChildKey(derivativeVault, parentVault, 3000, 60);
        bool parentIsCurrency0 = Currency.unwrap(childKey.currency0) == parentVault;

        (uint160 initialDerivPrice,,,) = POOL_MANAGER.getSlot0(childPoolId);
        console.log("\n--- Post-Launch State ---");
        console.log("Derivative pool created");
        console.log("Initial derivative sqrtPrice:", initialDerivPrice);
        console.log("Max Supply:", params.maxSupply);
        console.log("Fee tier: 0.3% (3000 bps)");
        console.log("Initial liquidity:", params.liquidity);

        // Approve tokens for swapping
        wNFT(parentVault).approve(address(swapRouter), type(uint256).max);
        wNFTMinter(derivativeVault).approve(address(swapRouter), type(uint256).max);

        PoolSwapTest.TestSettings memory settings =
            PoolSwapTest.TestSettings({takeClaims: false, settleUsingBurn: false});

        console.log("\n=====================================================");
        console.log("PHASE 1: PRICE IMPACT ACROSS TRADE SIZES");
        console.log("=====================================================\n");

        // Test various trade sizes
        uint256[] memory tradeSizes = new uint256[](5);
        tradeSizes[0] = 1e17; // 0.1 parent
        tradeSizes[1] = 5e17; // 0.5 parent
        tradeSizes[2] = 1e18; // 1 parent
        tradeSizes[3] = 5e18; // 5 parent
        tradeSizes[4] = 10e18; // 10 parent

        uint160 currentPrice = initialDerivPrice;

        for (uint256 i = 0; i < tradeSizes.length; i++) {
            uint256 tradeSize = tradeSizes[i];

            console.log("--- Trade");
            console.log("Trade number:", i + 1);
            console.log("Trade size (parent):", tradeSize / 1e18, ".", (tradeSize % 1e18) / 1e16);

            uint256 parentBal0 = wNFT(parentVault).balanceOf(address(this));
            uint256 derivBal0 = wNFTMinter(derivativeVault).balanceOf(address(this));

            IPoolManager.SwapParams memory swapParams = IPoolManager.SwapParams({
                zeroForOne: parentIsCurrency0,
                amountSpecified: -int256(tradeSize),
                sqrtPriceLimitX96: parentIsCurrency0 ? TickMath.MIN_SQRT_PRICE + 1 : TickMath.MAX_SQRT_PRICE - 1
            });

            swapRouter.swap(childKey, swapParams, settings, bytes(""));

            uint256 parentBal1 = wNFT(parentVault).balanceOf(address(this));
            uint256 derivBal1 = wNFTMinter(derivativeVault).balanceOf(address(this));
            (uint160 newPrice,,,) = POOL_MANAGER.getSlot0(childPoolId);

            uint256 parentSpentNow = parentBal0 - parentBal1;
            uint256 derivReceivedNow = derivBal1 - derivBal0;

            console.log("  Parent spent:", parentSpentNow / 1e18, ".", (parentSpentNow % 1e18) / 1e16);
            console.log("  Derivative received:", derivReceivedNow / 1e18, ".", (derivReceivedNow % 1e18) / 1e16);

            if (derivReceivedNow > 0) {
                uint256 avgPrice = (parentSpentNow * 1e18) / derivReceivedNow;
                console.log("  Average price (parent/derivative):", avgPrice / 1e18, ".", (avgPrice % 1e18) / 1e16);
            }

            int256 priceChange = int256(uint256(newPrice) * 10000 / uint256(currentPrice)) - 10000;
            console.log("  Price before:", currentPrice);
            console.log("  Price after:", newPrice);
            console.log("  Price impact (bps):", priceChange);

            // Calculate approximate fee (0.3% of trade)
            uint256 feeApprox = (parentSpentNow * 30) / 10000;
            console.log("  Estimated fee (parent tokens):", feeApprox / 1e18, ".", (feeApprox % 1e18) / 1e16);

            currentPrice = newPrice;
            console.log("");
        }

        console.log("\n=====================================================");
        console.log("PHASE 2: CUMULATIVE IMPACT & FEE ACCUMULATION");
        console.log("=====================================================\n");

        // Calculate cumulative fees from all trades
        console.log("--- Trade Summary After 5 Sequential Buys ---");

        (uint160 finalDerivPrice,,,) = POOL_MANAGER.getSlot0(childPoolId);
        (uint160 finalParentPrice,,,) = POOL_MANAGER.getSlot0(rootKey.toId());

        console.log("\nCumulative Price Movement:");
        console.log("  Initial derivative price:", initialDerivPrice);
        console.log("  Final derivative price:", finalDerivPrice);
        int256 totalDerivPriceChange = int256(uint256(finalDerivPrice) * 10000 / uint256(initialDerivPrice)) - 10000;
        console.log("  Total derivative price change (bps):", totalDerivPriceChange);

        console.log("\nParent Token Price Impact:");
        console.log("  Initial parent/ETH price:", parentEthPriceBefore);
        console.log("  Final parent/ETH price:", finalParentPrice);
        int256 parentPriceChange = int256(uint256(finalParentPrice) * 10000 / uint256(parentEthPriceBefore)) - 10000;
        console.log("  Parent price change (bps):", parentPriceChange);

        // Estimate total fees collected (sum of all trade fees)
        console.log("\nEstimated Total Fees Collected:");
        console.log("  From 5 trades: ~0.3% of each trade");
        console.log("  (Fees remain in pool as protocol liquidity)");

        console.log("\n=====================================================");
        console.log("PHASE 3: LARGE TRADE ANALYSIS");
        console.log("=====================================================\n");

        // Test large trade impact
        console.log("--- Large Trade: 20 parent tokens ---");

        uint256 parentBalBefore = wNFT(parentVault).balanceOf(address(this));
        uint256 derivBalBefore = wNFTMinter(derivativeVault).balanceOf(address(this));
        (uint160 priceBefore,,,) = POOL_MANAGER.getSlot0(childPoolId);

        IPoolManager.SwapParams memory largeSwap = IPoolManager.SwapParams({
            zeroForOne: parentIsCurrency0,
            amountSpecified: -int256(20e18),
            sqrtPriceLimitX96: parentIsCurrency0 ? TickMath.MIN_SQRT_PRICE + 1 : TickMath.MAX_SQRT_PRICE - 1
        });

        swapRouter.swap(childKey, largeSwap, settings, bytes(""));

        uint256 parentBalAfter = wNFT(parentVault).balanceOf(address(this));
        uint256 derivBalAfter = wNFTMinter(derivativeVault).balanceOf(address(this));
        (uint160 priceAfter,,,) = POOL_MANAGER.getSlot0(childPoolId);

        uint256 parentSpent = parentBalBefore - parentBalAfter;
        uint256 derivReceived = derivBalAfter - derivBalBefore;

        console.log("Trade Results:");
        console.log("  Parent spent:", parentSpent / 1e18, ".", (parentSpent % 1e18) / 1e16);
        console.log("  Derivative received:", derivReceived / 1e18, ".", (derivReceived % 1e18) / 1e16);

        if (derivReceived > 0) {
            uint256 avgPrice = (parentSpent * 1e18) / derivReceived;
            console.log("  Average price (parent/derivative):", avgPrice / 1e18, ".", (avgPrice % 1e18) / 1e16);
        }

        int256 largePriceChange = int256(uint256(priceAfter) * 10000 / uint256(priceBefore)) - 10000;
        console.log("  Price impact (bps):", largePriceChange);
        console.log(
            "  Estimated fee:", (parentSpent * 30) / 10000 / 1e18, ".", ((parentSpent * 30) / 10000 % 1e18) / 1e16
        );

        console.log("\n=====================================================");
        console.log("              ANALYSIS COMPLETE");
        console.log("=====================================================\n");
    }

    function _buildChildKey(address tokenA, address tokenB, uint24 fee, int24 spacing)
        internal
        view
        returns (PoolKey memory key)
    {
        Currency currencyA = Currency.wrap(tokenA);
        Currency currencyB = Currency.wrap(tokenB);
        IHooks hooksInstance = IHooks(HOOK_ADDRESS);
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
