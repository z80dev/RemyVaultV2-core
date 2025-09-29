// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {BaseTest} from "./BaseTest.t.sol";
import {console2 as console} from "forge-std/console2.sol";

import {DerivativeFactory} from "../src/DerivativeFactory.sol";
import {MinterRemyVault} from "../src/MinterRemyVault.sol";
import {RemyVaultFactory} from "../src/RemyVaultFactory.sol";
import {RemyVaultHook} from "../src/RemyVaultHook.sol";
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
 * @title DerivativePriceRangesTest
 * @notice Tests for different price ranges in derivative token launches
 *
 * Price Ranges:
 * - LOW: 0.1 to 1 parent token per derivative
 * - MEDIUM: 0.5 to 5 parent tokens per derivative
 * - HIGH: 1 to 10 parent tokens per derivative
 */
contract DerivativePriceRangesTest is BaseTest {
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

    // LOW PRICE RANGE: 0.1 to 1 parent per derivative
    // Tick for 0.1 parent per derivative = ln(0.1) / ln(1.0001) * 1 = -23027
    // Tick for 1 parent per derivative = ln(1) / ln(1.0001) * 1 = 0
    int24 internal constant LOW_TICK_LOWER = -23040;  // ~0.1 parent per derivative (rounded to tick spacing)
    int24 internal constant LOW_TICK_UPPER = 0;       // 1.0 parent per derivative
    // sqrt(0.1) * 2^96 = ~25054144837504793118
    uint160 internal constant LOW_SQRT_PRICE = 25054144837504793118; // sqrt(0.1) * 2^96

    // MEDIUM PRICE RANGE: 0.5 to 5 parent per derivative
    // Tick for 0.5 parent per derivative = ln(0.5) / ln(1.0001) * 1 = -6931
    // Tick for 5 parent per derivative = ln(5) / ln(1.0001) * 1 = 16095
    int24 internal constant MED_TICK_LOWER = -6960;   // ~0.5 parent per derivative (rounded to tick spacing)
    int24 internal constant MED_TICK_UPPER = 16080;   // ~5 parent per derivative (rounded to tick spacing)
    // sqrt(0.5) * 2^96 = ~56022770974786139918
    uint160 internal constant MED_SQRT_PRICE = 56022770974786139918; // sqrt(0.5) * 2^96

    // HIGH PRICE RANGE: 1 to 10 parent per derivative
    // Tick for 1 parent per derivative = ln(1) / ln(1.0001) * 1 = 0
    // Tick for 10 parent per derivative = ln(10) / ln(1.0001) * 1 = 23026
    int24 internal constant HIGH_TICK_LOWER = 0;      // 1.0 parent per derivative
    int24 internal constant HIGH_TICK_UPPER = 23040;  // ~10 parent per derivative (rounded to tick spacing)
    // sqrt(1) * 2^96 = 79228162514264337593543950336
    uint160 internal constant HIGH_SQRT_PRICE = 79228162514264337593543950336; // sqrt(1) * 2^96

    RemyVaultFactory internal vaultFactory;
    RemyVaultHook internal hook;
    DerivativeFactory internal factory;
    MockERC721Simple internal parentCollection;
    PoolSwapTest internal swapRouter;
    PoolModifyLiquidityTest internal liquidityRouter;

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

    function test_LowPriceRange() public {
        console.log("\n=== TESTING LOW PRICE RANGE (0.1 to 1 parent per derivative) ===");

        (address parentVault, address derivativeVault, PoolId childPoolId) = _setupDerivative(
            "Low Price Derivative",
            "LOW",
            LOW_TICK_LOWER,
            LOW_TICK_UPPER,
            LOW_SQRT_PRICE,
            10e18, // liquidity
            20e18  // parent contribution
        );

        _testPriceRange(
            parentVault,
            derivativeVault,
            childPoolId,
            0.1e18,  // expected min price
            1e18,    // expected max price
            "LOW"
        );
    }

    function test_MediumPriceRange() public {
        console.log("\n=== TESTING MEDIUM PRICE RANGE (0.5 to 5 parent per derivative) ===");

        (address parentVault, address derivativeVault, PoolId childPoolId) = _setupDerivative(
            "Medium Price Derivative",
            "MED",
            MED_TICK_LOWER,
            MED_TICK_UPPER,
            MED_SQRT_PRICE,
            10e18, // liquidity
            50e18  // parent contribution
        );

        _testPriceRange(
            parentVault,
            derivativeVault,
            childPoolId,
            0.5e18,  // expected min price
            5e18,    // expected max price
            "MEDIUM"
        );
    }

    function test_HighPriceRange() public {
        console.log("\n=== TESTING HIGH PRICE RANGE (1 to 10 parent per derivative) ===");

        (address parentVault, address derivativeVault, PoolId childPoolId) = _setupDerivative(
            "High Price Derivative",
            "HIGH",
            HIGH_TICK_LOWER,
            HIGH_TICK_UPPER,
            HIGH_SQRT_PRICE,
            10e18,  // liquidity
            100e18  // parent contribution
        );

        _testPriceRange(
            parentVault,
            derivativeVault,
            childPoolId,
            1e18,   // expected min price
            10e18,  // expected max price
            "HIGH"
        );
    }

    function test_AllPriceRangesComparison() public {
        console.log("\n=== COMPARING ALL PRICE RANGES ===");

        // Setup all three derivatives
        (address parentVault, address lowDerivative, PoolId lowPoolId) = _setupDerivative(
            "Low Price Derivative",
            "LOW",
            LOW_TICK_LOWER,
            LOW_TICK_UPPER,
            LOW_SQRT_PRICE,
            10e18,
            20e18
        );

        (, address medDerivative, PoolId medPoolId) = _setupDerivative(
            "Medium Price Derivative",
            "MED",
            MED_TICK_LOWER,
            MED_TICK_UPPER,
            MED_SQRT_PRICE,
            10e18,
            50e18
        );

        (, address highDerivative, PoolId highPoolId) = _setupDerivative(
            "High Price Derivative",
            "HIGH",
            HIGH_TICK_LOWER,
            HIGH_TICK_UPPER,
            HIGH_SQRT_PRICE,
            10e18,
            100e18
        );

        // Test buying 1 derivative from each pool with parent tokens
        console.log("\n--- Buying 1 derivative from each pool ---");

        uint256 lowCost = _testBuyDerivative(parentVault, lowDerivative, lowPoolId, 1e18);
        console.log("LOW range - Cost to buy 1 derivative:", lowCost / 1e18, "parent tokens");
        assertGe(lowCost, 0.08e18, "Low range cost should be at least 0.08 parent");
        assertLe(lowCost, 1.2e18, "Low range cost should be at most 1.2 parent");

        uint256 medCost = _testBuyDerivative(parentVault, medDerivative, medPoolId, 1e18);
        console.log("MEDIUM range - Cost to buy 1 derivative:", medCost / 1e18, "parent tokens");
        assertGe(medCost, 0.4e18, "Medium range cost should be at least 0.4 parent");
        assertLe(medCost, 6e18, "Medium range cost should be at most 6 parent");

        uint256 highCost = _testBuyDerivative(parentVault, highDerivative, highPoolId, 1e18);
        console.log("HIGH range - Cost to buy 1 derivative:", highCost / 1e18, "parent tokens");
        assertGe(highCost, 0.8e18, "High range cost should be at least 0.8 parent");
        assertLe(highCost, 12e18, "High range cost should be at most 12 parent");

        // Verify ordering
        console.log("\n--- Price comparison ---");
        assertLt(lowCost, medCost, "Low price should be cheaper than medium");
        assertLt(medCost, highCost, "Medium price should be cheaper than high");
        console.log("✓ Price ordering verified: LOW < MEDIUM < HIGH");

        console.log("\n=== ALL PRICE RANGES COMPARISON PASSED ===");
    }

    function _setupDerivative(
        string memory name,
        string memory symbol,
        int24 tickLower,
        int24 tickUpper,
        uint160 sqrtPrice,
        uint256 liquidity,
        uint256 parentContribution
    ) internal returns (address parentVault, address derivativeVault, PoolId childPoolId) {
        // Setup parent vault
        parentVault = vaultFactory.deployVault(address(parentCollection), "Parent Token", "PRNT");
        factory.registerRootPool(parentVault, 3000, 60, SQRT_PRICE_1_1);

        // Mint parent tokens
        uint256 tokenCount = 500;
        uint256[] memory tokenIds = new uint256[](tokenCount);
        for (uint256 i = 0; i < tokenCount; i++) {
            uint256 tokenId = uint256(keccak256(abi.encodePacked(name, i)));
            parentCollection.mint(address(this), tokenId);
            tokenIds[i] = tokenId;
        }
        parentCollection.setApprovalForAll(parentVault, true);
        RemyVault(parentVault).deposit(tokenIds, address(this));

        // Add liquidity to root pool
        (PoolKey memory rootKey,) = factory.rootPool(parentVault);
        RemyVault(parentVault).approve(address(liquidityRouter), type(uint256).max);

        IPoolManager.ModifyLiquidityParams memory rootLiqParams = IPoolManager.ModifyLiquidityParams({
            tickLower: -887220,
            tickUpper: 887220,
            liquidityDelta: int256(10 * 1e18),
            salt: 0
        });

        liquidityRouter.modifyLiquidity{value: 10 ether}(rootKey, rootLiqParams, bytes(""));

        // Create derivative
        RemyVault(parentVault).approve(address(factory), type(uint256).max);

        DerivativeFactory.DerivativeParams memory params;
        params.parentVault = parentVault;
        params.nftName = name;
        params.nftSymbol = symbol;
        params.nftBaseUri = string(abi.encodePacked("ipfs://", symbol, "/"));
        params.nftOwner = address(this);
        params.vaultName = string(abi.encodePacked(name, " Token"));
        params.vaultSymbol = string(abi.encodePacked("d", symbol));
        params.fee = 3000;
        params.tickSpacing = 60;
        params.maxSupply = 100;
        params.tickLower = tickLower;
        params.tickUpper = tickUpper;
        params.sqrtPriceX96 = sqrtPrice;
        params.liquidity = liquidity;
        params.parentTokenContribution = parentContribution;
        params.derivativeTokenRecipient = address(this);

        (, derivativeVault, childPoolId) = factory.createDerivative(params);

        console.log("Derivative created:", symbol);
        console.log("  Parent vault:", parentVault);
        console.log("  Derivative vault:", derivativeVault);
        console.log("  Initial contribution:", parentContribution / 1e18, "parent tokens");
    }

    function _testPriceRange(
        address parentVault,
        address derivativeVault,
        PoolId poolId,
        uint256 expectedMinPrice,
        uint256 expectedMaxPrice,
        string memory rangeName
    ) internal {
        console.log("\n--- Testing", rangeName, "price range ---");
        console.log("Expected range:", expectedMinPrice / 1e18, "to", expectedMaxPrice / 1e18, "parent per derivative");

        // Get initial price
        (uint160 sqrtPriceX96,,,) = POOL_MANAGER.getSlot0(poolId);
        uint256 price = _sqrtPriceToPrice(sqrtPriceX96);
        console.log("Initial price from pool:", price / 1e18, "parent per derivative (approx)");

        // Setup for swaps
        RemyVault(parentVault).approve(address(swapRouter), type(uint256).max);
        MinterRemyVault(derivativeVault).approve(address(swapRouter), type(uint256).max);

        // Test buying derivatives at current price
        uint256 costToBuy = _testBuyDerivative(parentVault, derivativeVault, poolId, 1e18);
        console.log("Cost to buy 1 derivative:", costToBuy / 1e18, "parent tokens");

        // Verify price is within expected range (with some tolerance for fees/slippage)
        assertGe(costToBuy, expectedMinPrice * 8 / 10, "Price below minimum range");
        assertLe(costToBuy, expectedMaxPrice * 12 / 10, "Price above maximum range");

        console.log("✓ Price is within expected range");
    }

    function _testBuyDerivative(
        address parentVault,
        address derivativeVault,
        PoolId poolId,
        uint256 derivativeAmount
    ) internal returns (uint256 parentCost) {
        PoolKey memory poolKey = _buildChildKey(derivativeVault, parentVault, 3000, 60);
        bool parentIsCurrency0 = Currency.unwrap(poolKey.currency0) == parentVault;

        uint256 parentBefore = RemyVault(parentVault).balanceOf(address(this));
        uint256 derivBefore = MinterRemyVault(derivativeVault).balanceOf(address(this));

        // Try to buy specified amount of derivatives
        IPoolManager.SwapParams memory swapParams = IPoolManager.SwapParams({
            zeroForOne: parentIsCurrency0, // Parent -> Derivative
            amountSpecified: parentIsCurrency0 ? int256(derivativeAmount) : -int256(derivativeAmount),
            sqrtPriceLimitX96: parentIsCurrency0 ? TickMath.MIN_SQRT_PRICE + 1 : TickMath.MAX_SQRT_PRICE - 1
        });

        PoolSwapTest.TestSettings memory settings =
            PoolSwapTest.TestSettings({takeClaims: false, settleUsingBurn: false});

        try swapRouter.swap(poolKey, swapParams, settings, bytes("")) {
            uint256 parentAfter = RemyVault(parentVault).balanceOf(address(this));
            uint256 derivAfter = MinterRemyVault(derivativeVault).balanceOf(address(this));

            parentCost = parentBefore - parentAfter;
            uint256 derivReceived = derivAfter - derivBefore;

            if (derivReceived > 0) {
                return (parentCost * 1e18) / derivReceived; // Return price per derivative
            }
        } catch {
            // If exact output swap fails, try with input amount
            swapParams.amountSpecified = -int256(derivativeAmount * 2); // Spend up to 2x expected
            swapRouter.swap(poolKey, swapParams, settings, bytes(""));

            uint256 parentAfter = RemyVault(parentVault).balanceOf(address(this));
            uint256 derivAfter = MinterRemyVault(derivativeVault).balanceOf(address(this));

            parentCost = parentBefore - parentAfter;
            uint256 derivReceived = derivAfter - derivBefore;

            if (derivReceived > 0) {
                return (parentCost * 1e18) / derivReceived;
            }
        }

        return parentCost;
    }

    function _sqrtPriceToPrice(uint160 sqrtPriceX96) internal pure returns (uint256) {
        // Convert sqrtPriceX96 to actual price
        // price = (sqrtPriceX96 / 2^96)^2
        uint256 price = (uint256(sqrtPriceX96) * uint256(sqrtPriceX96)) >> 192;
        return price;
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