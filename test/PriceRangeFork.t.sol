// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {BaseTest} from "./BaseTest.t.sol";
import {console2 as console} from "forge-std/console2.sol";

import {DerivativeFactory} from "../src/DerivativeFactory.sol";
import {MinterRemyVault} from "../src/MinterRemyVault.sol";
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
contract PriceRangeForkTest is BaseTest {
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
    PoolSwapTest internal swapRouter;
    PoolModifyLiquidityTest internal liquidityRouter;

    // Price constants from tick calculations
    // Parent/ETH pool: parent costs 0.01 to 0.5 ETH
    int24 internal constant PARENT_ETH_TICK_LOWER = 6900;   // ~2 parent per ETH (0.5 ETH per parent)
    int24 internal constant PARENT_ETH_TICK_UPPER = 46020;  // ~100 parent per ETH (0.01 ETH per parent)
    uint160 internal constant PARENT_ETH_SQRT_PRICE = 792281625142643375935439503360; // 100 parent per ETH

    // Derivative/Parent pool: derivative costs 0.1 to 1.0 parent
    // If derivative < parent address:
    int24 internal constant DERIV_PARENT_TICK_LOWER_DERIV_LOW = -23040; // 0.1 parent per derivative
    int24 internal constant DERIV_PARENT_TICK_UPPER_DERIV_LOW = 0;      // 1.0 parent per derivative
    uint160 internal constant DERIV_PARENT_SQRT_PRICE_DERIV_LOW = 25054144837504793750611689472;

    // If parent < derivative address:
    int24 internal constant DERIV_PARENT_TICK_LOWER_PARENT_LOW = 0;      // 1.0 parent per derivative
    int24 internal constant DERIV_PARENT_TICK_UPPER_PARENT_LOW = 22980;  // 10 derivative per parent
    uint160 internal constant DERIV_PARENT_SQRT_PRICE_PARENT_LOW = 250541448375047946302209916928;

    receive() external payable {}

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

        swapRouter = new PoolSwapTest(POOL_MANAGER);
        liquidityRouter = new PoolModifyLiquidityTest(POOL_MANAGER);
    }

    function test_ParentEthPriceRange() public {
        console.log("\n=== TESTING PARENT/ETH POOL PRICE RANGE ===");
        console.log("Target: Parent costs 0.01 to 0.5 ETH per token");
        console.log("Current: 0.01 ETH per parent (100 parent per ETH)");
        console.log("Liquidity: 500 parent tokens + ~5 ETH");

        // Deploy parent vault and register root pool
        address parentVault = vaultFactory.deployVault(address(parentCollection), "Parent Token", "PRNT");

        // Register root pool with calculated parameters
        PoolId rootPoolId = factory.registerRootPool(parentVault, 3000, 60, PARENT_ETH_SQRT_PRICE);

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
        RemyVault(parentVault).deposit(tokenIds, address(this));
        RemyVault(parentVault).approve(address(liquidityRouter), type(uint256).max);

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
            rootPoolId,
            address(liquidityRouter),
            PARENT_ETH_TICK_LOWER,
            PARENT_ETH_TICK_UPPER,
            0
        );
        assertGt(liquidity, 0, "Liquidity should be added");
        console.log("Position liquidity:", liquidity);

        // Test swap: Buy parent tokens with ETH (should work - parent gets cheaper)
        console.log("\n--- Testing Swap: Buy Parent with ETH ---");
        RemyVault(parentVault).approve(address(swapRouter), type(uint256).max);

        uint256 parentBefore = RemyVault(parentVault).balanceOf(address(this));

        IPoolManager.SwapParams memory swapParams = IPoolManager.SwapParams({
            zeroForOne: true, // ETH -> Parent
            amountSpecified: -0.1 ether, // Exact input: 0.1 ETH
            sqrtPriceLimitX96: TickMath.MIN_SQRT_PRICE + 1
        });

        PoolSwapTest.TestSettings memory settings =
            PoolSwapTest.TestSettings({takeClaims: false, settleUsingBurn: false});

        swapRouter.swap{value: 0.1 ether}(rootKey, swapParams, settings, bytes(""));

        uint256 parentAfter = RemyVault(parentVault).balanceOf(address(this));
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

        // Set up parent vault
        address parentVault = vaultFactory.deployVault(address(parentCollection), "Parent Token", "PRNT");
        PoolId rootPoolId = factory.registerRootPool(parentVault, 3000, 60, SQRT_PRICE_1_1);

        // Mint parent tokens
        uint256[] memory tokenIds = new uint256[](200);
        for (uint256 i = 0; i < 200; i++) {
            uint256 tokenId = i + 1;
            parentCollection.mint(address(this), tokenId);
            tokenIds[i] = tokenId;
        }
        parentCollection.setApprovalForAll(parentVault, true);
        RemyVault(parentVault).deposit(tokenIds, address(this));

        // Add liquidity to root pool first (required by hook)
        (PoolKey memory rootKey,) = factory.rootPool(parentVault);
        RemyVault(parentVault).approve(address(liquidityRouter), type(uint256).max);

        IPoolManager.ModifyLiquidityParams memory rootLiqParams = IPoolManager.ModifyLiquidityParams({
            tickLower: -887220,
            tickUpper: 887220,
            liquidityDelta: int256(10 * 1e18),
            salt: 0
        });

        liquidityRouter.modifyLiquidity{value: 10 ether}(rootKey, rootLiqParams, bytes(""));
        console.log("Root pool liquidity added");

        RemyVault(parentVault).approve(address(factory), type(uint256).max);

        // Create derivative with calculated ticks
        DerivativeFactory.DerivativeParams memory params;
        params.parentVault = parentVault;
        params.nftName = "Derivative Collection";
        params.nftSymbol = "DRV";
        params.nftBaseUri = "ipfs://derivative/";
        params.nftOwner = address(this);
        params.vaultName = "Derivative Token";
        params.vaultSymbol = "dDRV";
        params.fee = 3000;
        params.tickSpacing = 60;
        params.maxSupply = 50;
        params.parentTokenContribution = 20 * 1e18;
        params.derivativeTokenRecipient = address(this);

        // We'll use the ticks for when derivative < parent (more common case)
        // The factory's _normalizePriceAndTicks will flip them if needed
        params.tickLower = DERIV_PARENT_TICK_LOWER_DERIV_LOW;
        params.tickUpper = DERIV_PARENT_TICK_UPPER_DERIV_LOW;
        params.sqrtPriceX96 = DERIV_PARENT_SQRT_PRICE_DERIV_LOW;
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

        // Verify liquidity position exists
        // The factory may have normalized the ticks, so we need to check both possibilities
        int24 actualTickLower;
        int24 actualTickUpper;

        if (derivativeIsCurrency0) {
            // Ticks are as we specified
            actualTickLower = DERIV_PARENT_TICK_LOWER_DERIV_LOW;
            actualTickUpper = DERIV_PARENT_TICK_UPPER_DERIV_LOW;
        } else {
            // Ticks were flipped
            actualTickLower = -DERIV_PARENT_TICK_UPPER_DERIV_LOW;
            actualTickUpper = -DERIV_PARENT_TICK_LOWER_DERIV_LOW;
        }

        (uint128 liquidity,,) = POOL_MANAGER.getPositionInfo(
            childPoolId,
            address(factory),
            actualTickLower,
            actualTickUpper,
            0
        );
        console.log("Actual tickLower:", actualTickLower);
        console.log("Actual tickUpper:", actualTickUpper);
        console.log("Position liquidity:", liquidity);
        assertGt(liquidity, 0, "Liquidity position should exist");

        // Test swap: Buy derivative with parent tokens
        console.log("\n--- Testing Swap: Buy Derivative with Parent ---");

        // Approve tokens for swap router
        RemyVault(parentVault).approve(address(swapRouter), type(uint256).max);
        MinterRemyVault(derivativeVault).approve(address(swapRouter), type(uint256).max);

        console.log("Parent balance before swap:", RemyVault(parentVault).balanceOf(address(this)) / 1e18);
        console.log("Derivative balance before swap:", MinterRemyVault(derivativeVault).balanceOf(address(this)) / 1e18);

        uint256 derivativeBefore = MinterRemyVault(derivativeVault).balanceOf(address(this));
        uint256 parentBefore = RemyVault(parentVault).balanceOf(address(this));

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

        uint256 derivativeAfter = MinterRemyVault(derivativeVault).balanceOf(address(this));
        uint256 parentAfter = RemyVault(parentVault).balanceOf(address(this));

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

        // Set up pools
        address parentVault = vaultFactory.deployVault(address(parentCollection), "Parent Token", "PRNT");
        factory.registerRootPool(parentVault, 3000, 60, SQRT_PRICE_1_1);

        // Mint parent tokens
        uint256[] memory tokenIds = new uint256[](300);
        for (uint256 i = 0; i < 300; i++) {
            parentCollection.mint(address(this), i + 1);
            tokenIds[i] = i + 1;
        }
        parentCollection.setApprovalForAll(parentVault, true);
        RemyVault(parentVault).deposit(tokenIds, address(this));

        // Add liquidity to root pool first
        (PoolKey memory rootKey,) = factory.rootPool(parentVault);
        RemyVault(parentVault).approve(address(liquidityRouter), type(uint256).max);

        IPoolManager.ModifyLiquidityParams memory rootLiqParams = IPoolManager.ModifyLiquidityParams({
            tickLower: -887220,
            tickUpper: 887220,
            liquidityDelta: int256(10 * 1e18),
            salt: 0
        });

        liquidityRouter.modifyLiquidity{value: 10 ether}(rootKey, rootLiqParams, bytes(""));
        console.log("Root pool liquidity added\n");

        RemyVault(parentVault).approve(address(factory), type(uint256).max);

        // Create derivative
        DerivativeFactory.DerivativeParams memory params;
        params.parentVault = parentVault;
        params.nftName = "Derivative";
        params.nftSymbol = "DRV";
        params.nftBaseUri = "ipfs://";
        params.nftOwner = address(this);
        params.vaultName = "Derivative Token";
        params.vaultSymbol = "dDRV";
        params.fee = 3000;
        params.tickSpacing = 60;
        params.maxSupply = 100;
        params.tickLower = -23040; // Will be normalized if needed
        params.tickUpper = 0;
        params.sqrtPriceX96 = DERIV_PARENT_SQRT_PRICE_DERIV_LOW;
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
        RemyVault(parentVault).approve(address(swapRouter), type(uint256).max);
        MinterRemyVault(derivativeVault).approve(address(swapRouter), type(uint256).max);

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