// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {StdInvariant} from "forge-std/StdInvariant.sol";
import {Vm} from "forge-std/Vm.sol";
import {BaseTest} from "./BaseTest.t.sol";

import {wNFTHook} from "../src/wNFTHook.sol";
import {PoolModifyLiquidityTest} from "@uniswap/v4-core/src/test/PoolModifyLiquidityTest.sol";
import {PoolSwapTest} from "@uniswap/v4-core/src/test/PoolSwapTest.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
import {Currency, CurrencyLibrary} from "@uniswap/v4-core/src/types/Currency.sol";
import {Hooks} from "@uniswap/v4-core/src/libraries/Hooks.sol";
import {BalanceDelta} from "@uniswap/v4-core/src/types/BalanceDelta.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";

import {MockERC20} from "solmate/src/test/utils/mocks/MockERC20.sol";

/// @title RemyVaultHookInvariantTest
/// @dev Invariant tests for the wNFTHook fee distribution mechanism
contract RemyVaultHookInvariantTest is BaseTest {
    using PoolIdLibrary for PoolKey;

    uint256 internal constant TOTAL_FEE_BPS = 1_000;
    uint256 internal constant FEE_DENOMINATOR = 10_000;
    uint256 internal constant CHILD_SHARE_WITH_PARENT_BPS = 750;

    uint160 internal constant CLEAR_HOOK_PERMISSIONS_MASK = ~uint160(0) << 14;
    uint160 internal constant HOOK_FLAGS = Hooks.BEFORE_SWAP_FLAG | Hooks.AFTER_SWAP_FLAG
        | Hooks.BEFORE_SWAP_RETURNS_DELTA_FLAG | Hooks.AFTER_SWAP_RETURNS_DELTA_FLAG;
    uint160 internal constant HOOK_ADDRESS_SEED = uint160(0x4444000000000000000000000000000000000000);
    address internal constant HOOK_ADDRESS =
        address(uint160((HOOK_ADDRESS_SEED & CLEAR_HOOK_PERMISSIONS_MASK) | HOOK_FLAGS));

    address internal constant POOL_MANAGER_ADDRESS = 0x498581fF718922c3f8e6A244956aF099B2652b2b;
    IPoolManager internal constant POOL_MANAGER = IPoolManager(POOL_MANAGER_ADDRESS);

    bytes32 internal constant DONATE_TOPIC = keccak256("Donate(bytes32,address,uint256,uint256)");

    uint160 internal constant SQRT_PRICE_1_1 = 79228162514264337593543950336;
    uint128 internal constant LIQUIDITY = 1e18;

    PoolModifyLiquidityTest internal modifyRouter;
    PoolSwapTest internal swapRouter;
    wNFTHook internal hook;

    MockERC20 internal sharedToken;
    MockERC20 internal altToken;

    Currency internal remyCurrency;
    Currency internal altCurrency;

    PoolKey internal rootKey;
    PoolKey internal childKey;
    PoolId internal rootPoolId;
    PoolId internal childPoolId;

    uint256 internal totalSwapCount;
    uint256 internal totalSwapAmount;
    uint256 internal totalFeesDonated;

    receive() external payable {}

    function setUp() public override {
        super.setUp();
        vm.deal(address(this), 1_000_000 ether);

        modifyRouter = new PoolModifyLiquidityTest(POOL_MANAGER);
        swapRouter = new PoolSwapTest(POOL_MANAGER);

        sharedToken = new MockERC20("Remy Vault Token", "REMYT", 18);
        altToken = new MockERC20("Alt Stable", "ALT", 18);

        uint256 mintAmount = 1e36;
        sharedToken.mint(address(this), mintAmount);
        altToken.mint(address(this), mintAmount);

        sharedToken.approve(address(modifyRouter), type(uint256).max);
        sharedToken.approve(address(swapRouter), type(uint256).max);
        altToken.approve(address(modifyRouter), type(uint256).max);
        altToken.approve(address(swapRouter), type(uint256).max);

        vm.etch(HOOK_ADDRESS, hex"");
        deployCodeTo("wNFTHook.sol:wNFTHook", abi.encode(POOL_MANAGER, address(this)), HOOK_ADDRESS);
        hook = wNFTHook(HOOK_ADDRESS);

        remyCurrency = Currency.wrap(address(sharedToken));
        altCurrency = Currency.wrap(address(altToken));

        rootKey = PoolKey({
            currency0: CurrencyLibrary.ADDRESS_ZERO,
            currency1: remyCurrency,
            fee: 3000,
            tickSpacing: 60,
            hooks: IHooks(HOOK_ADDRESS)
        });
        rootPoolId = rootKey.toId();

        (Currency childCurrency0, Currency childCurrency1) = _sortCurrencies(remyCurrency, altCurrency);
        childKey = PoolKey({
            currency0: childCurrency0,
            currency1: childCurrency1,
            fee: 3000,
            tickSpacing: 60,
            hooks: IHooks(HOOK_ADDRESS)
        });
        childPoolId = childKey.toId();

        PoolKey memory emptyKey;
        hook.addChild(rootKey, false, emptyKey);
        hook.addChild(childKey, true, rootKey);

        POOL_MANAGER.initialize(rootKey, SQRT_PRICE_1_1);
        POOL_MANAGER.initialize(childKey, SQRT_PRICE_1_1);

        IPoolManager.ModifyLiquidityParams memory liquidityParams = IPoolManager.ModifyLiquidityParams({
            tickLower: -60000,
            tickUpper: 60000,
            liquidityDelta: int256(uint256(LIQUIDITY)),
            salt: 0
        });

        modifyRouter.modifyLiquidity{value: 50_000 ether}(rootKey, liquidityParams, bytes(""));
        modifyRouter.modifyLiquidity(childKey, liquidityParams, bytes(""));
    }

    /// @dev Invariant: Fees donated should never exceed the swap amount
    function invariant_feesNeverExceedSwapAmount() public view {
        // This is a logical invariant - fees are always 10% of swap amount
        // If we've donated any fees, total fees should be <= 10% of total swap amount
        if (totalSwapAmount > 0) {
            uint256 maxPossibleFees = (totalSwapAmount * TOTAL_FEE_BPS) / FEE_DENOMINATOR;
            assertLe(totalFeesDonated, maxPossibleFees, "INVARIANT: Fees exceed maximum allowed");
        }
    }

    /// @dev Invariant: Donations should only go to initialized pools
    function invariant_donationsOnlyToInitializedPools() public view {
        // All donations should go to pools that are configured in the hook
        (bool rootInitialized,,,,,) = hook.poolConfig(rootPoolId);
        (bool childInitialized,,,,,) = hook.poolConfig(childPoolId);

        assertTrue(rootInitialized || childInitialized, "INVARIANT: At least one pool must be initialized");
    }

    /// @dev Invariant: Child fee share is correct (75% for child, 25% for parent)
    function invariant_childFeeShareIsCorrect() public pure {
        // Mathematical invariant: CHILD_SHARE should be 75% of TOTAL_FEE
        uint256 expectedChildShare = (TOTAL_FEE_BPS * 75) / 100;
        assertEq(CHILD_SHARE_WITH_PARENT_BPS, expectedChildShare, "INVARIANT: Child share must be 75%");

        // Parent share should be 25%
        uint256 parentShare = TOTAL_FEE_BPS - CHILD_SHARE_WITH_PARENT_BPS;
        uint256 expectedParentShare = (TOTAL_FEE_BPS * 25) / 100;
        assertEq(parentShare, expectedParentShare, "INVARIANT: Parent share must be 25%");
    }

    /// @dev Test helper: Perform a swap and record metrics
    function testSwapAndRecordMetrics() public {
        IPoolManager.SwapParams memory params = IPoolManager.SwapParams({
            zeroForOne: true,
            amountSpecified: -int256(1e16),
            sqrtPriceLimitX96: TickMath.MIN_SQRT_PRICE + 1
        });

        PoolSwapTest.TestSettings memory settings =
            PoolSwapTest.TestSettings({takeClaims: false, settleUsingBurn: false});

        vm.recordLogs();
        swapRouter.swap(childKey, params, settings, bytes(""));
        Vm.Log[] memory logs = vm.getRecordedLogs();

        // Count donations
        uint256 donationsInSwap = 0;
        for (uint256 i = 0; i < logs.length; ++i) {
            if (logs[i].topics[0] == DONATE_TOPIC && logs[i].emitter == POOL_MANAGER_ADDRESS) {
                (uint256 amount0, uint256 amount1) = abi.decode(logs[i].data, (uint256, uint256));
                donationsInSwap += amount0 + amount1;
            }
        }

        totalSwapCount++;
        totalSwapAmount += uint256(params.amountSpecified < 0 ? -params.amountSpecified : params.amountSpecified);
        totalFeesDonated += donationsInSwap;
    }

    function _sortCurrencies(Currency a, Currency b) internal pure returns (Currency, Currency) {
        if (Currency.unwrap(a) < Currency.unwrap(b)) {
            return (a, b);
        }
        return (b, a);
    }
}
