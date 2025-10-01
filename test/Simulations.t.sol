// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {BaseTest} from "./BaseTest.t.sol";
import {DerivativeTestUtils} from "./DerivativeTestUtils.sol";
import {console} from "forge-std/console.sol";

import {wNFTFactory} from "../src/wNFTFactory.sol";
import {wNFT} from "../src/wNFT.sol";
import {wNFTMinter} from "../src/wNFTMinter.sol";
import {DerivativeFactory} from "../src/DerivativeFactory.sol";
import {wNFTHook} from "../src/wNFTHook.sol";
import {MockERC721Simple} from "./helpers/MockERC721Simple.sol";

import {Hooks} from "@uniswap/v4-core/src/libraries/Hooks.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {StateLibrary} from "@uniswap/v4-core/src/libraries/StateLibrary.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {IV4Quoter} from "@uniswap/v4-periphery/src/interfaces/IV4Quoter.sol";
import {PathKey} from "@uniswap/v4-periphery/src/libraries/PathKey.sol";
import {PoolModifyLiquidityTest} from "@uniswap/v4-core/src/test/PoolModifyLiquidityTest.sol";
import {PoolSwapTest} from "@uniswap/v4-core/src/test/PoolSwapTest.sol";
import {LiquidityAmounts} from "@uniswap/v4-core/test/utils/LiquidityAmounts.sol";
import {IERC721Receiver} from "@openzeppelin/contracts/token/ERC721/IERC721Receiver.sol";

