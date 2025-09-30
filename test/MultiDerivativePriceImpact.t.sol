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
import {DerivativeTestUtils} from "./DerivativeTestUtils.sol";

import {Hooks} from "@uniswap/v4-core/src/libraries/Hooks.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
import {Currency, CurrencyLibrary} from "@uniswap/v4-core/src/types/Currency.sol";
import {StateLibrary} from "@uniswap/v4-core/src/libraries/StateLibrary.sol";
import {PoolModifyLiquidityTest} from "@uniswap/v4-core/src/test/PoolModifyLiquidityTest.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";

import {PoolSwapTest} from "@uniswap/v4-core/src/test/PoolSwapTest.sol";

/**
 * @title MultiDerivativePriceImpact
 * @notice Simulates price impact of minting out three 1k derivative collections
 *
 * Test Flow:
 * 1. Initialize parent collection pool at 0.01 ETH per parent token
 * 2. Create three derivative collections (1k supply each)
 * 3. For each derivative, simulate complete mint-out via ETH -> Parent -> Derivative swaps
 * 4. Track parent token price impact throughout all three mint-outs
 * 5. Report cumulative fees collected from all swapping activity
 */
contract MultiDerivativePriceImpact is BaseTest, DerivativeTestUtils {
    using PoolIdLibrary for PoolKey;
    using CurrencyLibrary for Currency;
    using StateLibrary for IPoolManager;

    uint160 internal constant SQRT_PRICE_1_1 = 79228162514264337593543950336;
    // 0.01 ETH per parent: sqrt(0.01) * 2^96 = 7922816251426433759354395034
    uint160 internal constant SQRT_PRICE_0_01 = 7922816251426433759354395034;
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

    RemyVaultFactory internal vaultFactory;
    RemyVaultHook internal hook;
    DerivativeFactory internal factory;
    MockERC721Simple internal parentCollection;
    PoolModifyLiquidityTest internal liquidityRouter;
    PoolSwapTest internal swapRouter;

    address internal trader;

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

        liquidityRouter = new PoolModifyLiquidityTest(POOL_MANAGER);
        swapRouter = new PoolSwapTest(POOL_MANAGER);

        // Create separate trader address
        trader = makeAddr("TRADER");
        vm.deal(trader, 1_000_000 ether);
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

        // Register the root pool with the factory
        factory.registerRootPool(parentVault, fee, tickSpacing);

        return key.toId();
    }

    function test_ThreeDerivativesFullMintOut() public {
        console.log("\n");
        console.log("====================================================================");
        console.log("  THREE DERIVATIVE COLLECTIONS MINT-OUT SIMULATION");
        console.log("  Parent Pool Initial Price: 1:1 ETH per Parent Token");
        console.log("  Derivative Collections: 3 x 1000 supply");
        console.log("  Swap via: ETH -> Parent -> Derivative (two-step)");
        console.log("====================================================================\n");

        // Setup parent vault and pool at 1:1 ETH per parent
        address parentVault = vaultFactory.deployVault(address(parentCollection));
        PoolId rootPoolId = _initRootPool(parentVault, 3000, 60, SQRT_PRICE_1_1);

        // Mint parent NFTs and deposit - need enough for liquidity + derivatives
        uint256[] memory tokenIds = new uint256[](10000);
        for (uint256 i = 0; i < 10000; i++) {
            parentCollection.mint(address(this), i + 1);
            tokenIds[i] = i + 1;
        }
        parentCollection.setApprovalForAll(parentVault, true);
        RemyVault(parentVault).deposit(tokenIds, address(this));
        RemyVault(parentVault).approve(address(factory), type(uint256).max);

        // Add liquidity to parent/ETH pool
        (PoolKey memory rootKey,) = factory.rootPool(parentVault);
        RemyVault(parentVault).approve(address(liquidityRouter), type(uint256).max);

        IPoolManager.ModifyLiquidityParams memory rootLiqParams = IPoolManager.ModifyLiquidityParams({
            tickLower: -887220,
            tickUpper: 887220,
            liquidityDelta: int256(50 * 1e18),
            salt: 0
        });
        liquidityRouter.modifyLiquidity{value: 50 ether}(rootKey, rootLiqParams, bytes(""));

        (uint160 initialParentPrice,,,) = POOL_MANAGER.getSlot0(rootPoolId);
        console.log("--- INITIAL PARENT POOL STATE ---");
        console.log("Parent/ETH sqrtPrice:", initialParentPrice);
        console.log("Parent total supply:", RemyVault(parentVault).totalSupply() / 1e18);
        console.log("Liquidity provided: 50 parent + 50 ETH");

        // Track cumulative metrics
        uint256 totalETHSpent = 0;
        uint256 totalDerivativesReceived = 0;
        uint256 totalFeesCollected = 0;

        // Create and mint out three derivative collections
        string[3] memory names = ["Alpha Collection", "Beta Collection", "Gamma Collection"];

        for (uint256 i = 0; i < 3; i++) {
            // Three derivatives
            console.log("\n");
            console.log("====================================================================");
            console.log("  DERIVATIVE #", i + 1, ":", names[i]);
            console.log("====================================================================");

            (, uint256 ethSpent, uint256 derivativesReceived, uint256 feesCollected) = _createAndMintOutDerivative(
                parentVault,
                rootPoolId,
                names[i],
                1000, // maxSupply
                -887220, // tickLower - full range
                887220, // tickUpper - full range
                SQRT_PRICE_1_1, // sqrtPrice 1:1
                100 * 1e18, // liquidity
                100 * 1e18 // parent contribution
            );

            totalETHSpent += ethSpent;
            totalDerivativesReceived += derivativesReceived;
            totalFeesCollected += feesCollected;

            // Check parent price after this derivative
            (uint160 currentParentPrice,,,) = POOL_MANAGER.getSlot0(rootPoolId);
            console.log("\n--- PARENT PRICE AFTER DERIVATIVE #", i + 1, "---");
            console.log("Current parent/ETH sqrtPrice:", currentParentPrice);
            int256 priceChangeBps = int256(uint256(currentParentPrice) * 10000 / uint256(initialParentPrice)) - 10000;
            console.log("Cumulative price change (bps):", priceChangeBps);

            if (priceChangeBps > 0) {
                console.log("Direction: Parent MORE expensive (price UP)");
                console.log("  Change (bps):", uint256(priceChangeBps));
            } else if (priceChangeBps < 0) {
                console.log("Direction: Parent LESS expensive (price DOWN)");
                console.log("  Change (bps):", uint256(-priceChangeBps));
            }
        }

        // Final summary
        console.log("\n");
        console.log("====================================================================");
        console.log("  FINAL SUMMARY: ALL THREE DERIVATIVES MINTED OUT");
        console.log("====================================================================\n");

        (uint160 finalParentPrice,,,) = POOL_MANAGER.getSlot0(rootPoolId);
        int256 totalPriceChangeBps = int256(uint256(finalParentPrice) * 10000 / uint256(initialParentPrice)) - 10000;

        console.log("--- CUMULATIVE TOTALS ---");
        console.log("Total ETH spent by trader (wei):", totalETHSpent);
        console.log("Total derivatives received (wei):", totalDerivativesReceived);
        console.log("Total fees collected (wei):", totalFeesCollected);

        console.log("\n--- PARENT TOKEN PRICE IMPACT ---");
        console.log("Initial sqrtPrice:", initialParentPrice);
        console.log("Final sqrtPrice:", finalParentPrice);
        console.log("Total price change (bps):", totalPriceChangeBps);

        if (totalPriceChangeBps > 0) {
            console.log("Impact: Parent became MORE expensive");
            console.log("  Total change (bps):", uint256(totalPriceChangeBps));
        } else if (totalPriceChangeBps < 0) {
            console.log("Impact: Parent became LESS expensive");
            console.log("  Total change (bps):", uint256(-totalPriceChangeBps));
        }

        // Calculate actual price in ETH
        uint256 initialPriceInETH = (uint256(initialParentPrice) * uint256(initialParentPrice) * 1e18) >> 192;
        uint256 finalPriceInETH = (uint256(finalParentPrice) * uint256(finalParentPrice) * 1e18) >> 192;

        console.log("\n--- READABLE PRICES ---");
        console.log("Initial price (wei):", initialPriceInETH);
        console.log("Final price (wei):", finalPriceInETH);

        console.log("\n====================================================================");
        console.log("  SIMULATION COMPLETE");
        console.log("====================================================================\n");
    }

    function _createAndMintOutDerivative(
        address parentVault,
        PoolId, /* rootPoolId */
        string memory name,
        uint256 maxSupply,
        int24 tickLower,
        int24 tickUpper,
        uint160 sqrtPriceX96,
        uint128 liquidity,
        uint256 parentContribution
    )
        internal
        returns (address derivativeVault, uint256 ethSpent, uint256 derivativesReceived, uint256 feesCollected)
    {
        // Create derivative
        DerivativeFactory.DerivativeParams memory params;
        params.parentCollection = RemyVault(parentVault).erc721();
        params.nftName = name;
        params.nftSymbol = "DRV";
        params.nftBaseUri = "ipfs://test/";
        params.nftOwner = address(this);
        params.fee = 3000;
        params.tickSpacing = 60;
        params.maxSupply = maxSupply;
        params.tickLower = tickLower;
        params.tickUpper = tickUpper;
        params.sqrtPriceX96 = sqrtPriceX96;
        params.liquidity = liquidity;
        params.parentTokenContribution = parentContribution;
        params.derivativeTokenRecipient = address(1); // Send leftover to dead address so they can't interfere
        params.salt = mineSaltForToken1(factory, parentVault, params.maxSupply);

        (, derivativeVault,) = factory.createDerivative(params);

        console.log("\n--- DERIVATIVE CREATED ---");
        console.log("Name:", name);
        console.log("Max supply:", maxSupply, "NFTs");
        console.log("Initial token supply (full):", MinterRemyVault(derivativeVault).totalSupply());
        console.log("Initial token supply (readable):", MinterRemyVault(derivativeVault).totalSupply() / 1e18);
        console.log("Test contract balance:", MinterRemyVault(derivativeVault).balanceOf(address(this)));

        console.log("\n--- MINTING OUT VIA ETH -> PARENT -> DERIVATIVE ---");

        uint256 derivativeSupply = MinterRemyVault(derivativeVault).totalSupply();
        uint256 targetToBuy = derivativeSupply; // Try to buy entire supply
        uint256 totalDerivativesObtained = 0;
        uint256 totalETHUsed = 0;
        uint256 swapCount = 0;
        uint256 maxSwaps = 50; // Limit swaps

        (PoolKey memory rootKey,) = factory.rootPool(parentVault);
        PoolKey memory childKey = _buildChildKey(derivativeVault, parentVault, 3000, 60);
        bool parentIsCurrency0Child = Currency.unwrap(childKey.currency0) == parentVault;

        // Debug pool structure
        console.log("Root pool - currency0:", Currency.unwrap(rootKey.currency0) == address(0) ? "ETH" : "Parent");
        console.log("Root pool - currency1:", Currency.unwrap(rootKey.currency1) == address(0) ? "ETH" : "Parent");
        console.log("Child pool - parent is currency0:", parentIsCurrency0Child);

        PoolSwapTest.TestSettings memory settings =
            PoolSwapTest.TestSettings({takeClaims: false, settleUsingBurn: false});

        // Approve tokens
        RemyVault(parentVault).approve(address(swapRouter), type(uint256).max);
        MinterRemyVault(derivativeVault).approve(address(swapRouter), type(uint256).max);

        // Execute swaps in chunks: ETH -> Parent, then Parent -> Derivative
        while (swapCount < maxSwaps && totalDerivativesObtained < targetToBuy * 95 / 100) {
            uint256 ethChunk = 1 ether; // 1 ETH per swap

            uint256 parentBalBefore = RemyVault(parentVault).balanceOf(address(this));

            // Step 1: Swap ETH -> Parent
            IPoolManager.SwapParams memory swapToParent = IPoolManager.SwapParams({
                zeroForOne: true, // ETH (currency0) -> Parent (currency1)
                amountSpecified: -int256(ethChunk),
                sqrtPriceLimitX96: TickMath.MIN_SQRT_PRICE + 1
            });

            try swapRouter.swap{value: ethChunk}(rootKey, swapToParent, settings, bytes("")) {
                uint256 parentBalAfter = RemyVault(parentVault).balanceOf(address(this));
                uint256 parentReceived = parentBalAfter - parentBalBefore;

                if (swapCount == 0) {
                    console.log("\nFirst swap details:");
                    console.log("  ETH spent:", ethChunk / 1e18);
                    console.log("  Parent received:", parentReceived);
                }

                if (parentReceived == 0) break;

                // Step 2: Swap Parent -> Derivative
                uint256 derivBalBefore = MinterRemyVault(derivativeVault).balanceOf(address(this));

                IPoolManager.SwapParams memory swapToDerivative = IPoolManager.SwapParams({
                    zeroForOne: parentIsCurrency0Child,
                    amountSpecified: -int256(parentReceived),
                    sqrtPriceLimitX96: parentIsCurrency0Child ? TickMath.MIN_SQRT_PRICE + 1 : TickMath.MAX_SQRT_PRICE - 1
                });

                try swapRouter.swap(childKey, swapToDerivative, settings, bytes("")) {
                    uint256 derivBalAfter = MinterRemyVault(derivativeVault).balanceOf(address(this));
                    uint256 derivReceived = derivBalAfter - derivBalBefore;

                    if (swapCount == 0) {
                        console.log("  Parent spent:", parentReceived);
                        console.log("  Derivative received:", derivReceived);
                    }

                    if (derivReceived == 0) break;

                    totalDerivativesObtained += derivReceived;
                    totalETHUsed += ethChunk;
                    swapCount++;
                } catch {
                    break;
                }
            } catch {
                break;
            }
        }

        console.log("Swaps executed:", swapCount);
        console.log("ETH spent (wei):", totalETHUsed);
        console.log("Derivatives received (wei):", totalDerivativesObtained);

        uint256 percentMinted = (totalDerivativesObtained * 100) / derivativeSupply;
        console.log("Percent of supply minted:", percentMinted, "%");

        // Estimate fees (approximation based on total ETH spent)
        uint256 estimatedFees = (totalETHUsed * TOTAL_FEE_BPS) / 10000;

        ethSpent = totalETHUsed;
        derivativesReceived = totalDerivativesObtained;
        feesCollected = estimatedFees;
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
