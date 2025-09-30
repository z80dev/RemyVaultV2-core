// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {BaseHook} from "@uniswap/v4-periphery/src/utils/BaseHook.sol";
import {Hooks} from "@uniswap/v4-core/src/libraries/Hooks.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
import {Currency, CurrencyLibrary} from "@uniswap/v4-core/src/types/Currency.sol";
import {BalanceDelta, BalanceDeltaLibrary} from "@uniswap/v4-core/src/types/BalanceDelta.sol";
import {
    BeforeSwapDelta, BeforeSwapDeltaLibrary, toBeforeSwapDelta
} from "@uniswap/v4-core/src/types/BeforeSwapDelta.sol";
import {StateLibrary} from "@uniswap/v4-core/src/libraries/StateLibrary.sol";

contract RemyVaultHook is BaseHook {
    using PoolIdLibrary for PoolKey;
    using CurrencyLibrary for Currency;
    using BalanceDeltaLibrary for BalanceDelta;
    using StateLibrary for IPoolManager;

    uint16 internal constant FEE_DENOMINATOR = 10_000;
    uint16 internal constant TOTAL_FEE_BPS = 1_000; // 10%
    uint16 internal constant CHILD_SHARE_WITH_PARENT_BPS = 750; // 7.5%

    error NotOwner();
    error InvalidOwner();
    error HookMismatch();
    error RootPoolRequiresEth();
    error ChildPoolCannotUseEth();
    error ParentNotConfigured();
    error MustShareExactlyOneToken();
    error SharedTokenCannotBeEth();

    struct PoolConfig {
        bool initialized;
        bool hasParent;
        PoolKey parentKey;
        Currency sharedCurrency;
        bool sharedIsChild0;
        bool sharedIsParent0;
    }

    address public owner;

    mapping(PoolId => PoolConfig) public poolConfig;

    event OwnershipTransferred(address indexed previousOwner, address indexed newOwner);
    event ChildConfigured(PoolId indexed childPool, PoolId indexed parentPool, Currency sharedCurrency, bool hasParent);

    constructor(IPoolManager manager, address owner_) BaseHook(manager) {
        if (owner_ == address(0)) revert InvalidOwner();
        owner = owner_;
        emit OwnershipTransferred(address(0), owner_);
    }

    modifier onlyOwner() {
        if (msg.sender != owner) revert NotOwner();
        _;
    }

    function transferOwnership(address newOwner) external onlyOwner {
        if (newOwner == address(0)) revert InvalidOwner();
        emit OwnershipTransferred(owner, newOwner);
        owner = newOwner;
    }

    function addChild(PoolKey calldata childKey, bool hasParent, PoolKey calldata parentKey) external onlyOwner {
        if (address(childKey.hooks) != address(this)) revert HookMismatch();

        PoolConfig memory config;
        config.initialized = true;
        config.hasParent = hasParent;

        if (hasParent) {
            if (address(parentKey.hooks) != address(this)) revert HookMismatch();
            if (childKey.currency0.isAddressZero() || childKey.currency1.isAddressZero()) {
                revert ChildPoolCannotUseEth();
            }

            PoolId parentId = parentKey.toId();
            PoolConfig memory parentConfig = poolConfig[parentId];
            if (!parentConfig.initialized) revert ParentNotConfigured();

            (Currency sharedCurrency, bool sharedIsChild0, bool sharedIsParent0) = _sharedToken(childKey, parentKey);
            if (sharedCurrency.isAddressZero()) revert SharedTokenCannotBeEth();
            config.parentKey = parentKey;
            config.sharedCurrency = sharedCurrency;
            config.sharedIsChild0 = sharedIsChild0;
            config.sharedIsParent0 = sharedIsParent0;
        } else {
            bool childHasEth0 = childKey.currency0.isAddressZero();
            bool childHasEth1 = childKey.currency1.isAddressZero();
            if (childHasEth0 == childHasEth1) revert RootPoolRequiresEth();

            config.sharedCurrency = childHasEth0 ? childKey.currency1 : childKey.currency0;
            config.sharedIsChild0 = !childHasEth0;
        }

        PoolId childId = childKey.toId();
        poolConfig[childId] = config;

        PoolId parentPoolId = hasParent ? parentKey.toId() : PoolId.wrap(bytes32(0));
        emit ChildConfigured(childId, parentPoolId, config.sharedCurrency, hasParent);
    }

    function getHookPermissions() public pure override returns (Hooks.Permissions memory permissions) {
        permissions.beforeSwap = true;
        permissions.beforeSwapReturnDelta = true;
        permissions.afterSwap = true;
        permissions.afterSwapReturnDelta = true;
    }

    function _beforeSwap(address, PoolKey calldata key, IPoolManager.SwapParams calldata params, bytes calldata)
        internal
        override
        returns (bytes4, BeforeSwapDelta, uint24)
    {
        PoolConfig memory config = poolConfig[key.toId()];
        if (!config.initialized) {
            return (this.beforeSwap.selector, BeforeSwapDeltaLibrary.ZERO_DELTA, 0);
        }

        bool exactIn = params.amountSpecified < 0;
        bool specifiedIsC0 = _specifiedIsCurrency0(params.zeroForOne, exactIn);
        bool sharedIsSpecified = (config.sharedIsChild0 == specifiedIsC0);

        if (!sharedIsSpecified) {
            return (this.beforeSwap.selector, BeforeSwapDeltaLibrary.ZERO_DELTA, 0);
        }

        uint256 specifiedAmount = _abs(params.amountSpecified);
        uint256 totalFee = (specifiedAmount * TOTAL_FEE_BPS) / FEE_DENOMINATOR;
        if (totalFee == 0) {
            return (this.beforeSwap.selector, BeforeSwapDeltaLibrary.ZERO_DELTA, 0);
        }

        (uint256 childFee, uint256 parentFee) = _splitFees(totalFee, config.hasParent);

        uint256 actualFee = 0;
        if (childFee > 0 && _hasLiquidity(key)) {
            poolManager.donate(
                key, config.sharedIsChild0 ? childFee : 0, config.sharedIsChild0 ? 0 : childFee, bytes("")
            );
            actualFee += childFee;
        }

        if (config.hasParent && parentFee > 0 && _hasLiquidity(config.parentKey)) {
            poolManager.donate(
                config.parentKey,
                config.sharedIsParent0 ? parentFee : 0,
                config.sharedIsParent0 ? 0 : parentFee,
                bytes("")
            );
            actualFee += parentFee;
        }

        if (actualFee == 0) {
            return (this.beforeSwap.selector, BeforeSwapDeltaLibrary.ZERO_DELTA, 0);
        }

        BeforeSwapDelta delta = toBeforeSwapDelta(int128(int256(actualFee)), int128(0));
        return (this.beforeSwap.selector, delta, 0);
    }

    function _afterSwap(
        address,
        PoolKey calldata key,
        IPoolManager.SwapParams calldata params,
        BalanceDelta delta,
        bytes calldata
    ) internal override returns (bytes4, int128) {
        PoolConfig memory config = poolConfig[key.toId()];
        if (!config.initialized) {
            return (this.afterSwap.selector, int128(0));
        }

        bool exactIn = params.amountSpecified < 0;
        bool specifiedIsC0 = _specifiedIsCurrency0(params.zeroForOne, exactIn);
        bool sharedIsSpecified = (config.sharedIsChild0 == specifiedIsC0);

        if (sharedIsSpecified) {
            return (this.afterSwap.selector, int128(0));
        }

        int128 unspecifiedSigned = specifiedIsC0 ? delta.amount1() : delta.amount0();
        uint256 unspecifiedAmount = _abs(int256(unspecifiedSigned));
        uint256 totalFee = (unspecifiedAmount * TOTAL_FEE_BPS) / FEE_DENOMINATOR;
        if (totalFee == 0) {
            return (this.afterSwap.selector, int128(0));
        }

        (uint256 childFee, uint256 parentFee) = _splitFees(totalFee, config.hasParent);

        uint256 actualFee = 0;
        if (childFee > 0 && _hasLiquidity(key)) {
            poolManager.donate(
                key, config.sharedIsChild0 ? childFee : 0, config.sharedIsChild0 ? 0 : childFee, bytes("")
            );
            actualFee += childFee;
        }

        if (config.hasParent && parentFee > 0 && _hasLiquidity(config.parentKey)) {
            poolManager.donate(
                config.parentKey,
                config.sharedIsParent0 ? parentFee : 0,
                config.sharedIsParent0 ? 0 : parentFee,
                bytes("")
            );
            actualFee += parentFee;
        }

        return (this.afterSwap.selector, int128(int256(actualFee)));
    }

    function _hasLiquidity(PoolKey memory key) private view returns (bool) {
        uint128 liquidity = poolManager.getLiquidity(key.toId());
        return liquidity > 0;
    }

    function _sharedToken(PoolKey calldata childKey, PoolKey calldata parentKey)
        private
        pure
        returns (Currency shared, bool sharedIsChild0, bool sharedIsParent0)
    {
        uint8 matches;

        if (childKey.currency0 == parentKey.currency0) {
            shared = childKey.currency0;
            sharedIsChild0 = true;
            sharedIsParent0 = true;
            matches++;
        }

        if (childKey.currency0 == parentKey.currency1) {
            shared = childKey.currency0;
            sharedIsChild0 = true;
            sharedIsParent0 = false;
            matches++;
        }

        if (childKey.currency1 == parentKey.currency0) {
            shared = childKey.currency1;
            sharedIsChild0 = false;
            sharedIsParent0 = true;
            matches++;
        }

        if (childKey.currency1 == parentKey.currency1) {
            shared = childKey.currency1;
            sharedIsChild0 = false;
            sharedIsParent0 = false;
            matches++;
        }

        if (matches != 1) revert MustShareExactlyOneToken();
    }

    function _splitFees(uint256 totalFee, bool hasParent) private pure returns (uint256 childFee, uint256 parentFee) {
        if (hasParent) {
            childFee = (totalFee * CHILD_SHARE_WITH_PARENT_BPS) / TOTAL_FEE_BPS;
            parentFee = totalFee - childFee;
        } else {
            childFee = totalFee;
        }
    }

    function _specifiedIsCurrency0(bool zeroForOne, bool exactIn) private pure returns (bool) {
        return zeroForOne ? exactIn : !exactIn;
    }

    function _abs(int256 value) private pure returns (uint256) {
        if (value >= 0) {
            return uint256(value);
        }
        unchecked {
            return uint256(uint256(~value) + 1);
        }
    }
}