contract Simulations is BaseTest, DerivativeTestUtils, IERC721Receiver {
    using PoolIdLibrary for PoolKey;
    using StateLibrary for IPoolManager;

    receive() external payable {}

    function onERC721Received(address, address, uint256, bytes calldata) external pure override returns (bytes4) {
        return IERC721Receiver.onERC721Received.selector;
    }

    uint160 internal constant SQRT_PRICE_1_1 = 79228162514264337593543950336;
    uint160 internal constant CLEAR_HOOK_PERMISSIONS_MASK = ~uint160(0) << 14;
    uint160 internal constant HOOK_FLAGS = Hooks.BEFORE_SWAP_FLAG | Hooks.AFTER_SWAP_FLAG
        | Hooks.BEFORE_SWAP_RETURNS_DELTA_FLAG | Hooks.AFTER_SWAP_RETURNS_DELTA_FLAG;
    uint160 internal constant HOOK_ADDRESS_SEED = uint160(0x4444000000000000000000000000000000000000);
    address internal constant HOOK_ADDRESS =
        address(uint160((HOOK_ADDRESS_SEED & CLEAR_HOOK_PERMISSIONS_MASK) | HOOK_FLAGS));
    address internal constant POOL_MANAGER_ADDRESS = 0x498581fF718922c3f8e6A244956aF099B2652b2b;
    IPoolManager internal constant POOL_MANAGER = IPoolManager(POOL_MANAGER_ADDRESS);
    address internal constant QUOTER_ADDRESS = 0x0d5e0F971ED27FBfF6c2837bf31316121532048D;
    IV4Quoter internal constant QUOTER = IV4Quoter(QUOTER_ADDRESS);

    wNFTFactory internal vaultFactory;
    wNFTHook internal hook;
    DerivativeFactory internal factory;
    PoolModifyLiquidityTest internal liquidityHelper;
    PoolSwapTest internal swapRouter;

    // Parent pool state (initialized in _setUpParentPool)
    MockERC721Simple internal parentCollection;
    address internal parentVault;
    PoolKey internal rootKey;
    PoolId internal rootPoolId;

    function setUp() public override {
        super.setUp();

        vaultFactory = new wNFTFactory();

        vm.etch(HOOK_ADDRESS, hex"");
        deployCodeTo("wNFTHook.sol:wNFTHook", abi.encode(POOL_MANAGER, address(this)), HOOK_ADDRESS);
        hook = wNFTHook(HOOK_ADDRESS);

        factory = new DerivativeFactory(vaultFactory, hook, address(this));
        hook.transferOwnership(address(factory));

        liquidityHelper = new PoolModifyLiquidityTest(POOL_MANAGER);
        swapRouter = new PoolSwapTest(POOL_MANAGER);

        // Initialize parent pool with standard parameters
        _setUpParentPool();
    }

    function _setUpParentPool() internal {
        // Create parent collection and vault
        parentCollection = new MockERC721Simple("Parent NFT", "PRNT");

        // Mint 700 parent NFTs to this contract (need 600 for liquidity + some for derivative)
        for (uint256 i = 1; i <= 700; i++) {
            parentCollection.mint(address(this), i);
        }

        // Create parent vault
        parentVault = vaultFactory.deployVault(address(parentCollection));

        // Deposit NFTs into parent vault
        uint256[] memory tokenIds = new uint256[](700);
        for (uint256 i = 0; i < 700; i++) {
            tokenIds[i] = i + 1;
        }
        parentCollection.setApprovalForAll(parentVault, true);
        wNFT(parentVault).deposit(tokenIds, address(this));

        // Create root pool with price ≈ 0.01 ETH per parent token
        // Initialize at exactly tick 46020 to enable single-sided liquidity
        // tick 46020 => price = 1.0001^46020 ≈ 99.405 parent/ETH ≈ 0.01006 ETH/parent
        uint160 sqrtPriceTick46020 = TickMath.getSqrtPriceAtTick(46020);
        rootPoolId = _initRootPool(parentVault, 3000, 60, sqrtPriceTick46020);
        rootKey = _buildPoolKey(address(0), parentVault, 0x800000, 60);

        // Verify initialization
        (uint160 actualSqrtPrice, int24 actualTick,,) = POOL_MANAGER.getSlot0(rootPoolId);
        console.log("Initialized pool - tick:", actualTick);
        console.log("Expected tick: 46020");

        // Add liquidity to root pool (current tick = 46020 exactly)
        // Ranges bracket the current tick with minimal gap

        // Range 1: Parent tokens for selling as price rises (0.01006 → 0.1 ETH per parent)
        // From tick 23040 (0.1 ETH/parent) to 46020 (current tick)
        // Current tick = upper bound, so range just became inactive, 100% token1 (parent)
        _addLiquidityToPool(rootKey, 23040, 46020, 600e18, 0, address(this));

        // Range 2: ETH for buying parent as price falls (0.01006 → 0.001 ETH per parent)
        // From tick 46020 (current tick) to 69060 (0.001 ETH/parent)
        // Current tick = lower bound, so range is active, provides liquidity
        vm.deal(address(this), 20 ether);
        _addLiquidityToPool(rootKey, 46020, 69060, 0, 4 ether, address(this));
    }

    function test_CreateOGNFTAndVault() public {
        // Create userA
        address userA = makeAddr("userA");

        // Create OG NFT collection (created by and minted to userA)
        vm.startPrank(userA);
        MockERC721Simple ogNFT = new MockERC721Simple("Original NFT", "OG NFT");

        // Mint 1000 NFTs to userA (token IDs 0-999)
        for (uint256 i = 0; i < 1000; i++) {
            ogNFT.mint(userA, i);
        }
        vm.stopPrank();

        // Deal userA with 10 ETH
        vm.deal(userA, 10 ether);

        // Create wNFT for the OG NFT collection
        vm.prank(userA);
        address vaultAddress = vaultFactory.deployVault(address(ogNFT));
        wNFT vault = wNFT(vaultAddress);

        // Verify the vault was created correctly
        assertEq(vault.erc721(), address(ogNFT));
        assertEq(userA.balance, 10 ether);
        assertEq(ogNFT.balanceOf(userA), 1000);
    }

    function test_DerivativeCreation_EntireSupplyAsLiquidity() public {
        // Approve parent vault tokens for derivative creation
        wNFT(parentVault).approve(address(factory), type(uint256).max);

        // Setup derivative parameters
        uint256 maxSupply = 50;
        DerivativeFactory.DerivativeParams memory params;
        params.parentCollection = address(parentCollection);
        params.nftName = "Test Derivative";
        params.nftSymbol = "TDRV";
        params.nftBaseUri = "ipfs://test/";
        params.nftOwner = address(this);
        params.initialMinter = address(0);
        params.fee = 0x800000; // LPFeeLibrary.DYNAMIC_FEE_FLAG - only 10% hook fee
        params.maxSupply = maxSupply;
        params.tickLower = -12000;
        params.tickUpper = -7200;
        params.sqrtPriceX96 = 56022770974786139918731938227;
        params.liquidity = 15e18;
        params.parentTokenContribution = 0;
        params.derivativeTokenRecipient = address(this);
        params.parentTokenRefundRecipient = address(this);
        params.salt = mineSaltForToken1(factory, parentVault, params.maxSupply);

        // Create derivative
        (address nft, address derivativeVault, PoolId childPoolId) = factory.createDerivative(params);

        // Multi-hop quote: ETH -> parent -> derivative
        PoolKey memory childKey = _buildPoolKey(derivativeVault, parentVault, params.fee, factory.TICK_SPACING());

        // Build the path: ETH -> parent -> derivative
        IV4Quoter.QuoteExactParams memory quoteParams;
        quoteParams.exactCurrency = Currency.wrap(address(0)); // ETH
        quoteParams.exactAmount = uint128(0.1 ether);

        // Path has two hops: ETH->parent, then parent->derivative
        quoteParams.path = new PathKey[](2);

        // First hop: ETH -> parent (root pool)
        quoteParams.path[0] = PathKey({
            intermediateCurrency: Currency.wrap(parentVault),
            fee: 0x800000, // Dynamic fee flag for root pool
            tickSpacing: 60,
            hooks: IHooks(HOOK_ADDRESS),
            hookData: ""
        });

        // Second hop: parent -> derivative (child pool)
        quoteParams.path[1] = PathKey({
            intermediateCurrency: Currency.wrap(derivativeVault),
            fee: params.fee,
            tickSpacing: factory.TICK_SPACING(),
            hooks: IHooks(HOOK_ADDRESS),
            hookData: ""
        });

        console.log("=== MULTI-HOP SWAP QUOTE (ETH -> parent -> derivative) ===");
        try QUOTER.quoteExactInput(quoteParams) returns (uint256 derivativeTokensOut, uint256 gasEstimate) {
            console.log("0.1 ETH -> derivative tokens:", derivativeTokensOut);
            console.log("Total gas estimate:", gasEstimate);
        } catch {
            console.log("Multi-hop quote failed (may be restricted by hook)");
        }

        // Verify factory has no leftover tokens
        assertEq(
            wNFTMinter(derivativeVault).balanceOf(address(factory)), 0, "Factory should have 0 derivative tokens"
        );
        assertEq(wNFT(parentVault).balanceOf(address(factory)), 0, "Factory should have 0 parent tokens");
    }

    function _initRootPool(address vault, uint24, /* fee */ int24 tickSpacing, uint160 sqrtPriceX96)
        internal
        returns (PoolId poolId)
    {
        uint24 fee = 0x800000; // LPFeeLibrary.DYNAMIC_FEE_FLAG
        PoolKey memory key = _buildPoolKey(address(0), vault, fee, tickSpacing);
        PoolKey memory emptyKey;
        vm.prank(address(factory));
        hook.addChild(key, false, emptyKey);
        POOL_MANAGER.initialize(key, sqrtPriceX96);
        return key.toId();
    }

    function _buildPoolKey(address tokenA, address tokenB, uint24 fee, int24 tickSpacing)
        internal
        pure
        returns (PoolKey memory key)
    {
        Currency currencyA = Currency.wrap(tokenA);
        Currency currencyB = Currency.wrap(tokenB);
        if (Currency.unwrap(currencyA) < Currency.unwrap(currencyB)) {
            key = PoolKey({
                currency0: currencyA,
                currency1: currencyB,
                fee: fee,
                tickSpacing: tickSpacing,
                hooks: IHooks(HOOK_ADDRESS)
            });
        } else {
            key = PoolKey({
                currency0: currencyB,
                currency1: currencyA,
                fee: fee,
                tickSpacing: tickSpacing,
                hooks: IHooks(HOOK_ADDRESS)
            });
        }
    }

    function test_DerivativeCreation_1kSupply_PointOneToOnePrice() public {
        // Approve parent vault tokens for derivative creation
        wNFT(parentVault).approve(address(factory), type(uint256).max);

        // Setup derivative parameters for 500 token supply
        uint256 maxSupply = 500;
        DerivativeFactory.DerivativeParams memory params;
        params.parentCollection = address(parentCollection);
        params.nftName = "500 Derivative";
        params.nftSymbol = "500DRV";
        params.nftBaseUri = "ipfs://500/";
        params.nftOwner = address(this);
        params.initialMinter = address(0);
        params.fee = 0x800000; // LPFeeLibrary.DYNAMIC_FEE_FLAG - only 10% hook fee
        params.maxSupply = maxSupply;

        // Price range: 0.1 to 1 parent per derivative
        // In pool terms (derivative/parent): price = 1 to 10
        // tick 0 = price 1 (1 parent per derivative)
        // tick 23040 ≈ price 10 (0.1 parent per derivative)
        // Note: Uniswap positions are [tickLower, tickUpper) - half-open interval
        params.tickLower = 0;
        params.tickUpper = 23040;

        // Initialize at tick 23040 (at upper boundary) for single-sided derivative liquidity
        // When sqrtPrice >= sqrtPrice(tickUpper), position is 100% token1 (derivative)
        params.sqrtPriceX96 = TickMath.getSqrtPriceAtTick(23040);

        // Liquidity will be calculated by factory to consume all 500 derivative tokens
        params.liquidity = 1; // Factory ignores this, just needs to be non-zero

        params.parentTokenContribution = 0;
        params.derivativeTokenRecipient = address(this);
        params.parentTokenRefundRecipient = address(this);
        params.salt = mineSaltForToken1(factory, parentVault, params.maxSupply);

        console.log("=== CREATING DERIVATIVE ==");
        (address nft, address derivativeVault, PoolId childPoolId) = factory.createDerivative(params);

        // Build child pool key
        PoolKey memory childKey = _buildPoolKey(derivativeVault, parentVault, params.fee, factory.TICK_SPACING());
        bool parentIsZero = Currency.unwrap(childKey.currency0) == parentVault;

        // Verify pool state
        (uint160 actualSqrtPrice, int24 actualTick,,) = POOL_MANAGER.getSlot0(childPoolId);
        console.log("Child pool initialized at tick:", actualTick);
        console.log("Expected tick: 23040");
        assertEq(actualTick, 23040, "Pool should initialize at tick 23040");

        // Prime the pool with a tiny swap to enable quotes
        console.log("=== PRIMING POOL WITH SWAP ==");
        wNFT(parentVault).approve(address(swapRouter), 1e18);
        IPoolManager.SwapParams memory swapParams = IPoolManager.SwapParams({
            zeroForOne: parentIsZero,
            amountSpecified: -1, // Sell 1 wei of parent token
            sqrtPriceLimitX96: parentIsZero ? TickMath.MIN_SQRT_PRICE + 1 : TickMath.MAX_SQRT_PRICE - 1
        });
        swapRouter.swap(
            childKey, swapParams, PoolSwapTest.TestSettings({takeClaims: false, settleUsingBurn: false}), ""
        );
        console.log("Pool primed successfully");

        // Try to quote swaps (may fail due to hook restrictions)
        console.log("=== SWAP QUOTES ==");
        try QUOTER.quoteExactInputSingle(
            IV4Quoter.QuoteExactSingleParams({
                poolKey: childKey,
                zeroForOne: parentIsZero,
                exactAmount: 1e18,
                hookData: ""
            })
        ) returns (uint256 derivativeTokensOut, uint256 gasEstimate) {
            console.log("1 parent token -> derivative tokens:", derivativeTokensOut);
            console.log("Gas estimate:", gasEstimate);

            // At starting price ~10 (0.1 parent per derivative), expect ~9 derivative tokens
            // (10 tokens - 10% hook fee = 9 tokens, adjusted for price impact)
            assertGt(derivativeTokensOut, 8e18, "Should get at least 8 derivative tokens");
            assertLt(derivativeTokensOut, 10e18, "Should get at most 10 derivative tokens");

            // Quote: 0.1 parent token -> derivative tokens
            try QUOTER.quoteExactInputSingle(
                IV4Quoter.QuoteExactSingleParams({
                    poolKey: childKey,
                    zeroForOne: parentIsZero,
                    exactAmount: 0.1e18,
                    hookData: ""
                })
            ) returns (uint256 smallSwapOut, uint256) {
                console.log("0.1 parent token -> derivative tokens:", smallSwapOut);
            } catch {
                console.log("Small swap quote failed");
            }
        } catch {
            console.log("Swap quotes failed (likely restricted by hook before liquidity is added)");
        }

        // Multi-hop quote: ETH -> parent -> derivative
        console.log("=== MULTI-HOP SWAP QUOTE (ETH -> parent -> derivative) ===");
        IV4Quoter.QuoteExactParams memory quoteParams;
        quoteParams.exactCurrency = Currency.wrap(address(0)); // ETH
        quoteParams.exactAmount = uint128(0.1 ether);

        // Path has two hops: ETH->parent, then parent->derivative
        quoteParams.path = new PathKey[](2);

        // First hop: ETH -> parent (root pool)
        quoteParams.path[0] = PathKey({
            intermediateCurrency: Currency.wrap(parentVault),
            fee: 0x800000, // Dynamic fee flag for root pool
            tickSpacing: 60,
            hooks: IHooks(HOOK_ADDRESS),
            hookData: ""
        });

        // Second hop: parent -> derivative (child pool)
        quoteParams.path[1] = PathKey({
            intermediateCurrency: Currency.wrap(derivativeVault),
            fee: params.fee,
            tickSpacing: factory.TICK_SPACING(),
            hooks: IHooks(HOOK_ADDRESS),
            hookData: ""
        });

        try QUOTER.quoteExactInput(quoteParams) returns (uint256 derivativeTokensOut, uint256 gasEstimate) {
            console.log("0.1 ETH -> derivative tokens:", derivativeTokensOut);
            console.log("Total gas estimate:", gasEstimate);
        } catch {
            console.log("Multi-hop quote failed (may be restricted by hook)");
        }

        // Verify factory has no leftover tokens
        assertEq(
            wNFTMinter(derivativeVault).balanceOf(address(factory)), 0, "Factory should have 0 derivative tokens"
        );
        assertEq(wNFT(parentVault).balanceOf(address(factory)), 0, "Factory should have 0 parent tokens");
    }

    function _addLiquidityToPool(
        PoolKey memory key,
        int24 tickLower,
        int24 tickUpper,
        uint256 amount1Desired,
        uint256 amount0Desired,
        address recipient
    ) internal {
        // Get current sqrt price
        (uint160 sqrtPriceX96,,,) = POOL_MANAGER.getSlot0(key.toId());

        // Calculate sqrt prices at tick boundaries
        uint160 sqrtPriceAX96 = TickMath.getSqrtPriceAtTick(tickLower);
        uint160 sqrtPriceBX96 = TickMath.getSqrtPriceAtTick(tickUpper);

        // Calculate liquidity from token amounts
        uint128 liquidity = LiquidityAmounts.getLiquidityForAmounts(
            sqrtPriceX96, sqrtPriceAX96, sqrtPriceBX96, amount0Desired, amount1Desired
        );

        // Approve tokens if needed
        if (amount0Desired > 0 && Currency.unwrap(key.currency0) != address(0)) {
            // ERC20 token
            wNFT(Currency.unwrap(key.currency0)).approve(address(liquidityHelper), amount0Desired);
        }
        if (amount1Desired > 0) {
            wNFT(Currency.unwrap(key.currency1)).approve(address(liquidityHelper), amount1Desired);
        }

        // Add liquidity
        IPoolManager.ModifyLiquidityParams memory params = IPoolManager.ModifyLiquidityParams({
            tickLower: tickLower,
            tickUpper: tickUpper,
            liquidityDelta: int256(uint256(liquidity)),
            salt: bytes32(0)
        });

        liquidityHelper.modifyLiquidity{value: amount0Desired}(key, params, "");
    }

    function test_MintOut_LOW_PRICE_Derivative() public {
        console.log("=======================================================");
        console.log("=== LOW PRICE DERIVATIVE: 0.3 to 1.5 parent/deriv ===");
        console.log("=======================================================");

        // Approve parent vault tokens for derivative creation
        wNFT(parentVault).approve(address(factory), type(uint256).max);

        // Setup derivative parameters for 500 token supply
        uint256 maxSupply = 500;
        DerivativeFactory.DerivativeParams memory params;
        params.parentCollection = address(parentCollection);
        params.nftName = "LOW Price Derivative";
        params.nftSymbol = "LOWDRV";
        params.nftBaseUri = "ipfs://low/";
        params.nftOwner = address(this);
        params.initialMinter = address(0);
        params.fee = 0x800000; // LPFeeLibrary.DYNAMIC_FEE_FLAG - only 10% hook fee
        params.maxSupply = maxSupply;

        // Price range: 0.3 to 1.5 parent per derivative (5x range)
        // In pool terms (derivative/parent): price = 0.667 to 3.333
        params.tickLower = -4080; // tick -4080 ≈ 1.5 parent per derivative
        params.tickUpper = 12060; // tick 12060 ≈ 0.3 parent per derivative

        // Initialize at tick 12060 (at upper boundary) for single-sided derivative liquidity
        params.sqrtPriceX96 = TickMath.getSqrtPriceAtTick(12060);

        params.liquidity = 1; // Factory calculates this
        params.parentTokenContribution = 0;
        params.derivativeTokenRecipient = address(this);
        params.parentTokenRefundRecipient = address(this);
        params.salt = mineSaltForToken1(factory, parentVault, params.maxSupply);

        console.log("\n=== CREATING DERIVATIVE ===");
        (address nft, address derivativeVault, PoolId childPoolId) = factory.createDerivative(params);

        PoolKey memory childKey = _buildPoolKey(derivativeVault, parentVault, params.fee, factory.TICK_SPACING());
        bool parentIsZero = Currency.unwrap(childKey.currency0) == parentVault;

        (uint160 initialSqrtPrice, int24 initialTick,,) = POOL_MANAGER.getSlot0(childPoolId);
        console.log("Initial pool tick:", initialTick);
        console.log("Target starting price: 0.3 parent per derivative");

        // Record initial balances and parent pool state
        uint256 initialDerivativeInPool = wNFTMinter(derivativeVault).balanceOf(address(POOL_MANAGER));
        console.log("Derivative tokens in pool:", initialDerivativeInPool);

        // Track parent pool state before minting
        (uint160 parentPoolSqrtPriceBefore, int24 parentPoolTickBefore,,) = POOL_MANAGER.getSlot0(rootPoolId);
        console.log("\n=== PARENT POOL STATE BEFORE DERIVATIVE MINT ===");
        console.log("Parent pool tick:", parentPoolTickBefore);

        // PROGRESSIVE BUY QUOTES: Fixed ETH amounts using exact input
        console.log("\n=== PROGRESSIVE BUY QUOTES (Fixed ETH Amounts) ===");

        // Prime both pools with tiny swaps to activate liquidity
        console.log("Priming pools for quoter...");

        // Prime root pool (ETH -> parent)
        vm.deal(address(this), address(this).balance + 1 ether);
        IPoolManager.SwapParams memory primeRootSwap = IPoolManager.SwapParams({
            zeroForOne: true,
            amountSpecified: -1, // Sell 1 wei of ETH
            sqrtPriceLimitX96: TickMath.MIN_SQRT_PRICE + 1
        });
        swapRouter.swap{value: 1}(
            rootKey, primeRootSwap, PoolSwapTest.TestSettings({takeClaims: false, settleUsingBurn: false}), ""
        );

        // Prime child pool (parent -> derivative)
        wNFT(parentVault).approve(address(swapRouter), type(uint256).max);
        IPoolManager.SwapParams memory primeChildSwap = IPoolManager.SwapParams({
            zeroForOne: parentIsZero,
            amountSpecified: -1, // Sell 1 wei of parent
            sqrtPriceLimitX96: parentIsZero ? TickMath.MIN_SQRT_PRICE + 1 : TickMath.MAX_SQRT_PRICE - 1
        });
        swapRouter.swap(
            childKey, primeChildSwap, PoolSwapTest.TestSettings({takeClaims: false, settleUsingBurn: false}), ""
        );
        console.log("Pools primed successfully");

        // Test with progressively larger ETH amounts
        uint256[] memory ethAmounts = new uint256[](20);
        ethAmounts[0] = 0.01 ether;
        ethAmounts[1] = 0.05 ether;
        ethAmounts[2] = 0.1 ether;
        ethAmounts[3] = 0.25 ether;
        ethAmounts[4] = 0.5 ether;
        ethAmounts[5] = 1 ether;
        ethAmounts[6] = 2 ether;
        ethAmounts[7] = 3 ether;
        ethAmounts[8] = 4 ether;
        ethAmounts[9] = 5 ether;
        ethAmounts[10] = 6 ether;
        ethAmounts[11] = 7 ether;
        ethAmounts[12] = 8 ether;
        ethAmounts[13] = 9 ether;
        ethAmounts[14] = 10 ether;
        ethAmounts[15] = 11 ether;
        ethAmounts[16] = 12 ether;
        ethAmounts[17] = 13 ether;
        ethAmounts[18] = 14 ether;
        ethAmounts[19] = 15 ether;

        for (uint256 i = 0; i < ethAmounts.length; i++) {
            uint256 ethAmount = ethAmounts[i];

            // Multi-hop exact input: ETH -> parent -> derivative
            IV4Quoter.QuoteExactParams memory quoteParams;
            quoteParams.exactCurrency = Currency.wrap(address(0)); // Start with ETH
            quoteParams.exactAmount = uint128(ethAmount);

            quoteParams.path = new PathKey[](2);
            quoteParams.path[0] = PathKey({
                intermediateCurrency: Currency.wrap(parentVault),
                fee: 0x800000,
                tickSpacing: 60,
                hooks: IHooks(HOOK_ADDRESS),
                hookData: ""
            });
            quoteParams.path[1] = PathKey({
                intermediateCurrency: Currency.wrap(derivativeVault),
                fee: params.fee,
                tickSpacing: factory.TICK_SPACING(),
                hooks: IHooks(HOOK_ADDRESS),
                hookData: ""
            });

            try QUOTER.quoteExactInput(quoteParams) returns (uint256 derivTokensOut, uint256) {
                uint256 nftsOut = derivTokensOut / 1e18;
                console.log("---");
                console.log("ETH input:", ethAmount);
                console.log("  Derivative tokens out:", derivTokensOut);
                console.log("  NFTs out:", nftsOut);
                console.log("  ETH per NFT:", nftsOut > 0 ? ethAmount / nftsOut : 0);
                console.log("  Supply %:", (nftsOut * 100) / maxSupply);
            } catch {
                // Quote failed (likely no liquidity left), stop
                break;
            }
        }
        console.log("---");

        // STEP 1: Buy parent tokens with ETH
        console.log("\n=== STEP 1: BUY PARENT TOKENS WITH ETH ===");
        uint256 ethToSpend = 9 ether; // Testing with 9 ETH for 5x range (0.3-1.5)
        vm.deal(address(this), address(this).balance + ethToSpend); // Ensure we have enough ETH
        uint256 parentBalanceBeforeEthSwap = wNFT(parentVault).balanceOf(address(this));
        console.log("ETH to spend:", ethToSpend);

        IPoolManager.SwapParams memory ethSwapParams = IPoolManager.SwapParams({
            zeroForOne: true, // ETH -> parent
            amountSpecified: -int256(ethToSpend),
            sqrtPriceLimitX96: TickMath.MIN_SQRT_PRICE + 1
        });

        swapRouter.swap{value: ethToSpend}(
            rootKey, ethSwapParams, PoolSwapTest.TestSettings({takeClaims: false, settleUsingBurn: false}), ""
        );

        uint256 parentTokensAcquired = wNFT(parentVault).balanceOf(address(this)) - parentBalanceBeforeEthSwap;
        console.log("Parent tokens acquired:", parentTokensAcquired);
        console.log("ETH spent:", ethToSpend);
        console.log("Parent tokens per ETH:", parentTokensAcquired / 1e18);

        // STEP 2: Buy derivative tokens with parent tokens
        console.log("\n=== STEP 2: BUY DERIVATIVE TOKENS WITH PARENT ===");
        wNFT(parentVault).approve(address(swapRouter), type(uint256).max);

        // Prime the pool with a tiny swap first to enable proper execution
        console.log("Priming pool with tiny swap...");
        IPoolManager.SwapParams memory primeSwap = IPoolManager.SwapParams({
            zeroForOne: parentIsZero,
            amountSpecified: -1, // Sell 1 wei of parent token
            sqrtPriceLimitX96: parentIsZero ? TickMath.MIN_SQRT_PRICE + 1 : TickMath.MAX_SQRT_PRICE - 1
        });
        swapRouter.swap(childKey, primeSwap, PoolSwapTest.TestSettings({takeClaims: false, settleUsingBurn: false}), "");
        console.log("Pool primed successfully");

        uint256 parentBalanceBeforeDerivSwap = wNFT(parentVault).balanceOf(address(this));
        uint256 parentToSpend = parentTokensAcquired - 1; // Use acquired tokens minus the 1 wei for priming

        console.log("Parent tokens to spend:", parentToSpend);

        IPoolManager.SwapParams memory derivSwapParams = IPoolManager.SwapParams({
            zeroForOne: parentIsZero,
            amountSpecified: -int256(parentToSpend),
            sqrtPriceLimitX96: parentIsZero ? TickMath.MIN_SQRT_PRICE + 1 : TickMath.MAX_SQRT_PRICE - 1
        });

        swapRouter.swap(
            childKey, derivSwapParams, PoolSwapTest.TestSettings({takeClaims: false, settleUsingBurn: false}), ""
        );

        uint256 derivativeBalance = wNFTMinter(derivativeVault).balanceOf(address(this));
        uint256 parentSpent = parentBalanceBeforeDerivSwap - wNFT(parentVault).balanceOf(address(this));

        console.log("Derivative tokens acquired:", derivativeBalance);
        console.log("Parent tokens actually spent:", parentSpent);
        console.log("Derivative per parent:", derivativeBalance / (parentSpent / 1e18));

        // Check pool state after swap
        (uint160 finalSqrtPrice, int24 finalTick,,) = POOL_MANAGER.getSlot0(childPoolId);
        console.log("Final pool tick:", finalTick);
        console.log("Tick movement:", int256(finalTick) - int256(initialTick));
        console.log(
            "Derivative tokens remaining in pool:", wNFTMinter(derivativeVault).balanceOf(address(POOL_MANAGER))
        );

        // STEP 3: Mint NFTs from derivative tokens
        console.log("\n=== STEP 3: MINT NFTs FROM DERIVATIVE TOKENS ===");
        uint256 nftsToMint = derivativeBalance / 1e18;
        console.log("NFTs we can mint:", nftsToMint);

        uint256[] memory mintedTokenIds = wNFTMinter(derivativeVault).mint(nftsToMint, address(this));

        console.log("NFTs successfully minted:", MockERC721Simple(nft).balanceOf(address(this)));
        console.log("First NFT ID minted:", mintedTokenIds[0]);
        console.log("Last NFT ID minted:", mintedTokenIds[mintedTokenIds.length - 1]);

        // STEP 4: Analyze Parent Pool Price Impact
        console.log("\n=== PARENT POOL PRICE IMPACT ANALYSIS ===");
        (uint160 parentPoolSqrtPriceAfter, int24 parentPoolTickAfter,,) = POOL_MANAGER.getSlot0(rootPoolId);
        console.log("Parent pool tick after mint:", parentPoolTickAfter);
        console.log("Parent pool tick movement:", int256(parentPoolTickAfter) - int256(parentPoolTickBefore));

        // Get actual quotes by doing small test swaps and reverting
        console.log("\n=== PARENT TOKEN SELL QUOTES (Parent -> ETH) ===");
        uint256[] memory sellAmounts = new uint256[](5);
        sellAmounts[0] = 1e18; // 1 parent token
        sellAmounts[1] = 5e18; // 5 parent tokens
        sellAmounts[2] = 10e18; // 10 parent tokens
        sellAmounts[3] = 25e18; // 25 parent tokens
        sellAmounts[4] = 50e18; // 50 parent tokens

        for (uint256 i = 0; i < sellAmounts.length; i++) {
            uint256 sellAmount = sellAmounts[i];
            console.log("---");
            console.log("Quote for selling", sellAmount / 1e18, "parent tokens:");

            // Snapshot state
            uint256 snapshotId = vm.snapshot();

            // Do the swap to see output
            uint256 ethBefore = address(this).balance;
            IPoolManager.SwapParams memory sellParams = IPoolManager.SwapParams({
                zeroForOne: false, // parent -> ETH
                amountSpecified: -int256(sellAmount),
                sqrtPriceLimitX96: TickMath.MAX_SQRT_PRICE - 1
            });

            swapRouter.swap(
                rootKey, sellParams, PoolSwapTest.TestSettings({takeClaims: false, settleUsingBurn: false}), ""
            );
            uint256 ethReceived = address(this).balance - ethBefore;

            console.log("  Parent tokens sold:", sellAmount);
            console.log("  ETH received:", ethReceived);
            console.log("  Price (ETH per parent):", ethReceived * 1e18 / sellAmount);

            // Revert to snapshot
            vm.revertTo(snapshotId);
        }

        // SUMMARY
        console.log("\n=== SUMMARY ===");
        console.log("Total ETH spent:", ethToSpend);
        console.log("Total parent tokens spent:", parentSpent);
        console.log("Total derivative tokens acquired:", derivativeBalance);
        console.log("Total NFTs minted:", nftsToMint);
        console.log("ETH per NFT:", ethToSpend / nftsToMint);
        console.log("Parent per NFT:", parentSpent / nftsToMint);
        console.log("Collection mint progress:", (nftsToMint * 100) / maxSupply, "%");
        int256 parentPoolTickImpact = int256(parentPoolTickAfter) - int256(parentPoolTickBefore);
        console.log("Parent pool price impact (ticks):", parentPoolTickImpact);

        // Verify we acquired tokens
        assertGt(derivativeBalance, 0, "Should have acquired derivative tokens");
        assertGt(nftsToMint, 0, "Should be able to mint NFTs");
    }

    function test_MintOut_MEDIUM_PRICE_Derivative() public {
        console.log("=========================================================");
        console.log("=== MEDIUM PRICE DERIVATIVE: 0.5 to 2.0 parent/deriv ===");
        console.log("=========================================================");

        // Approve parent vault tokens for derivative creation
        wNFT(parentVault).approve(address(factory), type(uint256).max);

        // Setup derivative parameters for 250 token supply
        uint256 maxSupply = 250;
        DerivativeFactory.DerivativeParams memory params;
        params.parentCollection = address(parentCollection);
        params.nftName = "MEDIUM Price Derivative";
        params.nftSymbol = "MEDDRV";
        params.nftBaseUri = "ipfs://medium/";
        params.nftOwner = address(this);
        params.initialMinter = address(0);
        params.fee = 0x800000; // LPFeeLibrary.DYNAMIC_FEE_FLAG - only 10% hook fee
        params.maxSupply = maxSupply;

        // Price range: 0.5 to 2.0 parent per derivative
        // In pool terms (derivative/parent): price = 0.5 to 2
        // tick -6932 ≈ price 0.5 (2.0 parent per derivative)
        // tick 6931 ≈ price 2 (0.5 parent per derivative)
        params.tickLower = -6960; // Adjusted to nearest valid tick for spacing 60
        params.tickUpper = 6960; // Adjusted to nearest valid tick for spacing 60

        // Initialize at tick 6960 (at upper boundary) for single-sided derivative liquidity
        params.sqrtPriceX96 = TickMath.getSqrtPriceAtTick(6960);

        params.liquidity = 1; // Factory calculates this
        params.parentTokenContribution = 0;
        params.derivativeTokenRecipient = address(this);
        params.parentTokenRefundRecipient = address(this);
        params.salt = mineSaltForToken1(factory, parentVault, params.maxSupply);

        console.log("\n=== CREATING DERIVATIVE ===");
        (address nft, address derivativeVault, PoolId childPoolId) = factory.createDerivative(params);

        PoolKey memory childKey = _buildPoolKey(derivativeVault, parentVault, params.fee, factory.TICK_SPACING());
        bool parentIsZero = Currency.unwrap(childKey.currency0) == parentVault;

        (uint160 initialSqrtPrice, int24 initialTick,,) = POOL_MANAGER.getSlot0(childPoolId);
        console.log("Initial pool tick:", initialTick);
        console.log("Target starting price: 0.5 parent per derivative");

        // Record initial balances and parent pool state
        uint256 initialDerivativeInPool = wNFTMinter(derivativeVault).balanceOf(address(POOL_MANAGER));
        console.log("Derivative tokens in pool:", initialDerivativeInPool);

        // Track parent pool state before minting
        (uint160 parentPoolSqrtPriceBefore, int24 parentPoolTickBefore,,) = POOL_MANAGER.getSlot0(rootPoolId);
        console.log("\n=== PARENT POOL STATE BEFORE DERIVATIVE MINT ===");
        console.log("Parent pool tick:", parentPoolTickBefore);

        // PROGRESSIVE BUY QUOTES: Fixed ETH amounts using exact input
        console.log("\n=== PROGRESSIVE BUY QUOTES (Fixed ETH Amounts) ===");

        // Prime both pools with tiny swaps to activate liquidity
        console.log("Priming pools for quoter...");

        vm.deal(address(this), address(this).balance + 1 ether);
        IPoolManager.SwapParams memory primeRootSwap = IPoolManager.SwapParams({
            zeroForOne: true,
            amountSpecified: -1,
            sqrtPriceLimitX96: TickMath.MIN_SQRT_PRICE + 1
        });
        swapRouter.swap{value: 1}(
            rootKey, primeRootSwap, PoolSwapTest.TestSettings({takeClaims: false, settleUsingBurn: false}), ""
        );

        wNFT(parentVault).approve(address(swapRouter), type(uint256).max);
        IPoolManager.SwapParams memory primeChildSwap = IPoolManager.SwapParams({
            zeroForOne: parentIsZero,
            amountSpecified: -1,
            sqrtPriceLimitX96: parentIsZero ? TickMath.MIN_SQRT_PRICE + 1 : TickMath.MAX_SQRT_PRICE - 1
        });
        swapRouter.swap(
            childKey, primeChildSwap, PoolSwapTest.TestSettings({takeClaims: false, settleUsingBurn: false}), ""
        );
        console.log("Pools primed successfully");

        uint256[] memory ethAmounts = new uint256[](15);
        ethAmounts[0] = 0.01 ether;
        ethAmounts[1] = 0.05 ether;
        ethAmounts[2] = 0.1 ether;
        ethAmounts[3] = 0.25 ether;
        ethAmounts[4] = 0.5 ether;
        ethAmounts[5] = 1 ether;
        ethAmounts[6] = 2 ether;
        ethAmounts[7] = 3 ether;
        ethAmounts[8] = 4 ether;
        ethAmounts[9] = 5 ether;
        ethAmounts[10] = 6 ether;
        ethAmounts[11] = 7 ether;
        ethAmounts[12] = 8 ether;
        ethAmounts[13] = 9 ether;
        ethAmounts[14] = 10 ether;

        for (uint256 i = 0; i < ethAmounts.length; i++) {
            uint256 ethAmount = ethAmounts[i];

            IV4Quoter.QuoteExactParams memory quoteParams;
            quoteParams.exactCurrency = Currency.wrap(address(0));
            quoteParams.exactAmount = uint128(ethAmount);

            quoteParams.path = new PathKey[](2);
            quoteParams.path[0] = PathKey({
                intermediateCurrency: Currency.wrap(parentVault),
                fee: 0x800000,
                tickSpacing: 60,
                hooks: IHooks(HOOK_ADDRESS),
                hookData: ""
            });
            quoteParams.path[1] = PathKey({
                intermediateCurrency: Currency.wrap(derivativeVault),
                fee: params.fee,
                tickSpacing: factory.TICK_SPACING(),
                hooks: IHooks(HOOK_ADDRESS),
                hookData: ""
            });

            try QUOTER.quoteExactInput(quoteParams) returns (uint256 derivTokensOut, uint256) {
                uint256 nftsOut = derivTokensOut / 1e18;
                console.log("---");
                console.log("ETH input:", ethAmount);
                console.log("  Derivative tokens out:", derivTokensOut);
                console.log("  NFTs out:", nftsOut);
                console.log("  ETH per NFT:", nftsOut > 0 ? ethAmount / nftsOut : 0);
                console.log("  Supply %:", (nftsOut * 100) / maxSupply);
            } catch {
                break;
            }
        }
        console.log("---");

        uint256 ethToSpend = 8 ether;

        // STEP 1: Buy parent tokens with ETH
        console.log("\n=== STEP 1: BUY PARENT TOKENS WITH ETH ===");
        vm.deal(address(this), address(this).balance + ethToSpend); // Ensure we have enough ETH
        uint256 parentBalanceBeforeEthSwap = wNFT(parentVault).balanceOf(address(this));
        console.log("ETH to spend:", ethToSpend);

        IPoolManager.SwapParams memory ethSwapParams = IPoolManager.SwapParams({
            zeroForOne: true, // ETH -> parent
            amountSpecified: -int256(ethToSpend),
            sqrtPriceLimitX96: TickMath.MIN_SQRT_PRICE + 1
        });

        swapRouter.swap{value: ethToSpend}(
            rootKey, ethSwapParams, PoolSwapTest.TestSettings({takeClaims: false, settleUsingBurn: false}), ""
        );

        uint256 parentTokensAcquired = wNFT(parentVault).balanceOf(address(this)) - parentBalanceBeforeEthSwap;
        console.log("Parent tokens acquired:", parentTokensAcquired);
        console.log("ETH spent:", ethToSpend);
        console.log("Parent tokens per ETH:", parentTokensAcquired / 1e18);

        // STEP 2: Buy derivative tokens with parent tokens
        console.log("\n=== STEP 2: BUY DERIVATIVE TOKENS WITH PARENT ===");
        wNFT(parentVault).approve(address(swapRouter), type(uint256).max);

        // Prime the pool with a tiny swap first to enable proper execution
        console.log("Priming pool with tiny swap...");
        IPoolManager.SwapParams memory primeSwap = IPoolManager.SwapParams({
            zeroForOne: parentIsZero,
            amountSpecified: -1, // Sell 1 wei of parent token
            sqrtPriceLimitX96: parentIsZero ? TickMath.MIN_SQRT_PRICE + 1 : TickMath.MAX_SQRT_PRICE - 1
        });
        swapRouter.swap(childKey, primeSwap, PoolSwapTest.TestSettings({takeClaims: false, settleUsingBurn: false}), "");
        console.log("Pool primed successfully");

        uint256 parentBalanceBeforeDerivSwap = wNFT(parentVault).balanceOf(address(this));
        uint256 parentToSpend = parentTokensAcquired - 1; // Use acquired tokens minus the 1 wei for priming

        console.log("Parent tokens to spend:", parentToSpend);

        IPoolManager.SwapParams memory derivSwapParams = IPoolManager.SwapParams({
            zeroForOne: parentIsZero,
            amountSpecified: -int256(parentToSpend),
            sqrtPriceLimitX96: parentIsZero ? TickMath.MIN_SQRT_PRICE + 1 : TickMath.MAX_SQRT_PRICE - 1
        });

        swapRouter.swap(
            childKey, derivSwapParams, PoolSwapTest.TestSettings({takeClaims: false, settleUsingBurn: false}), ""
        );

        uint256 derivativeBalance = wNFTMinter(derivativeVault).balanceOf(address(this));
        uint256 parentSpent = parentBalanceBeforeDerivSwap - wNFT(parentVault).balanceOf(address(this));

        console.log("Derivative tokens acquired:", derivativeBalance);
        console.log("Parent tokens actually spent:", parentSpent);
        console.log("Derivative per parent:", derivativeBalance / (parentSpent / 1e18));

        // Check pool state after swap
        (uint160 finalSqrtPrice, int24 finalTick,,) = POOL_MANAGER.getSlot0(childPoolId);
        console.log("Final pool tick:", finalTick);
        console.log("Tick movement:", int256(finalTick) - int256(initialTick));
        console.log(
            "Derivative tokens remaining in pool:", wNFTMinter(derivativeVault).balanceOf(address(POOL_MANAGER))
        );

        // STEP 3: Mint NFTs from derivative tokens
        console.log("\n=== STEP 3: MINT NFTs FROM DERIVATIVE TOKENS ===");
        uint256 nftsToMint = derivativeBalance / 1e18;
        console.log("NFTs we can mint:", nftsToMint);

        uint256[] memory mintedTokenIds = wNFTMinter(derivativeVault).mint(nftsToMint, address(this));

        console.log("NFTs successfully minted:", MockERC721Simple(nft).balanceOf(address(this)));
        console.log("First NFT ID minted:", mintedTokenIds[0]);
        console.log("Last NFT ID minted:", mintedTokenIds[mintedTokenIds.length - 1]);

        // STEP 4: Analyze Parent Pool Price Impact
        console.log("\n=== PARENT POOL PRICE IMPACT ANALYSIS ===");
        (uint160 parentPoolSqrtPriceAfter, int24 parentPoolTickAfter,,) = POOL_MANAGER.getSlot0(rootPoolId);
        console.log("Parent pool tick after mint:", parentPoolTickAfter);
        console.log("Parent pool tick movement:", int256(parentPoolTickAfter) - int256(parentPoolTickBefore));

        // Get actual quotes by doing small test swaps and reverting
        console.log("\n=== PARENT TOKEN SELL QUOTES (Parent -> ETH) ===");
        uint256[] memory sellAmounts = new uint256[](5);
        sellAmounts[0] = 1e18; // 1 parent token
        sellAmounts[1] = 5e18; // 5 parent tokens
        sellAmounts[2] = 10e18; // 10 parent tokens
        sellAmounts[3] = 25e18; // 25 parent tokens
        sellAmounts[4] = 50e18; // 50 parent tokens

        for (uint256 i = 0; i < sellAmounts.length; i++) {
            uint256 sellAmount = sellAmounts[i];
            console.log("---");
            console.log("Quote for selling", sellAmount / 1e18, "parent tokens:");

            // Snapshot state
            uint256 snapshotId = vm.snapshot();

            // Do the swap to see output
            uint256 ethBefore = address(this).balance;
            IPoolManager.SwapParams memory sellParams = IPoolManager.SwapParams({
                zeroForOne: false, // parent -> ETH
                amountSpecified: -int256(sellAmount),
                sqrtPriceLimitX96: TickMath.MAX_SQRT_PRICE - 1
            });

            swapRouter.swap(
                rootKey, sellParams, PoolSwapTest.TestSettings({takeClaims: false, settleUsingBurn: false}), ""
            );
            uint256 ethReceived = address(this).balance - ethBefore;

            console.log("  Parent tokens sold:", sellAmount);
            console.log("  ETH received:", ethReceived);
            console.log("  Price (ETH per parent):", ethReceived * 1e18 / sellAmount);

            // Revert to snapshot
            vm.revertTo(snapshotId);
        }

        // SUMMARY
        console.log("\n=== SUMMARY ===");
        console.log("Total ETH spent:", ethToSpend);
        console.log("Total parent tokens spent:", parentSpent);
        console.log("Total derivative tokens acquired:", derivativeBalance);
        console.log("Total NFTs minted:", nftsToMint);
        console.log("ETH per NFT:", ethToSpend / nftsToMint);
        console.log("Parent per NFT:", parentSpent / nftsToMint);
        console.log("Collection mint progress:", (nftsToMint * 100) / maxSupply, "%");
        int256 parentPoolTickImpact = int256(parentPoolTickAfter) - int256(parentPoolTickBefore);
        console.log("Parent pool price impact (ticks):", parentPoolTickImpact);

        // Verify we acquired tokens
        assertGt(derivativeBalance, 0, "Should have acquired derivative tokens");
        assertGt(nftsToMint, 0, "Should be able to mint NFTs");
    }

    function test_MintOut_HIGH_SUPPLY_Derivative() public {
        console.log("===========================================================");
        console.log("=== HIGH SUPPLY DERIVATIVE: 0.25 to 2.0 parent/deriv ===");
        console.log("===========================================================");

        // Approve parent vault tokens for derivative creation
        wNFT(parentVault).approve(address(factory), type(uint256).max);

        // Setup derivative parameters for 1000 token supply
        uint256 maxSupply = 1000;
        DerivativeFactory.DerivativeParams memory params;
        params.parentCollection = address(parentCollection);
        params.nftName = "HIGH Supply Derivative";
        params.nftSymbol = "HIDRV";
        params.nftBaseUri = "ipfs://high/";
        params.nftOwner = address(this);
        params.initialMinter = address(0);
        params.fee = 0x800000; // LPFeeLibrary.DYNAMIC_FEE_FLAG - only 10% hook fee
        params.maxSupply = maxSupply;

        // Price range: 0.25 to 2.0 parent per derivative (8x range)
        // In pool terms (derivative/parent): price = 0.5 to 4.0
        params.tickLower = -6960; // tick -6960 ≈ 2.0 parent per derivative
        params.tickUpper = 13860; // tick 13860 ≈ 0.25 parent per derivative

        // Initialize at tick 13860 (at upper boundary) for single-sided derivative liquidity
        params.sqrtPriceX96 = TickMath.getSqrtPriceAtTick(13860);

        params.liquidity = 1; // Factory calculates this
        params.parentTokenContribution = 0;
        params.derivativeTokenRecipient = address(this);
        params.parentTokenRefundRecipient = address(this);
        params.salt = mineSaltForToken1(factory, parentVault, params.maxSupply);

        console.log("\n=== CREATING DERIVATIVE ===");
        (address nft, address derivativeVault, PoolId childPoolId) = factory.createDerivative(params);

        PoolKey memory childKey = _buildPoolKey(derivativeVault, parentVault, params.fee, factory.TICK_SPACING());
        bool parentIsZero = Currency.unwrap(childKey.currency0) == parentVault;

        (uint160 initialSqrtPrice, int24 initialTick,,) = POOL_MANAGER.getSlot0(childPoolId);
        console.log("Initial pool tick:", initialTick);
        console.log("Target starting price: 0.25 parent per derivative");

        // Record initial balances and parent pool state
        uint256 initialDerivativeInPool = wNFTMinter(derivativeVault).balanceOf(address(POOL_MANAGER));
        console.log("Derivative tokens in pool:", initialDerivativeInPool);

        // Track parent pool state before minting
        (uint160 parentPoolSqrtPriceBefore, int24 parentPoolTickBefore,,) = POOL_MANAGER.getSlot0(rootPoolId);
        console.log("\n=== PARENT POOL STATE BEFORE DERIVATIVE MINT ===");
        console.log("Parent pool tick:", parentPoolTickBefore);

        // PROGRESSIVE BUY QUOTES: Fixed ETH amounts using exact input
        console.log("\n=== PROGRESSIVE BUY QUOTES (Fixed ETH Amounts) ===");

        // Prime both pools with tiny swaps to activate liquidity
        console.log("Priming pools for quoter...");

        vm.deal(address(this), address(this).balance + 1 ether);
        IPoolManager.SwapParams memory primeRootSwap = IPoolManager.SwapParams({
            zeroForOne: true,
            amountSpecified: -1,
            sqrtPriceLimitX96: TickMath.MIN_SQRT_PRICE + 1
        });
        swapRouter.swap{value: 1}(
            rootKey, primeRootSwap, PoolSwapTest.TestSettings({takeClaims: false, settleUsingBurn: false}), ""
        );

        wNFT(parentVault).approve(address(swapRouter), type(uint256).max);
        IPoolManager.SwapParams memory primeChildSwap = IPoolManager.SwapParams({
            zeroForOne: parentIsZero,
            amountSpecified: -1,
            sqrtPriceLimitX96: parentIsZero ? TickMath.MIN_SQRT_PRICE + 1 : TickMath.MAX_SQRT_PRICE - 1
        });
        swapRouter.swap(
            childKey, primeChildSwap, PoolSwapTest.TestSettings({takeClaims: false, settleUsingBurn: false}), ""
        );
        console.log("Pools primed successfully");

        uint256[] memory ethAmounts = new uint256[](25);
        ethAmounts[0] = 0.01 ether;
        ethAmounts[1] = 0.05 ether;
        ethAmounts[2] = 0.1 ether;
        ethAmounts[3] = 0.25 ether;
        ethAmounts[4] = 0.5 ether;
        ethAmounts[5] = 1 ether;
        ethAmounts[6] = 2 ether;
        ethAmounts[7] = 3 ether;
        ethAmounts[8] = 4 ether;
        ethAmounts[9] = 5 ether;
        ethAmounts[10] = 6 ether;
        ethAmounts[11] = 7 ether;
        ethAmounts[12] = 8 ether;
        ethAmounts[13] = 9 ether;
        ethAmounts[14] = 10 ether;
        ethAmounts[15] = 11 ether;
        ethAmounts[16] = 12 ether;
        ethAmounts[17] = 13 ether;
        ethAmounts[18] = 14 ether;
        ethAmounts[19] = 15 ether;
        ethAmounts[20] = 16 ether;
        ethAmounts[21] = 17 ether;
        ethAmounts[22] = 18 ether;
        ethAmounts[23] = 19 ether;
        ethAmounts[24] = 20 ether;

        for (uint256 i = 0; i < ethAmounts.length; i++) {
            uint256 ethAmount = ethAmounts[i];

            IV4Quoter.QuoteExactParams memory quoteParams;
            quoteParams.exactCurrency = Currency.wrap(address(0));
            quoteParams.exactAmount = uint128(ethAmount);

            quoteParams.path = new PathKey[](2);
            quoteParams.path[0] = PathKey({
                intermediateCurrency: Currency.wrap(parentVault),
                fee: 0x800000,
                tickSpacing: 60,
                hooks: IHooks(HOOK_ADDRESS),
                hookData: ""
            });
            quoteParams.path[1] = PathKey({
                intermediateCurrency: Currency.wrap(derivativeVault),
                fee: params.fee,
                tickSpacing: factory.TICK_SPACING(),
                hooks: IHooks(HOOK_ADDRESS),
                hookData: ""
            });

            try QUOTER.quoteExactInput(quoteParams) returns (uint256 derivTokensOut, uint256) {
                uint256 nftsOut = derivTokensOut / 1e18;
                console.log("---");
                console.log("ETH input:", ethAmount);
                console.log("  Derivative tokens out:", derivTokensOut);
                console.log("  NFTs out:", nftsOut);
                console.log("  ETH per NFT:", nftsOut > 0 ? ethAmount / nftsOut : 0);
                console.log("  Supply %:", (nftsOut * 100) / maxSupply);
            } catch {
                break;
            }
        }
        console.log("---");

        // STEP 1: Buy parent tokens with ETH
        console.log("\n=== STEP 1: BUY PARENT TOKENS WITH ETH ===");
        uint256 ethToSpend = 15 ether; // Large supply needs more ETH
        vm.deal(address(this), address(this).balance + ethToSpend);
        uint256 parentBalanceBeforeEthSwap = wNFT(parentVault).balanceOf(address(this));
        console.log("ETH to spend:", ethToSpend);

        IPoolManager.SwapParams memory ethSwapParams = IPoolManager.SwapParams({
            zeroForOne: true, // ETH -> parent
            amountSpecified: -int256(ethToSpend),
            sqrtPriceLimitX96: TickMath.MIN_SQRT_PRICE + 1
        });

        swapRouter.swap{value: ethToSpend}(
            rootKey, ethSwapParams, PoolSwapTest.TestSettings({takeClaims: false, settleUsingBurn: false}), ""
        );

        uint256 parentTokensAcquired = wNFT(parentVault).balanceOf(address(this)) - parentBalanceBeforeEthSwap;
        console.log("Parent tokens acquired:", parentTokensAcquired);
        console.log("ETH spent:", ethToSpend);
        console.log("Parent tokens per ETH:", parentTokensAcquired / 1e18);

        // STEP 2: Buy derivative tokens with parent tokens
        console.log("\n=== STEP 2: BUY DERIVATIVE TOKENS WITH PARENT ===");
        wNFT(parentVault).approve(address(swapRouter), type(uint256).max);

        // Prime the pool with a tiny swap first to enable proper execution
        console.log("Priming pool with tiny swap...");
        IPoolManager.SwapParams memory primeSwap = IPoolManager.SwapParams({
            zeroForOne: parentIsZero,
            amountSpecified: -1, // Sell 1 wei of parent token
            sqrtPriceLimitX96: parentIsZero ? TickMath.MIN_SQRT_PRICE + 1 : TickMath.MAX_SQRT_PRICE - 1
        });
        swapRouter.swap(childKey, primeSwap, PoolSwapTest.TestSettings({takeClaims: false, settleUsingBurn: false}), "");
        console.log("Pool primed successfully");

        uint256 parentBalanceBeforeDerivSwap = wNFT(parentVault).balanceOf(address(this));
        uint256 parentToSpend = parentTokensAcquired - 1; // Use acquired tokens minus the 1 wei for priming

        console.log("Parent tokens to spend:", parentToSpend);

        IPoolManager.SwapParams memory derivSwapParams = IPoolManager.SwapParams({
            zeroForOne: parentIsZero,
            amountSpecified: -int256(parentToSpend),
            sqrtPriceLimitX96: parentIsZero ? TickMath.MIN_SQRT_PRICE + 1 : TickMath.MAX_SQRT_PRICE - 1
        });

        swapRouter.swap(
            childKey, derivSwapParams, PoolSwapTest.TestSettings({takeClaims: false, settleUsingBurn: false}), ""
        );

        uint256 derivativeBalance = wNFTMinter(derivativeVault).balanceOf(address(this));
        uint256 parentSpent = parentBalanceBeforeDerivSwap - wNFT(parentVault).balanceOf(address(this));

        console.log("Derivative tokens acquired:", derivativeBalance);
        console.log("Parent tokens actually spent:", parentSpent);
        console.log("Derivative per parent:", derivativeBalance / (parentSpent / 1e18));

        // Check pool state after swap
        (uint160 finalSqrtPrice, int24 finalTick,,) = POOL_MANAGER.getSlot0(childPoolId);
        console.log("Final pool tick:", finalTick);
        console.log("Tick movement:", int256(finalTick) - int256(initialTick));
        console.log(
            "Derivative tokens remaining in pool:", wNFTMinter(derivativeVault).balanceOf(address(POOL_MANAGER))
        );

        // STEP 3: Mint NFTs from derivative tokens
        console.log("\n=== STEP 3: MINT NFTs FROM DERIVATIVE TOKENS ===");
        uint256 nftsToMint = derivativeBalance / 1e18;
        console.log("NFTs we can mint:", nftsToMint);

        uint256[] memory mintedTokenIds = wNFTMinter(derivativeVault).mint(nftsToMint, address(this));

        console.log("NFTs successfully minted:", MockERC721Simple(nft).balanceOf(address(this)));
        console.log("First NFT ID minted:", mintedTokenIds[0]);
        console.log("Last NFT ID minted:", mintedTokenIds[mintedTokenIds.length - 1]);

        // STEP 4: Analyze Parent Pool Price Impact
        console.log("\n=== PARENT POOL PRICE IMPACT ANALYSIS ===");
        (uint160 parentPoolSqrtPriceAfter, int24 parentPoolTickAfter,,) = POOL_MANAGER.getSlot0(rootPoolId);
        console.log("Parent pool tick after mint:", parentPoolTickAfter);
        console.log("Parent pool tick movement:", int256(parentPoolTickAfter) - int256(parentPoolTickBefore));

        // Get actual quotes by doing small test swaps and reverting
        console.log("\n=== PARENT TOKEN SELL QUOTES (Parent -> ETH) ===");
        uint256[] memory sellAmounts = new uint256[](5);
        sellAmounts[0] = 1e18; // 1 parent token
        sellAmounts[1] = 5e18; // 5 parent tokens
        sellAmounts[2] = 10e18; // 10 parent tokens
        sellAmounts[3] = 25e18; // 25 parent tokens
        sellAmounts[4] = 50e18; // 50 parent tokens

        for (uint256 i = 0; i < sellAmounts.length; i++) {
            uint256 sellAmount = sellAmounts[i];
            console.log("---");
            console.log("Quote for selling", sellAmount / 1e18, "parent tokens:");

            // Snapshot state
            uint256 snapshotId = vm.snapshot();

            // Do the swap to see output
            uint256 ethBefore = address(this).balance;
            IPoolManager.SwapParams memory sellParams = IPoolManager.SwapParams({
                zeroForOne: false, // parent -> ETH
                amountSpecified: -int256(sellAmount),
                sqrtPriceLimitX96: TickMath.MAX_SQRT_PRICE - 1
            });

            swapRouter.swap(
                rootKey, sellParams, PoolSwapTest.TestSettings({takeClaims: false, settleUsingBurn: false}), ""
            );
            uint256 ethReceived = address(this).balance - ethBefore;

            console.log("  Parent tokens sold:", sellAmount);
            console.log("  ETH received:", ethReceived);
            console.log("  Price (ETH per parent):", ethReceived * 1e18 / sellAmount);

            // Revert to snapshot
            vm.revertTo(snapshotId);
        }

        // SUMMARY
        console.log("\n=== SUMMARY ===");
        console.log("Total ETH spent:", ethToSpend);
        console.log("Total parent tokens spent:", parentSpent);
        console.log("Total derivative tokens acquired:", derivativeBalance);
        console.log("Total NFTs minted:", nftsToMint);
        console.log("ETH per NFT:", ethToSpend / nftsToMint);
        console.log("Parent per NFT:", parentSpent / nftsToMint);
        console.log("Collection mint progress:", (nftsToMint * 100) / maxSupply, "%");
        int256 parentPoolTickImpact = int256(parentPoolTickAfter) - int256(parentPoolTickBefore);
        console.log("Parent pool price impact (ticks):", parentPoolTickImpact);

        // Verify we acquired tokens
        assertGt(derivativeBalance, 0, "Should have acquired derivative tokens");
        assertGt(nftsToMint, 0, "Should be able to mint NFTs");
    }
}
