// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {BaseTest} from "./BaseTest.t.sol";
import {console2 as console} from "forge-std/console2.sol";

import {DerivativeFactory} from "../src/DerivativeFactory.sol";
import {wNFTMinter} from "../src/wNFTMinter.sol";
import {wNFTFactory} from "../src/wNFTFactory.sol";
import {wNFTHook} from "../src/wNFTHook.sol";
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

/**
 * @title DerivativeMintOutSimulation
 * @notice Simulates complete mint-out of derivative collections at different price points
 *
 * For each scenario (LOW, MEDIUM, HIGH price), this test:
 * 1. Creates a derivative collection with specific price range
 * 2. Simulates traders buying derivative tokens until sold out
 * 3. Tracks all fees collected by child pool and parent pool
 * 4. Measures parent collection price impact throughout
 */
contract DerivativeMintOutSimulation is BaseTest, DerivativeTestUtils {
    using PoolIdLibrary for PoolKey;
    using CurrencyLibrary for Currency;
    using StateLibrary for IPoolManager;

    uint160 internal constant SQRT_PRICE_1_1 = 79228162514264337593543950336;
    uint160 internal constant CLEAR_HOOK_PERMISSIONS_MASK = ~uint160(0) << 14;
    uint160 internal constant HOOK_FLAGS = Hooks.BEFORE_SWAP_FLAG | Hooks.AFTER_SWAP_FLAG
        | Hooks.BEFORE_SWAP_RETURNS_DELTA_FLAG | Hooks.AFTER_SWAP_RETURNS_DELTA_FLAG;
    uint160 internal constant HOOK_ADDRESS_SEED = uint160(0x4444000000000000000000000000000000000000);
    address internal constant HOOK_ADDRESS =
        address(uint160((HOOK_ADDRESS_SEED & CLEAR_HOOK_PERMISSIONS_MASK) | HOOK_FLAGS));
    address internal constant POOL_MANAGER_ADDRESS = 0x498581fF718922c3f8e6A244956aF099B2652b2b;
    IPoolManager internal constant POOL_MANAGER = IPoolManager(POOL_MANAGER_ADDRESS);

    // Fee structure: 10% total, 7.5% to child, 2.5% to parent
    uint256 internal constant TOTAL_FEE_BPS = 1000; // 10%
    uint256 internal constant CHILD_FEE_BPS = 750; // 7.5%
    uint256 internal constant PARENT_FEE_BPS = 250; // 2.5%

    wNFTFactory internal vaultFactory;
    wNFTHook internal hook;
    DerivativeFactory internal factory;
    MockERC721Simple internal parentCollection;
    PoolSwapTest internal swapRouter;
    PoolModifyLiquidityTest internal liquidityRouter;

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
    function _initRootPool(address parentVault, uint24, /* fee */ int24, /* tickSpacing */ uint160 sqrtPriceX96)
        internal
        returns (PoolId poolId)
    {
        uint24 fee = 0x800000; // LPFeeLibrary.DYNAMIC_FEE_FLAG
        PoolKey memory key = _buildChildKey(address(0), parentVault, fee, factory.TICK_SPACING());
        PoolKey memory emptyKey;
        vm.prank(address(factory));
        hook.addChild(key, false, emptyKey);
        POOL_MANAGER.initialize(key, sqrtPriceX96);

        return key.toId();
    }

    function test_LowPriceDerivativeMintOut() public {
        console.log("\n");
        console.log("================================================================");
        console.log("  LOW PRICE DERIVATIVE MINT-OUT SIMULATION");
        console.log("  Target: 0.1 parent per derivative (cheap derivative)");
        console.log("================================================================");

        _runMintOutSimulation(
            "Low Price Derivative",
            -23040, // 0.1 parent per derivative
            0, // 1.0 parent per derivative
            25054144837504793750611689472, // sqrtPrice for 0.1
            100, // max supply
            50 * 1e18, // parent contribution
            20e18 // liquidity
        );
    }

    function test_MediumPriceDerivativeMintOut() public {
        console.log("\n");
        console.log("================================================================");
        console.log("  MEDIUM PRICE DERIVATIVE MINT-OUT SIMULATION");
        console.log("  Target: 0.5 parent per derivative (medium derivative)");
        console.log("================================================================");

        _runMintOutSimulation(
            "Medium Price Derivative",
            -11520, // 0.5 parent per derivative
            11520, // 2.0 parent per derivative
            56022770974786139918731938227, // sqrtPrice for 0.5
            100, // max supply
            50 * 1e18, // parent contribution
            20e18 // liquidity
        );
    }

    function test_HighPriceDerivativeMintOut() public {
        console.log("\n");
        console.log("================================================================");
        console.log("  HIGH PRICE DERIVATIVE MINT-OUT SIMULATION");
        console.log("  Target: 1.0 parent per derivative (expensive derivative)");
        console.log("================================================================");

        _runMintOutSimulation(
            "High Price Derivative",
            0, // 1.0 parent per derivative
            23040, // 10 parent per derivative
            79228162514264337593543950336, // sqrtPrice for 1.0
            100, // max supply
            100 * 1e18, // parent contribution
            20e18 // liquidity
        );
    }

    function _runMintOutSimulation(
        string memory name,
        int24 tickLower,
        int24 tickUpper,
        uint160 sqrtPriceX96,
        uint256 maxSupply,
        uint256 parentContribution,
        uint128 liquidity
    ) internal {
        // Setup parent vault and root pool
        address parentVault = vaultFactory.deployVault(address(parentCollection));
        PoolId rootPoolId = _initRootPool(parentVault, 3000, 60, SQRT_PRICE_1_1);

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
            liquidityDelta: int256(uint256(50 * 1e18)),
            salt: 0
        });
        liquidityRouter.modifyLiquidity{value: 50 ether}(rootKey, rootLiqParams, bytes(""));

        console.log("\n--- INITIAL STATE ---");
        (uint160 initialParentPrice,,,) = POOL_MANAGER.getSlot0(rootPoolId);
        console.log("Parent/ETH sqrtPrice:", initialParentPrice);
        console.log("Parent total supply:", wNFT(parentVault).totalSupply() / 1e18);

        // Create derivative
        DerivativeFactory.DerivativeParams memory params;
        params.parentCollection = wNFT(parentVault).erc721();
        params.nftName = name;
        params.nftSymbol = "DRV";
        params.nftBaseUri = "ipfs://test/";
        params.nftOwner = address(this);
        params.fee = 3000;
        params.maxSupply = maxSupply;
        params.tickLower = tickLower;
        params.tickUpper = tickUpper;
        params.sqrtPriceX96 = sqrtPriceX96;
        params.liquidity = liquidity;
        params.parentTokenContribution = parentContribution;
        params.derivativeTokenRecipient = address(this);
        params.salt = mineSaltForToken1(factory, parentVault, params.maxSupply);

        (, address derivativeVault, PoolId childPoolId) = factory.createDerivative(params);

        PoolKey memory childKey = _buildChildKey(derivativeVault, parentVault, 3000, factory.TICK_SPACING());
        bool parentIsCurrency0 = Currency.unwrap(childKey.currency0) == parentVault;

        (uint160 initialDerivPrice,,,) = POOL_MANAGER.getSlot0(childPoolId);
        uint256 derivativeSupply = wNFTMinter(derivativeVault).totalSupply();

        console.log("\n--- DERIVATIVE POOL CREATED ---");
        console.log("Collection name:", name);
        console.log("Max supply:", maxSupply, "NFTs");
        console.log("Derivative token supply:", derivativeSupply / 1e18);
        console.log("Initial derivative sqrtPrice:", initialDerivPrice);
        console.log("Parent is currency0:", parentIsCurrency0);

        // Approve tokens for swapping
        wNFT(parentVault).approve(address(swapRouter), type(uint256).max);
        wNFTMinter(derivativeVault).approve(address(swapRouter), type(uint256).max);

        console.log("\n--- SIMULATING MINT-OUT (BUYING ALL DERIVATIVES) ---");

        PoolSwapTest.TestSettings memory settings =
            PoolSwapTest.TestSettings({takeClaims: false, settleUsingBurn: false});

        // Track cumulative metrics
        uint256 totalParentSpent = 0;
        uint256 totalDerivativeReceived = 0;
        uint256 swapCount = 0;

        // Try to buy all available derivatives in chunks
        uint256 derivativeBalance = wNFTMinter(derivativeVault).balanceOf(address(this));
        uint256 targetToBuy = derivativeSupply - derivativeBalance; // Buy what we don't have

        // Attempt swaps until we've bought most of the supply or hit limits
        uint256 chunkSize = 10 * 1e18; // Buy in 10 parent token chunks
        uint256 maxSwaps = 20; // Limit number of swaps to prevent infinite loops

        while (swapCount < maxSwaps) {
            uint256 parentBalBefore = wNFT(parentVault).balanceOf(address(this));
            uint256 derivBalBefore = wNFTMinter(derivativeVault).balanceOf(address(this));

            // Adjust chunk size if we're running low on parent tokens
            uint256 actualChunkSize = chunkSize;
            if (parentBalBefore < chunkSize) {
                actualChunkSize = parentBalBefore / 2; // Use half of remaining
            }

            if (actualChunkSize < 0.1e18) break; // Stop if less than 0.1 parent left

            IPoolManager.SwapParams memory swapParams = IPoolManager.SwapParams({
                zeroForOne: parentIsCurrency0,
                amountSpecified: -int256(actualChunkSize),
                sqrtPriceLimitX96: parentIsCurrency0 ? TickMath.MIN_SQRT_PRICE + 1 : TickMath.MAX_SQRT_PRICE - 1
            });

            try swapRouter.swap(childKey, swapParams, settings, bytes("")) {
                uint256 parentBalAfter = wNFT(parentVault).balanceOf(address(this));
                uint256 derivBalAfter = wNFTMinter(derivativeVault).balanceOf(address(this));

                uint256 parentSpent = parentBalBefore - parentBalAfter;
                uint256 derivReceived = derivBalAfter - derivBalBefore;

                if (derivReceived == 0) break; // No more to buy

                totalParentSpent += parentSpent;
                totalDerivativeReceived += derivReceived;
                swapCount++;
            } catch {
                break; // Swap failed, we've hit a limit
            }
        }

        console.log("Total swaps executed:", swapCount);
        console.log("Total parent spent:", totalParentSpent / 1e18, ".", (totalParentSpent % 1e18) / 1e16);
        console.log(
            "Total derivative received:", totalDerivativeReceived / 1e18, ".", (totalDerivativeReceived % 1e18) / 1e16
        );

        if (totalDerivativeReceived > 0) {
            uint256 avgPrice = (totalParentSpent * 1e18) / totalDerivativeReceived;
            console.log("Average price paid (parent/derivative):", avgPrice / 1e18, ".", (avgPrice % 1e18) / 1e16);
        }

        // Calculate fees
        console.log("\n--- FEE ANALYSIS ---");
        uint256 totalFees = (totalParentSpent * TOTAL_FEE_BPS) / 10000;
        uint256 childFees = (totalFees * CHILD_FEE_BPS) / 1000;
        uint256 parentFees = totalFees - childFees;

        console.log("Total fees collected (10%):", totalFees / 1e18, ".", (totalFees % 1e18) / 1e16);
        console.log("Child pool fees (7.5%):", childFees / 1e18, ".", (childFees % 1e18) / 1e16);
        console.log("Parent pool fees (2.5%):", parentFees / 1e18, ".", (parentFees % 1e18) / 1e16);

        // Check price impact
        console.log("\n--- PRICE IMPACT ANALYSIS ---");
        (uint160 finalParentPrice,,,) = POOL_MANAGER.getSlot0(rootPoolId);
        (uint160 finalDerivPrice,,,) = POOL_MANAGER.getSlot0(childPoolId);

        console.log("Parent Collection (Parent/ETH Pool):");
        console.log("  Initial sqrtPrice:", initialParentPrice);
        console.log("  Final sqrtPrice:", finalParentPrice);
        int256 parentPriceChangeBps = int256(uint256(finalParentPrice) * 10000 / uint256(initialParentPrice)) - 10000;
        console.log("  Price change (bps):", parentPriceChangeBps);

        if (parentPriceChangeBps > 0) {
            console.log("  Impact: Parent became MORE expensive (price UP)");
        } else if (parentPriceChangeBps < 0) {
            console.log("  Impact: Parent became LESS expensive (price DOWN)");
        } else {
            console.log("  Impact: No price change");
        }

        console.log("\nDerivative Collection (Derivative/Parent Pool):");
        console.log("  Initial sqrtPrice:", initialDerivPrice);
        console.log("  Final sqrtPrice:", finalDerivPrice);
        int256 derivPriceChangeBps = int256(uint256(finalDerivPrice) * 10000 / uint256(initialDerivPrice)) - 10000;
        console.log("  Price change (bps):", derivPriceChangeBps);

        if (derivPriceChangeBps > 0) {
            console.log("  Impact: Derivative became MORE expensive");
        } else if (derivPriceChangeBps < 0) {
            console.log("  Impact: Derivative became LESS expensive");
        } else {
            console.log("  Impact: No price change");
        }

        // Final supply check
        uint256 finalDerivativeBalance = wNFTMinter(derivativeVault).balanceOf(address(this));
        uint256 percentBought = (finalDerivativeBalance * 100) / derivativeSupply;

        console.log("\n--- FINAL STATE ---");
        console.log("Derivative balance:", finalDerivativeBalance / 1e18, ".", (finalDerivativeBalance % 1e18) / 1e16);
        console.log("Percentage of supply acquired:", percentBought, "%");
        console.log("Parent total supply:", wNFT(parentVault).totalSupply() / 1e18);

        console.log("\n================================================================");
        console.log("  SIMULATION COMPLETE");
        console.log("================================================================\n");
    }

    function _buildChildKey(address tokenA, address tokenB, uint24 fee, int24 spacing)
        internal
        pure
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
