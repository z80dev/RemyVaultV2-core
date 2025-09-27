// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {BaseTest} from "./BaseTest.t.sol";

import {RemyVaultHook} from "../src/RemyVaultHook.sol";

import {PoolModifyLiquidityTest} from "@uniswap/v4-core/src/test/PoolModifyLiquidityTest.sol";
import {PoolSwapTest} from "@uniswap/v4-core/src/test/PoolSwapTest.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
import {Currency, CurrencyLibrary} from "@uniswap/v4-core/src/types/Currency.sol";
import {Hooks} from "@uniswap/v4-core/src/libraries/Hooks.sol";
import {BalanceDelta} from "@uniswap/v4-core/src/types/BalanceDelta.sol";
import {TransientStateLibrary} from "@uniswap/v4-core/src/libraries/TransientStateLibrary.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";

import {Vm} from "forge-std/Vm.sol";

import {MockERC20} from "solmate/src/test/utils/mocks/MockERC20.sol";

contract RemyVaultHookForkTest is BaseTest {
    using PoolIdLibrary for PoolKey;
    using TransientStateLibrary for IPoolManager;

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

    uint160 internal constant SQRT_PRICE_1_1 = 79228162514264337593543950336; // 2^96
    uint128 internal constant LIQUIDITY = 1e18;

    PoolModifyLiquidityTest internal modifyRouter;
    PoolSwapTest internal swapRouter;
    RemyVaultHook internal hook;

    MockERC20 internal sharedToken;
    MockERC20 internal altToken;

    Currency internal remyCurrency;
    Currency internal altCurrency;

    PoolKey internal rootKey;
    PoolKey internal childKey;
    PoolId internal rootPoolId;
    PoolId internal childPoolId;

    IPoolManager.ModifyLiquidityParams internal liquidityParams;

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
        deployCodeTo("RemyVaultHook.sol:RemyVaultHook", abi.encode(POOL_MANAGER, address(this)), HOOK_ADDRESS);
        hook = RemyVaultHook(HOOK_ADDRESS);
        assertEq(hook.owner(), address(this), "owner not configured");

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

        liquidityParams = IPoolManager.ModifyLiquidityParams({
            tickLower: -60000,
            tickUpper: 60000,
            liquidityDelta: int256(uint256(LIQUIDITY)),
            salt: 0
        });

        POOL_MANAGER.initialize(rootKey, SQRT_PRICE_1_1);
        POOL_MANAGER.initialize(childKey, SQRT_PRICE_1_1);

        modifyRouter.modifyLiquidity{value: 50_000 ether}(rootKey, liquidityParams, bytes(""));
        modifyRouter.modifyLiquidity(childKey, liquidityParams, bytes(""));
    }

    function testChildExactIn_FeesSplitWithParent() public {
        IPoolManager.SwapParams memory params = _swapParams(true, -int256(1e16));

        _assertChildSwap(params);
    }

    function testChildExactOut_FeesSplitWithParent() public {
        IPoolManager.SwapParams memory params = _swapParams(false, int256(1e16));

        _assertChildSwap(params);
    }

    function testRootExactIn_FeesStayWithPool() public {
        IPoolManager.SwapParams memory params = _swapParams(false, -int256(1e16));

        _assertRootSwap(params);
    }

    function testRootExactOut_FeesStayWithPool() public {
        IPoolManager.SwapParams memory params = _swapParams(true, int256(1e16));

        _assertRootSwap(params);
    }

    function testAddChild_WithParentUsingEth_Reverts() public {
        PoolKey memory invalidChild = PoolKey({
            currency0: remyCurrency,
            currency1: CurrencyLibrary.ADDRESS_ZERO,
            fee: 3000,
            tickSpacing: 60,
            hooks: IHooks(HOOK_ADDRESS)
        });

        vm.expectRevert(RemyVaultHook.ChildPoolCannotUseEth.selector);
        hook.addChild(invalidChild, true, rootKey);
    }

    function testAddChild_RootWithoutEth_Reverts() public {
        PoolKey memory invalidRoot = PoolKey({
            currency0: remyCurrency,
            currency1: altCurrency,
            fee: 3000,
            tickSpacing: 60,
            hooks: IHooks(HOOK_ADDRESS)
        });

        PoolKey memory emptyKey;
        vm.expectRevert(RemyVaultHook.RootPoolRequiresEth.selector);
        hook.addChild(invalidRoot, false, emptyKey);
    }

    function _assertChildSwap(IPoolManager.SwapParams memory params) internal {
        (bool initialized, bool hasParent,, Currency sharedCurrency, bool sharedIsChild0, bool sharedIsParent0) =
            hook.poolConfig(childPoolId);
        assertTrue(initialized, "child not configured");
        assertTrue(hasParent, "child missing parent");

        vm.recordLogs();
        BalanceDelta swapDelta = _executeSwap(childKey, params);
        Vm.Log[] memory logs = vm.getRecordedLogs();

        bool exactIn = params.amountSpecified < 0;
        bool specifiedIsC0 = params.zeroForOne ? exactIn : !exactIn;
        bool sharedIsSpecified = sharedIsChild0 == specifiedIsC0;
        uint256 basisAmount = _feeBasis(sharedIsSpecified, specifiedIsC0, params, swapDelta);
        uint256 totalFee;
        if (sharedIsSpecified) {
            totalFee = (basisAmount * TOTAL_FEE_BPS) / FEE_DENOMINATOR;
        } else if (params.amountSpecified < 0) {
            totalFee = (basisAmount * TOTAL_FEE_BPS) / (FEE_DENOMINATOR - TOTAL_FEE_BPS);
        } else {
            totalFee = (basisAmount * TOTAL_FEE_BPS) / (FEE_DENOMINATOR + TOTAL_FEE_BPS);
        }
        uint256 expectedChildDonation = totalFee * CHILD_SHARE_WITH_PARENT_BPS / TOTAL_FEE_BPS;
        uint256 expectedParentDonation = totalFee - expectedChildDonation;

        (bool childFound, uint256 childAmount0, uint256 childAmount1) = _findDonation(logs, childPoolId);
        (bool parentFound, uint256 parentAmount0, uint256 parentAmount1) = _findDonation(logs, rootPoolId);

        assertTrue(childFound, "child donation missing");
        assertTrue(parentFound, "parent donation missing");

        uint256 childDonation = sharedIsChild0 ? childAmount0 : childAmount1;
        uint256 childOther = sharedIsChild0 ? childAmount1 : childAmount0;
        uint256 parentDonation = sharedIsParent0 ? parentAmount0 : parentAmount1;
        uint256 parentOther = sharedIsParent0 ? parentAmount1 : parentAmount0;

        assertEq(childDonation, expectedChildDonation, "child donation mismatch");
        assertEq(childOther, 0, "unexpected child donation for other token");
        assertEq(parentDonation, expectedParentDonation, "parent donation mismatch");
        assertEq(parentOther, 0, "unexpected parent donation for other token");
        assertEq(POOL_MANAGER.currencyDelta(address(hook), sharedCurrency), 0, "hook delta not cleared");
    }

    function _assertRootSwap(IPoolManager.SwapParams memory params) internal {
        (bool initialized, bool hasParent,, Currency sharedCurrency, bool sharedIsCurrency0, bool sharedIsParent0) =
            hook.poolConfig(rootPoolId);
        assertTrue(initialized, "root not configured");
        assertFalse(hasParent, "root should not have parent");
        if (sharedIsParent0) {
            // unreachable but silences unused warning
        }

        vm.recordLogs();
        BalanceDelta swapDelta = _executeSwap(rootKey, params);
        Vm.Log[] memory logs = vm.getRecordedLogs();

        bool exactIn = params.amountSpecified < 0;
        bool specifiedIsC0 = params.zeroForOne ? exactIn : !exactIn;
        bool sharedIsSpecified = sharedIsCurrency0 == specifiedIsC0;

        uint256 basisAmount = _feeBasis(sharedIsSpecified, specifiedIsC0, params, swapDelta);
        uint256 totalFee = sharedIsSpecified
            ? (basisAmount * TOTAL_FEE_BPS) / FEE_DENOMINATOR
            : (basisAmount * TOTAL_FEE_BPS) / (FEE_DENOMINATOR - TOTAL_FEE_BPS);

        (bool rootFound, uint256 amount0, uint256 amount1) = _findDonation(logs, rootPoolId);
        assertTrue(rootFound, "root donation missing");

        uint256 donation = sharedIsCurrency0 ? amount0 : amount1;
        uint256 other = sharedIsCurrency0 ? amount1 : amount0;

        assertEq(donation, totalFee, "root donation mismatch");
        assertEq(other, 0, "unexpected donation for non-shared token");
        assertEq(POOL_MANAGER.currencyDelta(address(hook), sharedCurrency), 0, "hook delta not cleared");
    }

    function _executeSwap(PoolKey memory key, IPoolManager.SwapParams memory params) internal returns (BalanceDelta) {
        PoolSwapTest.TestSettings memory settings =
            PoolSwapTest.TestSettings({takeClaims: false, settleUsingBurn: false});
        bool usesNative = Currency.unwrap(key.currency0) == address(0) || Currency.unwrap(key.currency1) == address(0);
        uint256 msgValue = usesNative ? 1_000 ether : 0;
        return swapRouter.swap{value: msgValue}(key, params, settings, bytes(""));
    }

    function _swapParams(bool zeroForOne, int256 amountSpecified)
        internal
        pure
        returns (IPoolManager.SwapParams memory)
    {
        uint160 limit = zeroForOne ? TickMath.MIN_SQRT_PRICE + 1 : TickMath.MAX_SQRT_PRICE - 1;
        return IPoolManager.SwapParams({
            zeroForOne: zeroForOne,
            amountSpecified: amountSpecified,
            sqrtPriceLimitX96: limit
        });
    }

    function _feeBasis(
        bool sharedIsSpecified,
        bool specifiedIsC0,
        IPoolManager.SwapParams memory params,
        BalanceDelta delta
    ) internal pure returns (uint256) {
        if (sharedIsSpecified) {
            return _abs(params.amountSpecified);
        }

        int256 unspecifiedSigned = specifiedIsC0 ? int256(int128(delta.amount1())) : int256(int128(delta.amount0()));
        return _abs(unspecifiedSigned);
    }

    function _findDonation(Vm.Log[] memory logs, PoolId poolId)
        internal
        pure
        returns (bool found, uint256 amount0, uint256 amount1)
    {
        bytes32 poolIdTopic = PoolId.unwrap(poolId);
        for (uint256 i = 0; i < logs.length; ++i) {
            Vm.Log memory entry = logs[i];
            if (entry.emitter != POOL_MANAGER_ADDRESS) continue;
            if (entry.topics.length < 2) continue;
            if (entry.topics[0] != DONATE_TOPIC) continue;
            if (entry.topics[1] != poolIdTopic) continue;
            require(!found, "duplicate donation log");
            (amount0, amount1) = abi.decode(entry.data, (uint256, uint256));
            found = true;
        }
    }

    function _abs(int256 value) internal pure returns (uint256) {
        return uint256(value >= 0 ? value : -value);
    }

    function _sortCurrencies(Currency a, Currency b) internal pure returns (Currency, Currency) {
        if (Currency.unwrap(a) < Currency.unwrap(b)) {
            return (a, b);
        }
        return (b, a);
    }
}
