// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Test} from "forge-std/Test.sol";
import {StdInvariant} from "forge-std/StdInvariant.sol";
import {DerivativeTestUtils} from "./DerivativeTestUtils.sol";

import {DerivativeFactory} from "../src/DerivativeFactory.sol";
import {wNFTMinter} from "../src/wNFTMinter.sol";
import {wNFTFactory} from "../src/wNFTFactory.sol";
import {wNFTHook} from "../src/wNFTHook.sol";
import {wNFTNFT} from "../src/wNFTNFT.sol";
import {wNFT} from "../src/wNFT.sol";
import {MockERC721Simple} from "./helpers/MockERC721Simple.sol";

import {Hooks} from "@uniswap/v4-core/src/libraries/Hooks.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {PoolManager} from "@uniswap/v4-core/src/PoolManager.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
import {Currency, CurrencyLibrary} from "@uniswap/v4-core/src/types/Currency.sol";
import {StateLibrary} from "@uniswap/v4-core/src/libraries/StateLibrary.sol";

/// @title DerivativeFactoryInvariantHandler
/// @dev Handler for DerivativeFactory invariant testing
contract DerivativeFactoryInvariantHandler is Test, DerivativeTestUtils {
    using PoolIdLibrary for PoolKey;
    using CurrencyLibrary for Currency;
    using StateLibrary for IPoolManager;

    uint160 internal constant SQRT_PRICE_1_1 = 79228162514264337593543950336;

    DerivativeFactory public factory;
    wNFTFactory public vaultFactory;
    wNFTHook public hook;
    IPoolManager public manager;

    MockERC721Simple[] public parentCollections;
    address[] public parentVaults;
    address[] public derivativeVaults;
    address[] public derivativeNFTs;

    uint256 public derivativeCount;

    constructor(DerivativeFactory _factory, wNFTFactory _vaultFactory, wNFTHook _hook, IPoolManager _manager)
    {
        factory = _factory;
        vaultFactory = _vaultFactory;
        hook = _hook;
        manager = _manager;
    }

    function createParentVault(uint256 collectionSeed) public {
        // Create a new parent collection
        string memory name = string(abi.encodePacked("Parent", collectionSeed));
        MockERC721Simple collection = new MockERC721Simple(name, "PRT");
        parentCollections.push(collection);

        // Create vault for collection
        (address parentVault,) = factory.createVaultForCollection(address(collection), SQRT_PRICE_1_1);
        parentVaults.push(parentVault);

        // Mint some NFTs and deposit to vault
        uint256[] memory tokenIds = new uint256[](100);
        for (uint256 i = 0; i < 100; ++i) {
            collection.mint(address(this), i + 1);
            tokenIds[i] = i + 1;
        }
        collection.setApprovalForAll(parentVault, true);
        wNFT(parentVault).deposit(tokenIds, address(this));
        wNFT(parentVault).approve(address(factory), type(uint256).max);
    }

    function createDerivative(uint256 parentIndex, uint256 maxSupply, uint256 liquiditySeed) public {
        if (parentVaults.length == 0) return;

        parentIndex = parentIndex % parentVaults.length;
        address parentVault = parentVaults[parentIndex];

        maxSupply = bound(maxSupply, 10, 100);
        uint128 liquidity = uint128(bound(liquiditySeed, 1e3, 1e6));

        uint256 balance = wNFT(parentVault).balanceOf(address(this));
        if (balance < maxSupply * 1e18) return;

        DerivativeFactory.DerivativeParams memory params;
        params.parentCollection = address(parentCollections[parentIndex]);
        params.nftName = string(abi.encodePacked("Derivative", derivativeCount));
        params.nftSymbol = "DRV";
        params.nftBaseUri = "ipfs://";
        params.fee = 3000;
        params.sqrtPriceX96 = SQRT_PRICE_1_1;
        params.maxSupply = maxSupply;
        params.tickLower = -60;
        params.tickUpper = 60;
        params.liquidity = liquidity;
        params.parentTokenContribution = maxSupply * 1e18;
        params.salt = mineSaltForToken1(factory, parentVault, maxSupply);

        try factory.createDerivative(params) returns (address nft, address vault, PoolId) {
            derivativeNFTs.push(nft);
            derivativeVaults.push(vault);
            derivativeCount++;
        } catch {
            // Creation failed, skip
        }
    }

    function onERC721Received(address, address, uint256, bytes calldata) external pure returns (bytes4) {
        return this.onERC721Received.selector;
    }
}

