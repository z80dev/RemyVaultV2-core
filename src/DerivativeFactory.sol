// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Ownable} from "solady/auth/Ownable.sol";

import {RemyVaultFactory} from "./RemyVaultFactory.sol";
import {RemyVaultHook} from "./RemyVaultHook.sol";
import {RemyVaultNFT} from "./RemyVaultNFT.sol";
import {RemyVault} from "./RemyVault.sol";

import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";

contract DerivativeFactory is Ownable {
    using PoolIdLibrary for PoolKey;

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

        RemyVaultNFT derivativeNft =
            new RemyVaultNFT(params.nftName, params.nftSymbol, params.nftBaseUri, address(this));
        if (params.initialMinter != address(0)) {
            derivativeNft.setMinter(params.initialMinter, true);
        }
        if (params.nftOwner != address(0) && params.nftOwner != address(this)) {
            derivativeNft.transferOwnership(params.nftOwner);
        }

        nft = address(derivativeNft);
        vault = VAULT_FACTORY.deployVault(nft, params.vaultName, params.vaultSymbol);

        PoolKey memory childKey = _buildPoolKey(vault, params.parentVault, params.fee, params.tickSpacing);
        HOOK.addChild(childKey, true, root.key);
        POOL_MANAGER.initialize(childKey, params.sqrtPriceX96);

        childPoolId = childKey.toId();
        derivativeForVault[vault] = DerivativeInfo({nft: nft, parentVault: params.parentVault, poolId: childPoolId});
        vaultForNft[nft] = vault;

        address parentCollection = RemyVault(params.parentVault).erc721();

        emit DerivativeCreated(
            parentCollection,
            params.parentVault,
            nft,
            vault,
            childPoolId,
            params.fee,
            params.tickSpacing,
            params.sqrtPriceX96
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
        Currency currencyA = Currency.wrap(tokenA);
        Currency currencyB = Currency.wrap(tokenB);
        if (Currency.unwrap(currencyA) < Currency.unwrap(currencyB)) {
            key = PoolKey({
                currency0: currencyA,
                currency1: currencyB,
                fee: fee,
                tickSpacing: tickSpacing,
                hooks: IHooks(address(HOOK))
            });
        } else {
            key = PoolKey({
                currency0: currencyB,
                currency1: currencyA,
                fee: fee,
                tickSpacing: tickSpacing,
                hooks: IHooks(address(HOOK))
            });
        }
    }
}
