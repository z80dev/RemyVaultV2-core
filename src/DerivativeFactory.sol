// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Ownable} from "solady/auth/Ownable.sol";

import {MinterRemyVault} from "./MinterRemyVault.sol";
import {RemyVaultFactory} from "./RemyVaultFactory.sol";
import {RemyVaultHook} from "./RemyVaultHook.sol";
import {RemyVaultNFT} from "./RemyVaultNFT.sol";
import {RemyVault} from "./RemyVault.sol";

import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {BalanceDelta, BalanceDeltaLibrary} from "@uniswap/v4-core/src/types/BalanceDelta.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {IUnlockCallback} from "@uniswap/v4-core/src/interfaces/callback/IUnlockCallback.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
import {IERC20Minimal} from "@uniswap/v4-core/src/interfaces/external/IERC20Minimal.sol";

contract DerivativeFactory is Ownable, IUnlockCallback {
    using PoolIdLibrary for PoolKey;
    using BalanceDeltaLibrary for BalanceDelta;

    struct DerivativeParams {
        address parentVault;
        string nftName;
        string nftSymbol;
        string nftBaseUri;
        address nftOwner;
        address initialMinter;
        string vaultName;
        string vaultSymbol;
        uint24 fee;
        int24 tickSpacing;
        uint160 sqrtPriceX96;
        uint256 maxSupply;
        int24 tickLower;
        int24 tickUpper;
        uint128 liquidity;
        uint256 parentTokenContribution;
        address derivativeTokenRecipient;
        address parentTokenRefundRecipient;
    }

    struct RootPool {
        bool exists;
        PoolKey key;
        PoolId id;
    }

    struct DerivativeInfo {
        address nft;
        address parentVault;
        PoolId poolId;
    }

    struct ModifyLiquidityCallbackData {
        PoolKey key;
        IPoolManager.ModifyLiquidityParams params;
    }

    event RootPoolRegistered(
        address indexed parentVault, PoolId indexed poolId, uint24 fee, int24 tickSpacing, uint160 sqrtPriceX96
    );
    event ParentVaultRegistered(address indexed collection, address indexed parentVault, PoolId indexed poolId);
    event DerivativeCreated(
        address indexed parentCollection,
        address indexed parentVault,
        address indexed derivativeNft,
        address derivativeVault,
        PoolId childPoolId,
        uint24 fee,
        int24 tickSpacing,
        uint160 sqrtPriceX96
    );

    error HookOwnershipMissing();
    error ZeroAddress();
    error ParentVaultNotFromFactory(address parentVault);
    error ParentVaultAlreadyInitialized(address parentVault);
    error ParentVaultNotRegistered(address parentVault);
    error InvalidSqrtPrice();
    error InvalidTickRange();
    error ZeroLiquidity();
    error UnsupportedCurrency();
    error CallbackNotPoolManager();
    error TransferFailed();

    RemyVaultFactory public immutable VAULT_FACTORY;
    RemyVaultHook public immutable HOOK;
    IPoolManager public immutable POOL_MANAGER;

    mapping(address => RootPool) private _rootPools;
    mapping(address => DerivativeInfo) public derivativeForVault;
    mapping(address => address) public vaultForNft;

    constructor(RemyVaultFactory vaultFactory_, RemyVaultHook hook_, address owner_) {
        if (address(vaultFactory_) == address(0) || address(hook_) == address(0) || owner_ == address(0)) {
            revert ZeroAddress();
        }
        if (hook_.owner() != owner_) revert HookOwnershipMissing();
        VAULT_FACTORY = vaultFactory_;
        HOOK = hook_;
        POOL_MANAGER = hook_.poolManager();
        _initializeOwner(owner_);
    }

    function registerRootPool(address parentVault, uint24 fee, int24 tickSpacing, uint160 sqrtPriceX96)
        external
        onlyOwner
        requiresHookOwnership
        returns (PoolId poolId)
    {
        poolId = _registerRootPool(parentVault, fee, tickSpacing, sqrtPriceX96);
    }

    function createVaultForCollection(
        address collection,
        string calldata vaultName,
        string calldata vaultSymbol,
        uint24 fee,
        int24 tickSpacing,
        uint160 sqrtPriceX96
    ) external onlyOwner requiresHookOwnership returns (address vault, PoolId poolId) {
        vault = VAULT_FACTORY.deployVault(collection, vaultName, vaultSymbol);
        poolId = _registerRootPool(vault, fee, tickSpacing, sqrtPriceX96);
        emit ParentVaultRegistered(collection, vault, poolId);
    }

    function createDerivative(DerivativeParams calldata params)
        external
        onlyOwner
        requiresHookOwnership
        returns (address nft, address vault, PoolId childPoolId)
    {
        RootPool storage root = _rootPools[params.parentVault];
        if (!root.exists) revert ParentVaultNotRegistered(params.parentVault);
        if (params.sqrtPriceX96 == 0) revert InvalidSqrtPrice();
        if (params.tickLower >= params.tickUpper) revert InvalidTickRange();
        if (params.liquidity == 0) revert ZeroLiquidity();

        RemyVaultNFT derivativeNft =
            new RemyVaultNFT(params.nftName, params.nftSymbol, params.nftBaseUri, address(this));

        nft = address(derivativeNft);
        vault = VAULT_FACTORY.deployDerivativeVault(nft, params.vaultName, params.vaultSymbol, params.maxSupply);

        derivativeNft.setMinter(vault, true);
        if (params.initialMinter != address(0)) {
            derivativeNft.setMinter(params.initialMinter, true);
        }
        if (params.nftOwner != address(0) && params.nftOwner != address(this)) {
            derivativeNft.transferOwnership(params.nftOwner);
        }

        (PoolKey memory childKey, bool derivativeIsCurrency0) =
            _buildPoolKeyWithOrientation(vault, params.parentVault, params.fee, params.tickSpacing);

        (uint160 normalizedSqrtPrice, int24 normalizedLower, int24 normalizedUpper) =
            _normalizePriceAndTicks(derivativeIsCurrency0, params.sqrtPriceX96, params.tickLower, params.tickUpper);

        HOOK.addChild(childKey, true, root.key);
        POOL_MANAGER.initialize(childKey, normalizedSqrtPrice);

        MinterRemyVault derivativeToken = MinterRemyVault(vault);
        RemyVault parentToken = RemyVault(params.parentVault);

        if (params.parentTokenContribution != 0) {
            parentToken.transferFrom(msg.sender, address(this), params.parentTokenContribution);
        }

        _addInitialLiquidity(childKey, normalizedLower, normalizedUpper, params.liquidity);

        childPoolId = childKey.toId();
        derivativeForVault[vault] = DerivativeInfo({nft: nft, parentVault: params.parentVault, poolId: childPoolId});
        vaultForNft[nft] = vault;

        uint256 parentBalanceAfter = parentToken.balanceOf(address(this));
        uint256 derivativeBalanceAfter = derivativeToken.balanceOf(address(this));

        if (parentBalanceAfter != 0) {
            address refundRecipient =
                params.parentTokenRefundRecipient == address(0) ? msg.sender : params.parentTokenRefundRecipient;
            parentToken.transfer(refundRecipient, parentBalanceAfter);
        }

        if (derivativeBalanceAfter != 0) {
            address derivativeRecipient = params.derivativeTokenRecipient;
            if (derivativeRecipient == address(0)) {
                derivativeRecipient = params.nftOwner != address(0) ? params.nftOwner : msg.sender;
            }
            derivativeToken.transfer(derivativeRecipient, derivativeBalanceAfter);
        }

        address parentCollection = RemyVault(params.parentVault).erc721();

        emit DerivativeCreated(
            parentCollection,
            params.parentVault,
            nft,
            vault,
            childPoolId,
            params.fee,
            params.tickSpacing,
            normalizedSqrtPrice
        );
    }

    function rootPool(address parentVault) external view returns (PoolKey memory key, PoolId poolId) {
        RootPool storage root = _rootPools[parentVault];
        if (!root.exists) revert ParentVaultNotRegistered(parentVault);
        key = root.key;
        poolId = root.id;
    }

    modifier requiresHookOwnership() {
        if (HOOK.owner() != address(this)) revert HookOwnershipMissing();
        _;
    }

    function _registerRootPool(address parentVault, uint24 fee, int24 tickSpacing, uint160 sqrtPriceX96)
        private
        returns (PoolId poolId)
    {
        if (!VAULT_FACTORY.isVault(parentVault)) revert ParentVaultNotFromFactory(parentVault);
        RootPool storage root = _rootPools[parentVault];
        if (root.exists) revert ParentVaultAlreadyInitialized(parentVault);
        if (sqrtPriceX96 == 0) revert InvalidSqrtPrice();

        PoolKey memory key = _buildPoolKey(address(0), parentVault, fee, tickSpacing);
        PoolKey memory emptyKey;
        HOOK.addChild(key, false, emptyKey);
        POOL_MANAGER.initialize(key, sqrtPriceX96);

        poolId = key.toId();
        root.exists = true;
        root.key = key;
        root.id = poolId;

        emit RootPoolRegistered(parentVault, poolId, fee, tickSpacing, sqrtPriceX96);
    }

    function _buildPoolKey(address tokenA, address tokenB, uint24 fee, int24 tickSpacing)
        private
        view
        returns (PoolKey memory key)
    {
        (key,) = _buildPoolKeyWithOrientation(tokenA, tokenB, fee, tickSpacing);
    }

    function _buildPoolKeyWithOrientation(address tokenA, address tokenB, uint24 fee, int24 tickSpacing)
        private
        view
        returns (PoolKey memory key, bool tokenAIsCurrency0)
    {
        Currency currencyA = Currency.wrap(tokenA);
        Currency currencyB = Currency.wrap(tokenB);
        if (Currency.unwrap(currencyA) < Currency.unwrap(currencyB)) {
            tokenAIsCurrency0 = true;
            key = PoolKey({
                currency0: currencyA,
                currency1: currencyB,
                fee: fee,
                tickSpacing: tickSpacing,
                hooks: IHooks(address(HOOK))
            });
        } else {
            tokenAIsCurrency0 = false;
            key = PoolKey({
                currency0: currencyB,
                currency1: currencyA,
                fee: fee,
                tickSpacing: tickSpacing,
                hooks: IHooks(address(HOOK))
            });
        }
    }

    function _normalizePriceAndTicks(bool derivativeIsCurrency0, uint160 sqrtPriceX96, int24 tickLower, int24 tickUpper)
        private
        pure
        returns (uint160 normalizedSqrtPriceX96, int24 normalizedLower, int24 normalizedUpper)
    {
        if (derivativeIsCurrency0) {
            return (sqrtPriceX96, tickLower, tickUpper);
        }

        // Flip the orientation when the derivative token is currency1.
        uint256 q96Squared = uint256(1) << 192;
        normalizedSqrtPriceX96 = uint160(q96Squared / sqrtPriceX96);
        normalizedLower = -tickUpper;
        normalizedUpper = -tickLower;
    }

    function _addInitialLiquidity(PoolKey memory key, int24 tickLower, int24 tickUpper, uint128 liquidity)
        private
        returns (BalanceDelta delta)
    {
        ModifyLiquidityCallbackData memory data = ModifyLiquidityCallbackData({
            key: key,
            params: IPoolManager.ModifyLiquidityParams({
                tickLower: tickLower,
                tickUpper: tickUpper,
                liquidityDelta: int256(uint256(liquidity)),
                salt: bytes32(0)
            })
        });

        delta = abi.decode(POOL_MANAGER.unlock(abi.encode(data)), (BalanceDelta));
    }

    function unlockCallback(bytes calldata rawData) external override returns (bytes memory) {
        if (msg.sender != address(POOL_MANAGER)) revert CallbackNotPoolManager();

        ModifyLiquidityCallbackData memory data = abi.decode(rawData, (ModifyLiquidityCallbackData));
        (BalanceDelta delta,) = POOL_MANAGER.modifyLiquidity(data.key, data.params, bytes(""));

        _settleCurrencyDelta(data.key.currency0, delta.amount0());
        _settleCurrencyDelta(data.key.currency1, delta.amount1());

        return abi.encode(delta);
    }

    function _settleCurrencyDelta(Currency currency, int128 amountDelta) private {
        if (amountDelta == 0) return;

        address token = Currency.unwrap(currency);
        if (token == address(0)) revert UnsupportedCurrency();

        int256 amount = int256(amountDelta);
        if (amount < 0) {
            uint256 debt = uint256(-amount);
            POOL_MANAGER.sync(currency);
            bool success = IERC20Minimal(token).transfer(address(POOL_MANAGER), debt);
            if (!success) revert TransferFailed();
            POOL_MANAGER.settle();
        } else {
            POOL_MANAGER.take(currency, address(this), uint256(amount));
        }
    }
}
