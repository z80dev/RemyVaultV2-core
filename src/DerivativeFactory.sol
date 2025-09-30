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
import {StateLibrary} from "@uniswap/v4-core/src/libraries/StateLibrary.sol";
import {LPFeeLibrary} from "@uniswap/v4-core/src/libraries/LPFeeLibrary.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {FullMath} from "@uniswap/v4-core/src/libraries/FullMath.sol";
import {FixedPoint96} from "@uniswap/v4-core/src/libraries/FixedPoint96.sol";
import {IERC20Minimal} from "@uniswap/v4-core/src/interfaces/external/IERC20Minimal.sol";

contract DerivativeFactory is Ownable, IUnlockCallback {
    using PoolIdLibrary for PoolKey;
    using BalanceDeltaLibrary for BalanceDelta;
    using StateLibrary for IPoolManager;
    using LPFeeLibrary for uint24;

    struct DerivativeParams {
        address parentCollection;
        string nftName;
        string nftSymbol;
        string nftBaseUri;
        address nftOwner;
        address initialMinter;
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
        bytes32 salt;
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
    error ParentCollectionHasNoVault(address collection);
    error ParentCollectionHasNoPool(address collection, address vault);
    error InvalidSqrtPrice();
    error InvalidTickRange();
    error ZeroLiquidity();
    error UnsupportedCurrency();
    error CallbackNotPoolManager();
    error TransferFailed();
    error DerivativeVaultMustBeToken1(address derivativeVault, address parentVault);

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

    function createVaultForCollection(address collection, int24 tickSpacing, uint160 sqrtPriceX96)
        external
        onlyOwner
        requiresHookOwnership
        returns (address vault, PoolId poolId)
    {
        vault = VAULT_FACTORY.deployVault(collection);

        // Initialize the root pool with dynamic fee flag
        if (sqrtPriceX96 == 0) revert InvalidSqrtPrice();
        uint24 fee = LPFeeLibrary.DYNAMIC_FEE_FLAG;
        PoolKey memory key = _buildPoolKey(address(0), vault, fee, tickSpacing);
        PoolKey memory emptyKey;
        HOOK.addChild(key, false, emptyKey);
        POOL_MANAGER.initialize(key, sqrtPriceX96);

        // Cache the root pool
        poolId = key.toId();
        RootPool storage root = _rootPools[vault];
        root.exists = true;
        root.key = key;
        root.id = poolId;

        emit RootPoolRegistered(vault, poolId, fee, tickSpacing, sqrtPriceX96);
        emit ParentVaultRegistered(collection, vault, poolId);
    }

    function createDerivative(DerivativeParams calldata params)
        external
        returns (address nft, address vault, PoolId childPoolId)
    {
        // Look up the RemyVault for the parent collection
        address parentVault = VAULT_FACTORY.vaultFor(params.parentCollection);
        if (parentVault == address(0)) revert ParentCollectionHasNoVault(params.parentCollection);

        // Get or discover the root pool for this parent vault
        RootPool storage root = _rootPools[parentVault];
        if (!root.exists) {
            // Try to discover an existing root pool
            _discoverAndCacheRootPool(parentVault, params.fee, params.tickSpacing);
            // Check again after discovery attempt
            if (!root.exists) revert ParentCollectionHasNoPool(params.parentCollection, parentVault);
        }

        if (params.sqrtPriceX96 == 0) revert InvalidSqrtPrice();
        if (params.tickLower >= params.tickUpper) revert InvalidTickRange();
        if (params.liquidity == 0) revert ZeroLiquidity();

        RemyVaultNFT derivativeNft =
            new RemyVaultNFT(params.nftName, params.nftSymbol, params.nftBaseUri, address(this));

        nft = address(derivativeNft);
        vault = VAULT_FACTORY.deployDerivativeVault(nft, params.maxSupply, params.salt);

        // Enforce that derivative vault address > parent vault address (derivative will be token1)
        if (vault <= parentVault) {
            revert DerivativeVaultMustBeToken1(vault, parentVault);
        }

        derivativeNft.setMinter(vault, true);
        if (params.initialMinter != address(0)) {
            derivativeNft.setMinter(params.initialMinter, true);
        }
        if (params.nftOwner != address(0) && params.nftOwner != address(this)) {
            derivativeNft.transferOwnership(params.nftOwner);
        }

        (PoolKey memory childKey, bool derivativeIsCurrency0) =
            _buildPoolKeyWithOrientation(vault, parentVault, params.fee, params.tickSpacing);

        (uint160 normalizedSqrtPrice, int24 normalizedLower, int24 normalizedUpper) =
            _normalizePriceAndTicks(derivativeIsCurrency0, params.sqrtPriceX96, params.tickLower, params.tickUpper);

        HOOK.addChild(childKey, true, root.key);
        POOL_MANAGER.initialize(childKey, normalizedSqrtPrice);

        MinterRemyVault derivativeToken = MinterRemyVault(vault);
        RemyVault parentToken = RemyVault(parentVault);

        if (params.parentTokenContribution != 0) {
            parentToken.transferFrom(msg.sender, address(this), params.parentTokenContribution);
        }

        // Use the requested liquidity amount from params
        _addInitialLiquidity(childKey, normalizedLower, normalizedUpper, params.liquidity);

        childPoolId = childKey.toId();
        derivativeForVault[vault] = DerivativeInfo({nft: nft, parentVault: parentVault, poolId: childPoolId});
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

        emit DerivativeCreated(
            params.parentCollection,
            parentVault,
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

    /// @notice Compute the derivative vault address for the given parameters without deploying
    /// @param nftAddress The address of the derivative NFT collection
    /// @param maxSupply The maximum supply of derivative NFTs
    /// @param salt The salt for CREATE2 deployment
    /// @return The computed address of the derivative vault
    function computeDerivativeAddress(address nftAddress, uint256 maxSupply, bytes32 salt)
        external
        view
        returns (address)
    {
        return VAULT_FACTORY.computeDerivativeAddress(nftAddress, maxSupply, salt);
    }

    modifier requiresHookOwnership() {
        if (HOOK.owner() != address(this)) revert HookOwnershipMissing();
        _;
    }

    function _discoverAndCacheRootPool(address parentVault, uint24 hintFee, int24 hintTickSpacing) private {
        if (!VAULT_FACTORY.isVault(parentVault)) revert ParentVaultNotFromFactory(parentVault);

        // Always use the dynamic fee flag for permissionless pools
        uint24 fee = LPFeeLibrary.DYNAMIC_FEE_FLAG;

        // Try the hinted tick spacing first (from derivative params)
        if (_tryDiscoverPool(parentVault, fee, hintTickSpacing)) return;

        // Try common tick spacings
        int24[3] memory tickSpacings = [int24(10), int24(60), int24(200)];

        for (uint256 i = 0; i < tickSpacings.length; i++) {
            // Skip if we already tried this tick spacing
            if (tickSpacings[i] == hintTickSpacing) continue;
            if (_tryDiscoverPool(parentVault, fee, tickSpacings[i])) return;
        }
    }

    function _tryDiscoverPool(address parentVault, uint24 fee, int24 tickSpacing) private returns (bool) {
        PoolKey memory key = _buildPoolKey(address(0), parentVault, fee, tickSpacing);
        PoolId poolId = key.toId();

        // Check if pool is initialized (sqrtPrice != 0)
        (uint160 sqrtPriceX96,,,) = POOL_MANAGER.getSlot0(poolId);
        if (sqrtPriceX96 == 0) return false;

        // Verify the hook matches
        if (address(key.hooks) != address(HOOK)) return false;

        // Cache the discovered pool
        RootPool storage root = _rootPools[parentVault];
        root.exists = true;
        root.key = key;
        root.id = poolId;

        return true;
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
        // Use the provided price and ticks as-is
        // The caller should calculate these based on actual pool token ordering
        return (sqrtPriceX96, tickLower, tickUpper);
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

    function _calculateLiquidityForAmount(
        bool tokenIsCurrency0,
        uint160 sqrtPriceX96,
        int24 tickLower,
        int24 tickUpper,
        uint256 amount
    ) private pure returns (uint128) {
        uint160 sqrtRatioAX96 = TickMath.getSqrtPriceAtTick(tickLower);
        uint160 sqrtRatioBX96 = TickMath.getSqrtPriceAtTick(tickUpper);

        // Check if position is single-sided
        // In Uniswap V3: when price < range, liquidity is in currency0; when price > range, liquidity is in currency1
        uint128 liquidity;
        if (sqrtPriceX96 <= sqrtRatioAX96) {
            // Price below range - need currency0
            liquidity = _getLiquidityForAmount0(sqrtRatioAX96, sqrtRatioBX96, tokenIsCurrency0 ? amount : 0);
        } else if (sqrtPriceX96 >= sqrtRatioBX96) {
            // Price above range - need currency1
            liquidity = _getLiquidityForAmount1(sqrtRatioAX96, sqrtRatioBX96, tokenIsCurrency0 ? 0 : amount);
        } else {
            // Current price is within range - need both tokens
            // Calculate liquidity based on the derivative token
            if (tokenIsCurrency0) {
                liquidity = _getLiquidityForAmount0(sqrtPriceX96, sqrtRatioBX96, amount);
            } else {
                liquidity = _getLiquidityForAmount1(sqrtRatioAX96, sqrtPriceX96, amount);
            }
        }

        return liquidity;
    }

    function _getLiquidityForAmount0(uint160 sqrtRatioAX96, uint160 sqrtRatioBX96, uint256 amount0)
        private
        pure
        returns (uint128 liquidity)
    {
        if (sqrtRatioAX96 > sqrtRatioBX96) (sqrtRatioAX96, sqrtRatioBX96) = (sqrtRatioBX96, sqrtRatioAX96);
        uint256 intermediate = FullMath.mulDiv(sqrtRatioAX96, sqrtRatioBX96, FixedPoint96.Q96);
        liquidity = uint128(FullMath.mulDiv(amount0, intermediate, sqrtRatioBX96 - sqrtRatioAX96));
    }

    function _getLiquidityForAmount1(uint160 sqrtRatioAX96, uint160 sqrtRatioBX96, uint256 amount1)
        private
        pure
        returns (uint128 liquidity)
    {
        if (sqrtRatioAX96 > sqrtRatioBX96) (sqrtRatioAX96, sqrtRatioBX96) = (sqrtRatioBX96, sqrtRatioAX96);
        liquidity = uint128(FullMath.mulDiv(amount1, FixedPoint96.Q96, sqrtRatioBX96 - sqrtRatioAX96));
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
