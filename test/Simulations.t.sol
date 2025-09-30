// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {BaseTest} from "./BaseTest.t.sol";
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

contract Simulations is BaseTest {
    using PoolIdLibrary for PoolKey;
    using StateLibrary for IPoolManager;

    uint160 internal constant SQRT_PRICE_1_1 = 79228162514264337593543950336;
    uint160 internal constant CLEAR_HOOK_PERMISSIONS_MASK = ~uint160(0) << 14;
    uint160 internal constant HOOK_FLAGS = Hooks.BEFORE_SWAP_FLAG | Hooks.AFTER_SWAP_FLAG
        | Hooks.BEFORE_SWAP_RETURNS_DELTA_FLAG | Hooks.AFTER_SWAP_RETURNS_DELTA_FLAG;
    uint160 internal constant HOOK_ADDRESS_SEED = uint160(0x4444000000000000000000000000000000000000);
    address internal constant HOOK_ADDRESS =
        address(uint160((HOOK_ADDRESS_SEED & CLEAR_HOOK_PERMISSIONS_MASK) | HOOK_FLAGS));
    address internal constant POOL_MANAGER_ADDRESS = 0x498581fF718922c3f8e6A244956aF099B2652b2b;
    IPoolManager internal constant POOL_MANAGER = IPoolManager(POOL_MANAGER_ADDRESS);

    RemyVaultFactory internal vaultFactory;
    RemyVaultHook internal hook;
    DerivativeFactory internal factory;

    function setUp() public override {
        super.setUp();

        vaultFactory = new RemyVaultFactory();

        vm.etch(HOOK_ADDRESS, hex"");
        deployCodeTo("RemyVaultHook.sol:RemyVaultHook", abi.encode(POOL_MANAGER, address(this)), HOOK_ADDRESS);
        hook = RemyVaultHook(HOOK_ADDRESS);

        factory = new DerivativeFactory(vaultFactory, hook, address(this));
        hook.transferOwnership(address(factory));
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

        // Create root pool for parent vault (permissionless)
        PoolId rootPoolId = _initRootPool(parentVault, 3000, 60, SQRT_PRICE_1_1);

        // Approve parent vault tokens for derivative creation
        RemyVault(parentVault).approve(address(factory), type(uint256).max);

        // Setup derivative parameters
        uint256 maxSupply = 50; // Will create 50 derivative NFTs worth of tokens

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
        // For single-sided currency1 (derivative) liquidity:
        // Current sqrtPrice 56022... ≈ tick -6932
        // In Uniswap: when price > range, liquidity is in currency1
        // So place range BELOW current tick: -12000 to -7200
        params.tickLower = -12000;
        params.tickUpper = -7200;
        params.sqrtPriceX96 = 56022770974786139918731938227; // ~0.5 price (tick ~= -6932)
        params.liquidity = 15e18; // This should be overridden to use entire supply
        params.parentTokenContribution = 0; // No parent tokens needed for single-sided liquidity
        params.derivativeTokenRecipient = address(this);
        params.parentTokenRefundRecipient = address(this);

        // Mine a salt that ensures derivative vault address > parent vault address (derivative will be token1)
        // We need to predict the NFT address first - it's deployed with CREATE in the factory
        // For simplicity, we'll approximate the NFT address
        // The NFT is created as: new RemyVaultNFT(...) - this is the first CREATE in createDerivative
        // So the NFT address will be: keccak256(rlp([factory_address, nonce]))
        // Since we're in a test, we can just mine the salt by trial and error
        bytes32 salt = _mineSaltForToken1(parentVault, params.vaultName, params.vaultSymbol, maxSupply);
        params.salt = salt;

        console.log("Mined salt:", uint256(salt));
        console.log("Parent vault:", parentVault);

        // Create derivative
        (address nft, address derivativeVault, PoolId childPoolId) = factory.createDerivative(params);

        // Check balances after
        uint256 factoryDerivativeBalance = MinterRemyVault(derivativeVault).balanceOf(address(factory));
        uint256 thisDerivativeBalance = MinterRemyVault(derivativeVault).balanceOf(address(this));
        uint256 factoryParentBalance = RemyVault(parentVault).balanceOf(address(factory));

        uint256 totalSupply = maxSupply * 1e18;
        uint256 tokensInPool = totalSupply - thisDerivativeBalance;

        // Log results
        console.log("=== ISSUE IDENTIFIED ===");
        console.log("Total derivative supply:", totalSupply);
        console.log("Tokens refunded to recipient:", thisDerivativeBalance);
        console.log("Tokens added to pool:", tokensInPool);
        console.log("Expected: ALL tokens should be in pool (0 refunded)");

        // CRITICAL ASSERTIONS:
        // 1. Factory should have ZERO derivative tokens left
        assertEq(factoryDerivativeBalance, 0, "Factory should have 0 derivative tokens");
        assertEq(factoryParentBalance, 0, "Factory should have 0 parent tokens");

        // 2. ALL derivative tokens should be in the pool (none refunded)
        // This will FAIL with current implementation - showing the bug
        assertEq(thisDerivativeBalance, 0, "ALL derivative tokens should be in pool, none refunded");
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

    /// @notice Mine a salt that ensures the derivative vault address > parent vault address
    /// This is necessary because we want the derivative token to always be token1 in the pool
    function _mineSaltForToken1(
        address parentVault,
        string memory vaultName,
        string memory vaultSymbol,
        uint256 maxSupply
    ) internal view returns (bytes32) {
        // The NFT is created using CREATE (not CREATE2) in createDerivative
        // So we need to predict the NFT address based on the factory's nonce
        // NFT address = keccak256(rlp([factory_address, nonce]))
        uint64 factoryNonce = vm.getNonce(address(factory));

        // The nonce will be incremented when the NFT is created
        // RLP encoding for nonce < 128: [0xd6, 0x94, ...address..., nonce]
        // RLP encoding for nonce >= 128: varies
        address predictedNFT = _computeCreateAddress(address(factory), factoryNonce);

        console.log("Predicted NFT address:", predictedNFT);
        console.log("Factory nonce:", factoryNonce);

        // Now mine a salt such that the derivative vault address > parent vault address
        bytes32 salt;
        for (uint256 i = 0; i < 10000; i++) {
            salt = bytes32(i);
            address predictedVault = factory.predictDerivativeVaultAddress(
                predictedNFT,
                vaultName,
                vaultSymbol,
                maxSupply,
                salt
            );

            if (predictedVault > parentVault) {
                console.log("Found salt:", i);
                console.log("Predicted vault:", predictedVault);
                return salt;
            }
        }

        revert("Could not find valid salt in 10000 iterations");
    }

    /// @notice Compute the address of a contract deployed with CREATE
    function _computeCreateAddress(address deployer, uint64 nonce) internal pure returns (address) {
        // RLP encoding of [deployer, nonce]
        bytes memory rlpEncoded;

        if (nonce == 0x00) {
            rlpEncoded = abi.encodePacked(bytes1(0xd6), bytes1(0x94), deployer, bytes1(0x80));
        } else if (nonce <= 0x7f) {
            rlpEncoded = abi.encodePacked(bytes1(0xd6), bytes1(0x94), deployer, bytes1(uint8(nonce)));
        } else if (nonce <= 0xff) {
            rlpEncoded = abi.encodePacked(bytes1(0xd7), bytes1(0x94), deployer, bytes1(0x81), bytes1(uint8(nonce)));
        } else if (nonce <= 0xffff) {
            rlpEncoded = abi.encodePacked(bytes1(0xd8), bytes1(0x94), deployer, bytes1(0x82), bytes2(uint16(nonce)));
        } else if (nonce <= 0xffffff) {
            rlpEncoded = abi.encodePacked(bytes1(0xd9), bytes1(0x94), deployer, bytes1(0x83), bytes3(uint24(nonce)));
        } else {
            rlpEncoded = abi.encodePacked(bytes1(0xda), bytes1(0x94), deployer, bytes1(0x84), bytes4(uint32(nonce)));
        }

        return address(uint160(uint256(keccak256(rlpEncoded))));
    }
}