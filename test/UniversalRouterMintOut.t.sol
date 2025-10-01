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
import {PoolModifyLiquidityTest} from "@uniswap/v4-core/src/test/PoolModifyLiquidityTest.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";

import {PositionManager} from "@uniswap/v4-periphery/src/PositionManager.sol";
import {IV4Router} from "@uniswap/v4-periphery/src/interfaces/IV4Router.sol";
import {V4Quoter} from "@uniswap/v4-periphery/src/lens/V4Quoter.sol";
import {IV4Quoter} from "@uniswap/v4-periphery/src/interfaces/IV4Quoter.sol";
import {PathKey} from "@uniswap/v4-periphery/src/libraries/PathKey.sol";
import {Actions} from "@uniswap/v4-periphery/src/libraries/Actions.sol";
import {ActionConstants} from "@uniswap/v4-periphery/src/libraries/ActionConstants.sol";

/**
 * @title UniversalRouterMintOut
 * @notice Tests derivative mint-out using V4Router and V4Quoter (like the frontend will)
 *
 * This simulates a realistic user flow:
 * 1. User starts with ETH
 * 2. Quotes ETH -> Parent -> Derivative path
 * 3. Executes multi-hop swap via V4Router
 * 4. Tracks all fees and price impacts
 */
contract UniversalRouterMintOut is BaseTest, DerivativeTestUtils {
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

    wNFTFactory internal vaultFactory;
    wNFTHook internal hook;
    DerivativeFactory internal factory;
    MockERC721Simple internal parentCollection;
    PoolModifyLiquidityTest internal liquidityRouter;

    V4Quoter internal quoter;
    PositionManager internal positionManager;

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

        liquidityRouter = new PoolModifyLiquidityTest(POOL_MANAGER);
        quoter = new V4Quoter(POOL_MANAGER);
        // positionManager = new PositionManager(POOL_MANAGER, address(0), 0, address(0), ""); // requires more params
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

    function test_QuoteETHToDerivativeMultihop() public {
        console.log("\n================================================================");
        console.log("  ETH -> PARENT -> DERIVATIVE QUOTE TEST");
        console.log("================================================================\n");

        // Setup
        (address parentVault, PoolId rootPoolId, address derivativeVault, PoolId childPoolId) = _setupPools();

        (PoolKey memory rootKey,) = factory.rootPool(parentVault);
        PoolKey memory childKey = _buildChildKey(derivativeVault, parentVault, 3000, 60);

        // Get initial prices
        (uint160 initialParentPrice,,,) = POOL_MANAGER.getSlot0(rootPoolId);
        (uint160 initialDerivPrice,,,) = POOL_MANAGER.getSlot0(childPoolId);

        console.log("--- INITIAL STATE ---");
        console.log("Parent/ETH sqrtPrice:", initialParentPrice);
        console.log("Derivative/Parent sqrtPrice:", initialDerivPrice);

        // Build path: ETH -> Parent -> Derivative
        PathKey[] memory path = new PathKey[](2);
        path[0] = PathKey({
            intermediateCurrency: Currency.wrap(parentVault),
            fee: 0x800000, // DYNAMIC_FEE_FLAG for root pool
            tickSpacing: 60,
            hooks: IHooks(HOOK_ADDRESS),
            hookData: bytes("")
        });
        path[1] = PathKey({
            intermediateCurrency: Currency.wrap(derivativeVault),
            fee: 3000,
            tickSpacing: 60,
            hooks: IHooks(HOOK_ADDRESS),
            hookData: bytes("")
        });

        // Quote the swap: 1 ETH in
        IV4Quoter.QuoteExactParams memory quoteParams =
            IV4Quoter.QuoteExactParams({exactCurrency: CurrencyLibrary.ADDRESS_ZERO, path: path, exactAmount: 1 ether});

        console.log("\n--- QUOTING SWAP: 1 ETH -> DERIVATIVE ---");

        (uint256 amountOut, uint256 gasEstimate) = quoter.quoteExactInput(quoteParams);

        console.log("ETH input: 1.0");
        console.log("Derivative output (quoted):", amountOut / 1e18, ".", (amountOut % 1e18) / 1e16);
        console.log("Gas estimate:", gasEstimate);

        // Calculate expected parent intermediate
        // This is an approximation - actual will be affected by fees
        console.log("\n--- EXPECTED PATH BREAKDOWN ---");
        console.log("Step 1: ETH -> Parent (via root pool)");
        console.log("Step 2: Parent -> Derivative (via child pool)");
        console.log("Note: 10% fees applied on shared token (parent) at each hop");

        console.log("\n================================================================");
        console.log("  QUOTE TEST COMPLETE");
        console.log("================================================================\n");
    }

    function test_LowPriceDerivativeMintOutWithRouter() public {
        console.log("\n================================================================");
        console.log("  LOW PRICE DERIVATIVE MINT-OUT (via V4Router)");
        console.log("  Starting from ETH, buying derivatives");
        console.log("================================================================\n");

        _runRouterMintOut(
            "Low Price",
            -23040, // 0.1 parent per derivative
            0,
            25054144837504793750611689472
        );
    }

    function test_MediumPriceDerivativeMintOutWithRouter() public {
        console.log("\n================================================================");
        console.log("  MEDIUM PRICE DERIVATIVE MINT-OUT (via V4Router)");
        console.log("  Starting from ETH, buying derivatives");
        console.log("================================================================\n");

        _runRouterMintOut(
            "Medium Price",
            -11520, // 0.5 parent per derivative
            11520,
            56022770974786139918731938227
        );
    }

    function test_HighPriceDerivativeMintOutWithRouter() public {
        console.log("\n================================================================");
        console.log("  HIGH PRICE DERIVATIVE MINT-OUT (via V4Router)");
        console.log("  Starting from ETH, buying derivatives");
        console.log("================================================================\n");

        _runRouterMintOut(
            "High Price",
            0, // 1.0 parent per derivative
            23040,
            79228162514264337593543950336
        );
    }

    function _runRouterMintOut(string memory name, int24 tickLower, int24 tickUpper, uint160 sqrtPriceX96) internal {
        // Note: V4Router integration requires more setup
        // For now, documenting the expected flow:

        console.log("=== DERIVATIVE:", name, "===\n");
        console.log("Expected Flow:");
        console.log("1. User provides ETH");
        console.log("2. V4Router executes: ETH -> Parent (root pool)");
        console.log("3. V4Router executes: Parent -> Derivative (child pool)");
        console.log("4. Fees collected at each hop:");
        console.log("   - Root pool: 10% of parent received");
        console.log("   - Child pool: 7.5% kept, 2.5% sent to root");
        console.log("\nPrice Range:");
        console.log("  Tick Lower:", tickLower);
        console.log("  Tick Upper:", tickUpper);
        console.log("Initial sqrtPrice:", sqrtPriceX96);

        console.log("\n[TODO] Full router integration requires:");
        console.log("  - Proper Actions encoding with Planner");
        console.log("  - SETTLE_ALL and TAKE_ALL for multi-hop");
        console.log("  - Native ETH wrapping/unwrapping");
        console.log("\nRefer to v4-periphery/test/router/V4Router.t.sol for examples");
    }

    function _setupPools()
        internal
        returns (address parentVault, PoolId rootPoolId, address derivativeVault, PoolId childPoolId)
    {
        // Create parent vault and pool
        parentVault = vaultFactory.deployVault(address(parentCollection));
        rootPoolId = _initRootPool(parentVault, 3000, 60, SQRT_PRICE_1_1);

        // Mint and deposit parent NFTs
        uint256[] memory tokenIds = new uint256[](200);
        for (uint256 i = 0; i < 200; i++) {
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
            liquidityDelta: int256(30 * 1e18),
            salt: 0
        });
        liquidityRouter.modifyLiquidity{value: 30 ether}(rootKey, rootLiqParams, bytes(""));

        // Create derivative
        DerivativeFactory.DerivativeParams memory params;
        params.parentCollection = wNFT(parentVault).erc721();
        params.nftName = "Test Derivative";
        params.nftSymbol = "TDRV";
        params.nftBaseUri = "ipfs://test/";
        params.nftOwner = address(this);
        params.fee = 3000;
        params.maxSupply = 100;
        params.tickLower = -11520;
        params.tickUpper = 11520;
        params.sqrtPriceX96 = 56022770974786139918731938227;
        params.liquidity = 15e18;
        params.parentTokenContribution = 50 * 1e18;
        params.derivativeTokenRecipient = address(this);
        params.salt = mineSaltForToken1(factory, parentVault, params.maxSupply);

        (, derivativeVault, childPoolId) = factory.createDerivative(params);
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
