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

    function setUp() public override {
        super.setUp();

        vaultFactory = new RemyVaultFactory();

        vm.etch(HOOK_ADDRESS, hex"");
        deployCodeTo("RemyVaultHook.sol:RemyVaultHook", abi.encode(POOL_MANAGER, address(this)), HOOK_ADDRESS);
        hook = RemyVaultHook(HOOK_ADDRESS);

        factory = new DerivativeFactory(vaultFactory, hook, address(this));
        hook.transferOwnership(address(factory));

        liquidityHelper = new PoolModifyLiquidityTest(POOL_MANAGER);
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
        // Setup: Create parent collection and vault
        MockERC721Simple parentCollection = new MockERC721Simple("Parent NFT", "PRNT");

        // Mint 100 parent NFTs to this contract
        for (uint256 i = 1; i <= 100; i++) {
            parentCollection.mint(address(this), i);
        }

        // Create parent vault
        address parentVault = vaultFactory.deployVault(address(parentCollection), "Parent Vault", "PVAL");

        // Deposit NFTs into parent vault
        uint256[] memory tokenIds = new uint256[](100);
        for (uint256 i = 0; i < 100; i++) {
            tokenIds[i] = i + 1;
        }
        parentCollection.setApprovalForAll(parentVault, true);
        RemyVault(parentVault).deposit(tokenIds, address(this));

        // Create root pool with price = 0.01 ETH per parent token
        // Parent is token1, ETH is token0
        // Price = 100 parent per ETH = 100, sqrtPrice = sqrt(100) * 2^96 = 10 * 2^96
        uint160 sqrtPrice001 = 792281625142643375935439503360;
        PoolId rootPoolId = _initRootPool(parentVault, 3000, 60, sqrtPrice001);
        PoolKey memory rootKey = _buildPoolKey(address(0), parentVault, 0x800000, 60);

        // Add liquidity to root pool (current tick ≈ 46052)
        // Range 1: 0.001-0.009 ETH per parent (price falls from 0.01)
        // tick for 0.001 ETH/parent (1000 parent/ETH) ≈ 69078, for 0.009 (111 parent/ETH) ≈ 46964
        // Round to tickSpacing of 60: 46920 to 69060
        // Current tick < range, so liquidity is 100% in token0 (ETH)
        vm.deal(address(this), 10 ether);
        _addLiquidityToPool(rootKey, 46920, 69060, 0, 2 ether, address(this));

        // Range 2: 0.011-0.1 ETH per parent (price rises from 0.01)
        // tick for 0.011 ETH/parent (91 parent/ETH) ≈ 45074, for 0.1 (10 parent/ETH) ≈ 23027
        // Round to tickSpacing of 60: 23040 to 45060
        // Current tick > range, so liquidity is 100% in token1 (parent tokens)
        _addLiquidityToPool(rootKey, 23040, 45060, 10e18, 0, address(this));

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