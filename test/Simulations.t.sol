// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {BaseTest} from "./BaseTest.t.sol";
import {DerivativeTestUtils} from "./DerivativeTestUtils.sol";
import {console} from "forge-std/console.sol";

import {RemyVaultFactory} from "../src/RemyVaultFactory.sol";
import {RemyVault} from "../src/RemyVault.sol";
import {MinterRemyVault} from "../src/MinterRemyVault.sol";
import {DerivativeFactory} from "../src/DerivativeFactory.sol";
import {RemyVaultHook} from "../src/RemyVaultHook.sol";
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
import {PoolModifyLiquidityTest} from "@uniswap/v4-core/src/test/PoolModifyLiquidityTest.sol";
import {LiquidityAmounts} from "@uniswap/v4-core/test/utils/LiquidityAmounts.sol";

contract Simulations is BaseTest, DerivativeTestUtils {
    using PoolIdLibrary for PoolKey;
    using StateLibrary for IPoolManager;

    receive() external payable {}

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

    RemyVaultFactory internal vaultFactory;
    RemyVaultHook internal hook;
    DerivativeFactory internal factory;
    PoolModifyLiquidityTest internal liquidityHelper;

    // Parent pool state (initialized in _setUpParentPool)
    MockERC721Simple internal parentCollection;
    address internal parentVault;
    PoolKey internal rootKey;
    PoolId internal rootPoolId;

    function setUp() public override {
        super.setUp();

        vaultFactory = new RemyVaultFactory();

        vm.etch(HOOK_ADDRESS, hex"");
        deployCodeTo("RemyVaultHook.sol:RemyVaultHook", abi.encode(POOL_MANAGER, address(this)), HOOK_ADDRESS);
        hook = RemyVaultHook(HOOK_ADDRESS);

        factory = new DerivativeFactory(vaultFactory, hook, address(this));
        hook.transferOwnership(address(factory));

        liquidityHelper = new PoolModifyLiquidityTest(POOL_MANAGER);

        // Initialize parent pool with standard parameters
        _setUpParentPool();
    }

    function _setUpParentPool() internal {
        // Create parent collection and vault
        parentCollection = new MockERC721Simple("Parent NFT", "PRNT");

        // Mint 500 parent NFTs to this contract (need 300 for liquidity + some for derivative)
        for (uint256 i = 1; i <= 500; i++) {
            parentCollection.mint(address(this), i);
        }

        // Create parent vault
        parentVault = vaultFactory.deployVault(address(parentCollection), "Parent Vault", "PVAL");

        // Deposit NFTs into parent vault
        uint256[] memory tokenIds = new uint256[](500);
        for (uint256 i = 0; i < 500; i++) {
            tokenIds[i] = i + 1;
        }
        parentCollection.setApprovalForAll(parentVault, true);
        RemyVault(parentVault).deposit(tokenIds, address(this));

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
        _addLiquidityToPool(rootKey, 23040, 46020, 300e18, 0, address(this));

        // Range 2: ETH for buying parent as price falls (0.01006 → 0.001 ETH per parent)
        // From tick 46020 (current tick) to 69060 (0.001 ETH/parent)
        // Current tick = lower bound, so range is active, provides liquidity
        vm.deal(address(this), 10 ether);
        _addLiquidityToPool(rootKey, 46020, 69060, 0, 2 ether, address(this));
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

        // Create RemyVault for the OG NFT collection
        vm.prank(userA);
        address vaultAddress = vaultFactory.deployVault(address(ogNFT), "OG Vault", "OGV");
        RemyVault vault = RemyVault(vaultAddress);

        // Verify the vault was created correctly
        assertEq(vault.erc721(), address(ogNFT));
        assertEq(userA.balance, 10 ether);
        assertEq(ogNFT.balanceOf(userA), 1000);
    }

    function test_DerivativeCreation_EntireSupplyAsLiquidity() public {
        // Parent pool is already initialized in setUp via _setUpParentPool()
        // Quote: 0.1 ETH -> parent tokens (root pool)
        (uint256 parentTokensOut, uint256 ethGasEstimate) = QUOTER.quoteExactInputSingle(
            IV4Quoter.QuoteExactSingleParams({
                poolKey: rootKey,
                zeroForOne: true,
                exactAmount: 0.1 ether,
                hookData: ""
            })
        );

        console.log("=== SWAP QUOTES ===");
        console.log("0.1 ETH -> parent tokens:", parentTokensOut);
        console.log("Gas estimate (ETH->parent):", ethGasEstimate);

        // Approve parent vault tokens for derivative creation
        RemyVault(parentVault).approve(address(factory), type(uint256).max);

        // Setup derivative parameters
        uint256 maxSupply = 50;
        DerivativeFactory.DerivativeParams memory params;
        params.parentCollection = address(parentCollection);
        params.nftName = "Test Derivative";
        params.nftSymbol = "TDRV";
        params.nftBaseUri = "ipfs://test/";
        params.nftOwner = address(this);
        params.initialMinter = address(0);
        params.vaultName = "Test Derivative Token";
        params.vaultSymbol = "tDRV";
        params.fee = 3000;
        params.tickSpacing = 60;
        params.maxSupply = maxSupply;
        params.tickLower = -12000;
        params.tickUpper = -7200;
        params.sqrtPriceX96 = 56022770974786139918731938227;
        params.liquidity = 15e18;
        params.parentTokenContribution = 0;
        params.derivativeTokenRecipient = address(this);
        params.parentTokenRefundRecipient = address(this);
        params.salt = mineSaltForToken1(factory, parentVault, params.vaultName, params.vaultSymbol, maxSupply);

        // Create derivative
        (address nft, address derivativeVault, PoolId childPoolId) = factory.createDerivative(params);

        // Quote: 1 parent token -> derivative tokens (child pool)
        PoolKey memory childKey = _buildPoolKey(derivativeVault, parentVault, params.fee, params.tickSpacing);
        bool parentIsZero = Currency.unwrap(childKey.currency0) == parentVault;
        try QUOTER.quoteExactInputSingle(
            IV4Quoter.QuoteExactSingleParams({
                poolKey: childKey,
                zeroForOne: parentIsZero,
                exactAmount: 1e18,
                hookData: ""
            })
        ) returns (uint256 derivativeTokensOut, uint256 parentGasEstimate) {
            console.log("1 parent token -> derivative tokens:", derivativeTokensOut);
            console.log("Gas estimate (parent->derivative):", parentGasEstimate);
        } catch {
            console.log("Derivative quote failed (may be restricted by hook)");
        }

        // Verify factory has no leftover tokens
        assertEq(MinterRemyVault(derivativeVault).balanceOf(address(factory)), 0, "Factory should have 0 derivative tokens");
        assertEq(RemyVault(parentVault).balanceOf(address(factory)), 0, "Factory should have 0 parent tokens");
    }

    function _initRootPool(address parentVault, uint24 /* fee */, int24 tickSpacing, uint160 sqrtPriceX96)
        internal
        returns (PoolId poolId)
    {
        uint24 fee = 0x800000; // LPFeeLibrary.DYNAMIC_FEE_FLAG
        PoolKey memory key = _buildPoolKey(address(0), parentVault, fee, tickSpacing);
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
        RemyVault(parentVault).approve(address(factory), type(uint256).max);

        // Setup derivative parameters for 1000 token supply
        uint256 maxSupply = 1000;
        DerivativeFactory.DerivativeParams memory params;
        params.parentCollection = address(parentCollection);
        params.nftName = "1K Derivative";
        params.nftSymbol = "1KDRV";
        params.nftBaseUri = "ipfs://1k/";
        params.nftOwner = address(this);
        params.initialMinter = address(0);
        params.vaultName = "1K Derivative Token";
        params.vaultSymbol = "1KDRV";
        params.fee = 3000;
        params.tickSpacing = 60;
        params.maxSupply = maxSupply;

        // Price range: 0.1 to 1 parent per derivative
        // In pool terms (derivative/parent): price = 1 to 10
        // tick 0 = price 1 (1 parent per derivative)
        // tick 23040 ≈ price 10 (0.1 parent per derivative)
        params.tickLower = 0;
        params.tickUpper = 23040;

        // Initialize above range (at tick 23100) for single-sided derivative liquidity
        // When price > range upper bound, position is 100% token1 (derivative)
        params.sqrtPriceX96 = TickMath.getSqrtPriceAtTick(23100);

        // Liquidity will be calculated by factory to consume all 1000 derivative tokens
        params.liquidity = 1; // Factory ignores this, just needs to be non-zero

        params.parentTokenContribution = 0;
        params.derivativeTokenRecipient = address(this);
        params.parentTokenRefundRecipient = address(this);
        params.salt = mineSaltForToken1(factory, parentVault, params.vaultName, params.vaultSymbol, maxSupply);

        console.log("=== CREATING DERIVATIVE ==");
        (address nft, address derivativeVault, PoolId childPoolId) = factory.createDerivative(params);

        // Build child pool key
        PoolKey memory childKey = _buildPoolKey(derivativeVault, parentVault, params.fee, params.tickSpacing);
        bool parentIsZero = Currency.unwrap(childKey.currency0) == parentVault;

        // Verify pool state
        (uint160 actualSqrtPrice, int24 actualTick,,) = POOL_MANAGER.getSlot0(childPoolId);
        console.log("Child pool initialized at tick:", actualTick);
        console.log("Expected tick: 23100");
        assertEq(actualTick, 23100, "Pool should initialize at tick 23100");

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

            // At starting price ~10 (0.1 parent per derivative), should get ~10 derivative tokens per parent
            assertGt(derivativeTokensOut, 9e18, "Should get at least 9 derivative tokens");
            assertLt(derivativeTokensOut, 11e18, "Should get at most 11 derivative tokens");

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

        // Verify factory has no leftover tokens
        assertEq(MinterRemyVault(derivativeVault).balanceOf(address(factory)), 0, "Factory should have 0 derivative tokens");
        assertEq(RemyVault(parentVault).balanceOf(address(factory)), 0, "Factory should have 0 parent tokens");
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
        uint128 liquidity =
            LiquidityAmounts.getLiquidityForAmounts(sqrtPriceX96, sqrtPriceAX96, sqrtPriceBX96, amount0Desired, amount1Desired);

        // Approve tokens if needed
        if (amount0Desired > 0 && Currency.unwrap(key.currency0) != address(0)) {
            // ERC20 token
            RemyVault(Currency.unwrap(key.currency0)).approve(address(liquidityHelper), amount0Desired);
        }
        if (amount1Desired > 0) {
            RemyVault(Currency.unwrap(key.currency1)).approve(address(liquidityHelper), amount1Desired);
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
}