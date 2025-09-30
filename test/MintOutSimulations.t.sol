// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {BaseTest} from "./BaseTest.t.sol";
import {DerivativeTestUtils} from "./DerivativeTestUtils.sol";
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
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {FullMath} from "@uniswap/v4-core/src/libraries/FullMath.sol";
import {LiquidityAmounts} from "@uniswap/v4-periphery/src/libraries/LiquidityAmounts.sol";
import {BalanceDelta, BalanceDeltaLibrary} from "@uniswap/v4-core/src/types/BalanceDelta.sol";
import {PoolSwapTest} from "@uniswap/v4-core/src/test/PoolSwapTest.sol";
import {PoolModifyLiquidityTest} from "@uniswap/v4-core/src/test/PoolModifyLiquidityTest.sol";

contract MintOutSimulations is BaseTest, DerivativeTestUtils {
    using PoolIdLibrary for PoolKey;
    using CurrencyLibrary for Currency;
    using StateLibrary for IPoolManager;
    using BalanceDeltaLibrary for BalanceDelta;

    uint160 internal constant CLEAR_HOOK_PERMISSIONS_MASK = ~uint160(0) << 14;
    uint160 internal constant HOOK_FLAGS = Hooks.BEFORE_SWAP_FLAG | Hooks.AFTER_SWAP_FLAG
        | Hooks.BEFORE_SWAP_RETURNS_DELTA_FLAG | Hooks.AFTER_SWAP_RETURNS_DELTA_FLAG;
    uint160 internal constant HOOK_ADDRESS_SEED = uint160(0x4444000000000000000000000000000000000000);
    address internal constant HOOK_ADDRESS =
        address(uint160((HOOK_ADDRESS_SEED & CLEAR_HOOK_PERMISSIONS_MASK) | HOOK_FLAGS));
    address internal constant POOL_MANAGER_ADDRESS = 0x498581fF718922c3f8e6A244956aF099B2652b2b;
    IPoolManager internal constant POOL_MANAGER = IPoolManager(POOL_MANAGER_ADDRESS);

    uint24 internal constant POOL_FEE = 3000;
    int24 internal constant POOL_TICK_SPACING = 60;

    // Parent pool target: 300 parent tokens paired with ~2 ETH, price 0.01 ETH per parent
    int24 internal constant PARENT_INITIAL_TICK = 46080;   // ~0.01 ETH per parent
    int24 internal constant PARENT_TICK_LOWER = 18960;     // ~0.15 ETH per parent lower bound
    int24 internal constant PARENT_TICK_UPPER = 52980;     // ~0.005 ETH per parent upper bound
    uint256 internal constant PARENT_ETH_LIQUIDITY = 2 ether;
    uint256 internal constant PARENT_TOKEN_LIQUIDITY = 300 * 1e18;

    // Fee structure from RemyVaultHook: 10% total (7.5% child, 2.5% parent)
    uint256 internal constant TOTAL_FEE_BPS = 1000;
    uint256 internal constant CHILD_FEE_BPS = 750;

    RemyVaultFactory internal vaultFactory;
    RemyVaultHook internal hook;
    DerivativeFactory internal factory;
    MockERC721Simple internal parentCollection;
    PoolModifyLiquidityTest internal liquidityRouter;
    PoolSwapTest internal swapRouter;

    address internal trader;

    struct ScenarioConfig {
        string label;
        uint256 maxSupply;
        int24 baseTickLower;
        int24 baseTickUpper;
        int24 baseInitialTick;
        uint256 parentContribution;
        uint128 liquidity;
        uint256 ethChunk;
        uint256 maxRounds;
    }

    struct ParentPoolState {
        address parentVault;
        PoolKey rootKey;
        PoolId rootPoolId;
        uint160 initialSqrtPrice;
        uint128 liquidity;
        uint256 parentUsed;
        uint256 ethUsed;
    }

    struct ScenarioResult {
        uint256 ethSpent;
        uint256 parentSpent;
        uint256 derivativesBought;
        uint256 swapsExecuted;
        uint160 finalParentSqrtPrice;
        uint160 finalDerivativeSqrtPrice;
        uint160 initialParentSqrtPrice;
        uint160 initialDerivativeSqrtPrice;
    }

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

        trader = makeAddr("SIM_TRADER");
        vm.deal(trader, 5_000 ether);
    }

    // Helper to initialize a root pool directly (for testing the permissionless flow)
    function _initRootPool(address parentVault, uint24 /* fee */, int24 tickSpacing, uint160 sqrtPriceX96)
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

    function test_LowPriceDerivativeMintOut() public {
        ScenarioConfig memory config = _lowScenario();
        _runScenario(config);
    }

    function test_MediumPriceDerivativeMintOut() public {
        ScenarioConfig memory config = _mediumScenario();
        _runScenario(config);
    }

    function test_HighPriceDerivativeMintOut() public {
        ScenarioConfig memory config = _highScenario();
        _runScenario(config);
    }

    // ---------------------------------------------------------------------
    // Scenario Definitions
    // ---------------------------------------------------------------------

    function _lowScenario() internal pure returns (ScenarioConfig memory config) {
        config.label = "LOW PRICE (0.1 parent per derivative)";
        config.maxSupply = 1000;
        config.baseTickLower = -23040;  // ~0.0999 parent/derivative
        config.baseTickUpper = 0;        // 1.0 parent/derivative
        config.baseInitialTick = -22980; // Keep inside tick range (~0.1005)
        config.parentContribution = 400 * 1e18;
        config.liquidity = uint128(150 * 1e18);
        config.ethChunk = 0.25 ether;
        config.maxRounds = 120;
    }

    function _mediumScenario() internal pure returns (ScenarioConfig memory config) {
        config.label = "MEDIUM PRICE (0.5 parent per derivative)";
        config.maxSupply = 100;
        config.baseTickLower = -6960;    // ~0.498 parent/derivative
        config.baseTickUpper = 6960;     // ~2.006 parent/derivative
        config.baseInitialTick = -6900;  // ~0.505 parent/derivative
        config.parentContribution = 120 * 1e18;
        config.liquidity = uint128(40 * 1e18);
        config.ethChunk = 0.5 ether;
        config.maxRounds = 80;
    }

    function _highScenario() internal pure returns (ScenarioConfig memory config) {
        config.label = "HIGH PRICE (1.0 parent per derivative)";
        config.maxSupply = 100;
        config.baseTickLower = 0;        // 1.0 parent/derivative
        config.baseTickUpper = 23040;    // ~10 parent/derivative
        config.baseInitialTick = 60;     // ~1.006 parent/derivative (inside range)
        config.parentContribution = 180 * 1e18;
        config.liquidity = uint128(50 * 1e18);
        config.ethChunk = 0.75 ether;
        config.maxRounds = 80;
    }

    // ---------------------------------------------------------------------
    // Scenario Runner
    // ---------------------------------------------------------------------

    function _runScenario(ScenarioConfig memory config) internal {
        console.log("\n====================================================================");
        console.log("  DERIVATIVE MINT-OUT SIMULATION:");
        console.log("  %s", config.label);
        console.log("====================================================================\n");

        ParentPoolState memory parentState = _setupParentPool();

        console.log("Parent pool seeded with:");
        console.log("  Parent tokens used:", parentState.parentUsed / 1e18, ".", (parentState.parentUsed % 1e18) / 1e16);
        console.log("  ETH used:", parentState.ethUsed / 1e18, ".", (parentState.ethUsed % 1e18) / 1e16);

        string memory nftName = string.concat("Scenario ", config.label);
        string memory vaultName = string.concat("Token ", config.label);
        string memory vaultSymbol = "dDRV";

        (bool derivativeIsCurrency0,) = _predictDerivativeOrientation(config.maxSupply, parentState.parentVault, nftName, vaultName, vaultSymbol);
        (int24 initialTick, int24 tickLower, int24 tickUpper) = _scenarioTicks(config, derivativeIsCurrency0);
        uint160 sqrtPriceX96 = TickMath.getSqrtPriceAtTick(initialTick);

        console.log("Derivative pool orientation:");
        console.log("  derivativeIsCurrency0:", derivativeIsCurrency0);
        console.log("  tickLower:", tickLower);
        console.log("  tickUpper:", tickUpper);
        console.log("  initialTick:", initialTick);

        DerivativeFactory.DerivativeParams memory params;
        params.parentCollection = RemyVault(parentState.parentVault).erc721();
        params.nftName = nftName;
        params.nftSymbol = "DRV";
        params.nftBaseUri = "ipfs://mint-out/";
        params.nftOwner = address(this);
        params.vaultName = vaultName;
        params.vaultSymbol = vaultSymbol;
        params.fee = POOL_FEE;
        params.tickSpacing = POOL_TICK_SPACING;
        params.maxSupply = config.maxSupply;
        params.tickLower = tickLower;
        params.tickUpper = tickUpper;
        params.sqrtPriceX96 = sqrtPriceX96;
        params.liquidity = config.liquidity;
        params.parentTokenContribution = config.parentContribution;
        params.derivativeTokenRecipient = address(1);
        params.parentTokenRefundRecipient = address(this);
        params.salt = mineSaltForToken1(factory, parentState.parentVault, params.vaultName, params.vaultSymbol, params.maxSupply);

        (, address derivativeVault, PoolId childPoolId) = factory.createDerivative(params);

        PoolKey memory childKey = _buildChildKey(derivativeVault, parentState.parentVault, POOL_FEE, POOL_TICK_SPACING);
        bool parentIsCurrency0 = Currency.unwrap(childKey.currency0) == parentState.parentVault;
        require(parentIsCurrency0 == !derivativeIsCurrency0, "orientation mismatch");

        (uint160 initialParentSqrtPrice,,,) = POOL_MANAGER.getSlot0(parentState.rootPoolId);
        (uint160 initialDerivativeSqrtPrice,,,) = POOL_MANAGER.getSlot0(childPoolId);

        console.log("Initial parent sqrtPrice:", initialParentSqrtPrice);
        console.log("Initial derivative sqrtPrice:", initialDerivativeSqrtPrice);

        vm.deal(trader, config.ethChunk * config.maxRounds * 2);
        vm.prank(trader);
        RemyVault(parentState.parentVault).approve(address(POOL_MANAGER), type(uint256).max);
        vm.prank(trader);
        MinterRemyVault(derivativeVault).approve(address(POOL_MANAGER), type(uint256).max);

        ScenarioResult memory result = _simulateMintOut(config, parentState, childKey, childPoolId, derivativeVault, parentIsCurrency0, initialParentSqrtPrice, initialDerivativeSqrtPrice);

        _reportScenario(config, result, parentIsCurrency0, derivativeIsCurrency0, parentState.parentVault, derivativeVault);
    }

    // ---------------------------------------------------------------------
    // Simulation Execution
    // ---------------------------------------------------------------------

    function _simulateMintOut(
        ScenarioConfig memory config,
        ParentPoolState memory parentState,
        PoolKey memory childKey,
        PoolId childPoolId,
        address derivativeVault,
        bool parentIsCurrency0,
        uint160 initialParentSqrtPrice,
        uint160 initialDerivativeSqrtPrice
    ) internal returns (ScenarioResult memory result) {
        PoolSwapTest.TestSettings memory settings = PoolSwapTest.TestSettings({takeClaims: false, settleUsingBurn: false});

        uint256 totalEthSpent;
        uint256 totalParentSpent;
        uint256 totalDerivativesAcquired;
        uint256 swapsExecuted;

        uint256 derivativeSupply = MinterRemyVault(derivativeVault).totalSupply();

        for (uint256 i = 0; i < config.maxRounds; ++i) {
            uint256 parentBalanceBefore = RemyVault(parentState.parentVault).balanceOf(trader);
            uint256 derivativeBalanceBefore = MinterRemyVault(derivativeVault).balanceOf(trader);

            IPoolManager.SwapParams memory swapEthToParent = IPoolManager.SwapParams({
                zeroForOne: true,
                amountSpecified: -int256(config.ethChunk),
                sqrtPriceLimitX96: TickMath.MIN_SQRT_PRICE + 1
            });

            vm.startPrank(trader);
            try swapRouter.swap{value: config.ethChunk}(parentState.rootKey, swapEthToParent, settings, bytes("")) {
                vm.stopPrank();
            } catch {
                vm.stopPrank();
                break;
            }

            uint256 parentReceived = RemyVault(parentState.parentVault).balanceOf(trader) - parentBalanceBefore;
            if (parentReceived == 0) {
                break;
            }

            IPoolManager.SwapParams memory swapParentToDerivative = IPoolManager.SwapParams({
                zeroForOne: parentIsCurrency0,
                amountSpecified: -int256(parentReceived),
                sqrtPriceLimitX96: parentIsCurrency0 ? TickMath.MIN_SQRT_PRICE + 1 : TickMath.MAX_SQRT_PRICE - 1
            });

            vm.startPrank(trader);
            try swapRouter.swap(childKey, swapParentToDerivative, settings, bytes("")) {
                vm.stopPrank();
            } catch {
                vm.stopPrank();
                break;
            }

            uint256 derivativeReceived = MinterRemyVault(derivativeVault).balanceOf(trader) - derivativeBalanceBefore;
            if (derivativeReceived == 0) {
                break;
            }

            totalEthSpent += config.ethChunk;
            totalParentSpent += parentReceived;
            totalDerivativesAcquired += derivativeReceived;
            swapsExecuted += 1;

            if (totalDerivativesAcquired >= derivativeSupply * 999 / 1000) {
                break;
            }
        }

        (uint160 finalParentSqrtPrice,,,) = POOL_MANAGER.getSlot0(parentState.rootPoolId);
        (uint160 finalDerivativeSqrtPrice,,,) = POOL_MANAGER.getSlot0(childPoolId);

        result.ethSpent = totalEthSpent;
        result.parentSpent = totalParentSpent;
        result.derivativesBought = totalDerivativesAcquired;
        result.swapsExecuted = swapsExecuted;
        result.finalParentSqrtPrice = finalParentSqrtPrice;
        result.finalDerivativeSqrtPrice = finalDerivativeSqrtPrice;
        result.initialParentSqrtPrice = initialParentSqrtPrice;
        result.initialDerivativeSqrtPrice = initialDerivativeSqrtPrice;
    }

    // ---------------------------------------------------------------------
    // Reporting
    // ---------------------------------------------------------------------

    function _reportScenario(
        ScenarioConfig memory config,
        ScenarioResult memory result,
        bool parentIsCurrency0,
        bool derivativeIsCurrency0,
        address parentVault,
        address derivativeVault
    ) internal view {
        uint256 derivativeSupply = MinterRemyVault(derivativeVault).totalSupply();

        console.log("\n--- TRADING RESULTS ---");
        console.log("Total swaps executed:", result.swapsExecuted);
        console.log("Total ETH spent:", result.ethSpent / 1e18, ".", (result.ethSpent % 1e18) / 1e16);
        console.log("Total parent tokens spent:", result.parentSpent / 1e18, ".", (result.parentSpent % 1e18) / 1e16);
        console.log("Total derivatives acquired:", result.derivativesBought / 1e18, ".", (result.derivativesBought % 1e18) / 1e16);

        if (result.derivativesBought != 0) {
            uint256 avgParentPrice = FullMath.mulDiv(result.parentSpent, 1e18, result.derivativesBought);
            uint256 avgEthPrice = FullMath.mulDiv(result.ethSpent, 1e18, result.derivativesBought);
            console.log("Average paid (parent/derivative):", avgParentPrice / 1e18, ".", (avgParentPrice % 1e18) / 1e16);
            console.log("Average paid (ETH/derivative):", avgEthPrice / 1e18, ".", (avgEthPrice % 1e18) / 1e16);
        }

        uint256 percentMinted = result.derivativesBought == 0
            ? 0
            : FullMath.mulDiv(result.derivativesBought, 10000, derivativeSupply);
        console.log("Percent of supply acquired (bps):", percentMinted);

        console.log("\n--- FEE COLLECTION (MODELLED) ---");
        uint256 totalFees = FullMath.mulDiv(result.parentSpent, TOTAL_FEE_BPS, 10000);
        uint256 childFees = FullMath.mulDiv(totalFees, CHILD_FEE_BPS, TOTAL_FEE_BPS);
        uint256 parentFees = totalFees - childFees;
        console.log("Total fees (parent tokens):", totalFees / 1e18, ".", (totalFees % 1e18) / 1e16);
        console.log("  Child pool fees (7.5%):", childFees / 1e18, ".", (childFees % 1e18) / 1e16);
        console.log("  Parent pool fees (2.5%):", parentFees / 1e18, ".", (parentFees % 1e18) / 1e16);

        console.log("\n--- PRICE IMPACT ---");
        _logPriceImpact("Parent/ETH", result.initialParentSqrtPrice, result.finalParentSqrtPrice, false);
        _logPriceImpact("Derivative/Parent", result.initialDerivativeSqrtPrice, result.finalDerivativeSqrtPrice, derivativeIsCurrency0);

        console.log("\n--- FINAL BALANCES ---");
        console.log("Trader parent balance:", RemyVault(parentVault).balanceOf(trader) / 1e18);
        console.log("Trader derivative balance:", MinterRemyVault(derivativeVault).balanceOf(trader) / 1e18);
    }

    function _logPriceImpact(string memory label, uint160 initialSqrtPrice, uint160 finalSqrtPrice, bool derivativeIsCurrency0)
        internal
        pure
    {
        if (initialSqrtPrice == 0) {
            console.log("%s pool not initialized", label);
            return;
        }

        int256 changeBps = _bpsChange(initialSqrtPrice, finalSqrtPrice);
        uint256 initialPrice = _priceFromSqrt(initialSqrtPrice);
        uint256 finalPrice = _priceFromSqrt(finalSqrtPrice);

        if (derivativeIsCurrency0) {
            // interpret as parent per derivative when derivative is token0
            console.log("%s initial price (parent per derivative, 1e18):", initialPrice);
            console.log("%s final price (parent per derivative, 1e18):", finalPrice);
        } else {
            // convert to parent per derivative units (invert token1/token0 price)
            uint256 initialInverted = FullMath.mulDiv(1e36, 1, initialPrice);
            uint256 finalInverted = FullMath.mulDiv(1e36, 1, finalPrice);
            console.log("%s initial price (parent per derivative, 1e18):", initialInverted);
            console.log("%s final price (parent per derivative, 1e18):", finalInverted);
        }

        console.log("%s price change (bps):", changeBps);
    }

    // ---------------------------------------------------------------------
    // Parent Pool Setup
    // ---------------------------------------------------------------------

    function _setupParentPool() internal returns (ParentPoolState memory state) {
        address parentVault = vaultFactory.deployVault(address(parentCollection), "Parent Token", "PRNT");
        state.parentVault = parentVault;

        uint256 nftCount = 1500;
        uint256[] memory tokenIds = new uint256[](nftCount);
        for (uint256 i; i < nftCount; ++i) {
            parentCollection.mint(address(this), i + 1);
            tokenIds[i] = i + 1;
        }

        parentCollection.setApprovalForAll(parentVault, true);
        RemyVault(parentVault).deposit(tokenIds, address(this));

        RemyVault(parentVault).approve(address(factory), type(uint256).max);
        RemyVault(parentVault).approve(address(liquidityRouter), type(uint256).max);

        uint160 parentSqrtPrice = TickMath.getSqrtPriceAtTick(PARENT_INITIAL_TICK);
        PoolId rootPoolId = _initRootPool(parentVault, POOL_FEE, POOL_TICK_SPACING, parentSqrtPrice);
        state.rootPoolId = rootPoolId;

        (PoolKey memory rootKey,) = factory.rootPool(parentVault);
        state.rootKey = rootKey;
        state.initialSqrtPrice = parentSqrtPrice;

        uint160 sqrtLower = TickMath.getSqrtPriceAtTick(PARENT_TICK_LOWER);
        uint160 sqrtUpper = TickMath.getSqrtPriceAtTick(PARENT_TICK_UPPER);
        uint128 liquidity = LiquidityAmounts.getLiquidityForAmounts(
            parentSqrtPrice,
            sqrtLower,
            sqrtUpper,
            PARENT_ETH_LIQUIDITY,
            PARENT_TOKEN_LIQUIDITY
        );
        state.liquidity = liquidity;

        IPoolManager.ModifyLiquidityParams memory params = IPoolManager.ModifyLiquidityParams({
            tickLower: PARENT_TICK_LOWER,
            tickUpper: PARENT_TICK_UPPER,
            liquidityDelta: int256(uint256(liquidity)),
            salt: 0
        });

        BalanceDelta delta = liquidityRouter.modifyLiquidity{value: PARENT_ETH_LIQUIDITY}(rootKey, params, bytes(""));

        uint256 ethUsed = delta.amount0() < 0 ? uint256(int256(-delta.amount0())) : uint256(int256(delta.amount0()));
        uint256 parentUsed = delta.amount1() < 0 ? uint256(int256(-delta.amount1())) : uint256(int256(delta.amount1()));

        state.ethUsed = ethUsed;
        state.parentUsed = parentUsed;
    }

    // ---------------------------------------------------------------------
    // Helpers
    // ---------------------------------------------------------------------

    function _predictDerivativeOrientation(
        uint256 maxSupply,
        address parentVault,
        string memory nftName,
        string memory vaultName,
        string memory vaultSymbol
    ) internal view returns (bool derivativeIsCurrency0, address predictedVault) {
        // Mine salt to ensure derivative is always token1 (currency1)
        bytes32 salt = mineSaltForToken1(factory, parentVault, vaultName, vaultSymbol, maxSupply);
        (address predictedNft, address predictedVaultAddr) = predictDerivativeAddresses(factory, vaultName, vaultSymbol, maxSupply, salt);
        predictedVault = predictedVaultAddr;
        // Derivative is always token1 (not currency0) after salt mining
        derivativeIsCurrency0 = false;
    }

    function _scenarioTicks(ScenarioConfig memory config, bool derivativeIsCurrency0)
        internal
        pure
        returns (int24 initialTick, int24 tickLower, int24 tickUpper)
    {
        if (derivativeIsCurrency0) {
            return (config.baseInitialTick, config.baseTickLower, config.baseTickUpper);
        }
        return (-config.baseInitialTick, -config.baseTickUpper, -config.baseTickLower);
    }

    function _bpsChange(uint160 initialSqrt, uint160 finalSqrt) internal pure returns (int256) {
        if (initialSqrt == 0) return 0;
        if (finalSqrt >= initialSqrt) {
            return int256(uint256(finalSqrt) * 10000 / uint256(initialSqrt)) - 10000;
        }
        return -int256(uint256(initialSqrt) * 10000 / uint256(finalSqrt)) + 10000;
    }

    function _priceFromSqrt(uint160 sqrtPriceX96) internal pure returns (uint256 priceE18) {
        uint256 numerator = uint256(sqrtPriceX96) * uint256(sqrtPriceX96) * 1e18;
        priceE18 = numerator >> 192;
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