/// @title DerivativeFactoryInvariantTest
/// @dev Invariant tests for the DerivativeFactory
contract DerivativeFactoryInvariantTest is StdInvariant, Test, DerivativeTestUtils {
    using PoolIdLibrary for PoolKey;
    using CurrencyLibrary for Currency;

    uint160 internal constant SQRT_PRICE_1_1 = 79228162514264337593543950336;
    uint160 internal constant CLEAR_HOOK_PERMISSIONS_MASK = ~uint160(0) << 14;
    uint160 internal constant HOOK_FLAGS = Hooks.BEFORE_SWAP_FLAG | Hooks.AFTER_SWAP_FLAG
        | Hooks.BEFORE_SWAP_RETURNS_DELTA_FLAG | Hooks.AFTER_SWAP_RETURNS_DELTA_FLAG;

    wNFTFactory internal vaultFactory;
    wNFTHook internal hook;
    DerivativeFactory internal factory;
    PoolManager internal managerImpl;
    IPoolManager internal manager;
    DerivativeFactoryInvariantHandler internal handler;

    address internal hookAddress;

    function setUp() public {
        managerImpl = new PoolManager(address(this));
        manager = IPoolManager(address(managerImpl));

        address baseHookAddress = address(0x4444000000000000000000000000000000000000);
        hookAddress = address(uint160((uint160(baseHookAddress) & CLEAR_HOOK_PERMISSIONS_MASK) | HOOK_FLAGS));
        vm.etch(hookAddress, hex"");
        deployCodeTo("wNFTHook.sol:wNFTHook", abi.encode(manager, address(this)), hookAddress);
        hook = wNFTHook(hookAddress);

        vaultFactory = new wNFTFactory();
        factory = new DerivativeFactory(vaultFactory, hook, address(this));
        hook.transferOwnership(address(factory));

        handler = new DerivativeFactoryInvariantHandler(factory, vaultFactory, hook, manager);

        // Initialize with one parent vault
        handler.createParentVault(0);

        targetContract(address(handler));

        bytes4[] memory selectors = new bytes4[](2);
        selectors[0] = DerivativeFactoryInvariantHandler.createParentVault.selector;
        selectors[1] = DerivativeFactoryInvariantHandler.createDerivative.selector;

        targetSelector(FuzzSelector({addr: address(handler), selectors: selectors}));
    }

    /// @dev Invariant: Derivative address must always be greater than parent address (to be currency1)
    function invariant_derivativeAddressAlwaysGreaterThanParent() public view {
        for (uint256 i = 0; i < handler.derivativeCount(); i++) {
            address derivativeVault = handler.derivativeVaults(i);
            (,address parentVault,) = factory.derivativeForVault(derivativeVault);

            assertTrue(
                derivativeVault > parentVault,
                "INVARIANT: Derivative vault must be > parent vault (to be currency1)"
            );
        }
    }

    /// @dev Invariant: All derivatives have valid root pools
    function invariant_allDerivativesHaveValidRootPool() public view {
        for (uint256 i = 0; i < handler.derivativeCount(); i++) {
            address derivativeVault = handler.derivativeVaults(i);
            (, address parentVault, PoolId childPoolId) = factory.derivativeForVault(derivativeVault);

            // Verify hook configuration
            (bool initialized, bool hasParent, PoolKey memory parentKey,,,) = hook.poolConfig(childPoolId);

            assertTrue(initialized, "INVARIANT: Derivative pool must be initialized in hook");
            assertTrue(hasParent, "INVARIANT: Derivative pool must have parent");

            // Parent pool must exist
            (PoolKey memory rootKey, PoolId rootId) = factory.rootPool(parentVault);
            assertEq(
                PoolId.unwrap(parentKey.toId()), PoolId.unwrap(rootId), "INVARIANT: Parent pool ID must match root"
            );

            assertTrue(address(rootKey.hooks) == hookAddress, "INVARIANT: Root pool must use correct hook");
        }
    }

    /// @dev Invariant: Derivative supply matches deployment parameters
    function invariant_derivativeSupplyMatchesDeployment() public view {
        for (uint256 i = 0; i < handler.derivativeCount(); i++) {
            address derivativeVault = handler.derivativeVaults(i);
            wNFTMinter vault = wNFTMinter(derivativeVault);

            uint256 maxSupply = vault.maxSupply();
            uint256 totalSupply = vault.totalSupply();
            uint256 mintedCount = vault.mintedCount();

            // Total supply should equal: (maxSupply - mintedCount + deposited) * UNIT
            uint256 expectedTotalSupply = (maxSupply - mintedCount) * vault.UNIT();

            // Add deposited NFTs
            address nft = address(wNFTNFT(vault.erc721()));
            uint256 depositedCount = wNFTNFT(nft).balanceOf(derivativeVault);
            expectedTotalSupply += depositedCount * vault.UNIT();

            assertEq(totalSupply, expectedTotalSupply, "INVARIANT: Derivative total supply mismatch");
        }
    }

    function onERC721Received(address, address, uint256, bytes calldata) external pure returns (bytes4) {
        return this.onERC721Received.selector;
    }
}
