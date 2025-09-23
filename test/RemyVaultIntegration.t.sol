// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import "forge-std/Test.sol";
import "../src/RemyVaultHook.sol";
import {IRemyVault} from "../src/interfaces/IRemyVault.sol";
import {IERC721} from "../src/interfaces/IERC721.sol";
import {IERC20Minimal} from "@uniswap/v4-core/src/interfaces/external/IERC20Minimal.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {CurrencyLibrary, Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {PoolId, PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
import {HookMiner} from "@uniswap/v4-periphery/src/utils/HookMiner.sol";

/**
 * @title RemyVaultHookTest
 * @notice Test contract for RemyVaultHook
 */
contract RemyVaultHookTest is Test {
    using CurrencyLibrary for Currency;
    using PoolIdLibrary for PoolKey;

    // Test constants
    uint256 constant BUY_FEE = 250; // 2.5%

    // Mock contracts
    address mockPoolManager;
    address mockRemyVault;
    address mockVaultToken;
    address mockNFTCollection;

    // Hook instance
    RemyVaultHook hook;

    // Test accounts
    address owner;
    address user;
    address feeRecipient;

    // Events to test
    event NFTBought(address indexed buyer, uint256 tokenId, uint256 price);
    event NFTSold(address indexed seller, uint256 tokenId, uint256 price);
    event InventoryChanged(uint256[] tokenIds, bool added);
    event FeesCollected(address indexed recipient, uint256 amount);

    /**
     * @notice Set up test environment before each test
     */
    function setUp() public {
        // Create test accounts
        owner = makeAddr("owner");
        user = makeAddr("user");
        feeRecipient = makeAddr("feeRecipient");

        // Set up mock contracts
        mockPoolManager = makeAddr("poolManager");
        mockRemyVault = makeAddr("remyVault");
        mockVaultToken = makeAddr("vaultToken");
        mockNFTCollection = makeAddr("nftCollection");

        // For testing, we'll just directly deploy the hook without address validation
        vm.startPrank(owner);

        // Mock RemyVault interface calls before deployment
        vm.mockCall(mockRemyVault, abi.encodeWithSelector(IRemyVault.erc20.selector), abi.encode(mockVaultToken));

        vm.mockCall(mockRemyVault, abi.encodeWithSelector(IRemyVault.erc721.selector), abi.encode(mockNFTCollection));

        // Deploy the hook with try/catch to get more info on failures
        try new RemyVaultHook(IPoolManager(mockPoolManager), mockRemyVault, feeRecipient, BUY_FEE) returns (
            RemyVaultHook deployedHook
        ) {
            hook = deployedHook;
        } catch Error(string memory reason) {
            console.log("Deployment failed with reason:", reason);
            revert(reason);
        } catch (bytes memory) {
            console.log("Deployment failed with low level error");
            revert("Low level error");
        }
        vm.stopPrank();
    }

    /**
     * @notice Test basic constructor and initialization
     */
    function testInitialization() public view {
        assertEq(address(hook.remyVault()), mockRemyVault);
        assertEq(address(hook.vaultToken()), mockVaultToken);
        assertEq(address(hook.nftCollection()), mockNFTCollection);
        assertEq(hook.owner(), owner);
        assertEq(hook.feeRecipient(), feeRecipient);
        assertEq(hook.buyFee(), BUY_FEE);
    }

    /**
     * @notice Test adding NFTs to inventory
     */
    function testAddNFTsToInventory() public {
        uint256[] memory tokenIds = new uint256[](2);
        tokenIds[0] = 1;
        tokenIds[1] = 2;

        // Mock NFT transfer
        vm.mockCall(
            mockNFTCollection,
            abi.encodeWithSelector(IERC721.transferFrom.selector, owner, address(hook), tokenIds[0]),
            abi.encode()
        );

        vm.mockCall(
            mockNFTCollection,
            abi.encodeWithSelector(IERC721.transferFrom.selector, owner, address(hook), tokenIds[1]),
            abi.encode()
        );

        // Expect event to be emitted
        vm.expectEmit(true, true, true, true);
        emit InventoryChanged(tokenIds, true);

        // Add NFTs to inventory
        vm.prank(owner);
        hook.addNFTsToInventory(tokenIds);

        // Check inventory
        assertEq(hook.inventorySize(), 2);
        assertTrue(hook.isInInventory(1));
        assertTrue(hook.isInInventory(2));
    }

    /**
     * @notice Test setting buy fee
     */
    function testSetBuyFee() public {
        uint256 newBuyFee = 300;

        vm.prank(owner);
        hook.setBuyFee(newBuyFee);

        assertEq(hook.buyFee(), newBuyFee);
    }

    /**
     * @notice Test transferring ownership
     */
    function testTransferOwnership() public {
        address newOwner = makeAddr("newOwner");

        vm.prank(owner);
        hook.transferOwnership(newOwner);

        assertEq(hook.owner(), newOwner);
    }

    /**
     * @notice Test unauthorized access
     */
    function testUnauthorizedAccess() public {
        vm.startPrank(user);

        // Try to set fee as non-owner
        vm.expectRevert(RemyVaultHook.Unauthorized.selector);
        hook.setBuyFee(300);

        // Try to transfer ownership as non-owner
        vm.expectRevert(RemyVaultHook.Unauthorized.selector);
        hook.transferOwnership(user);

        // Try to add NFTs to inventory as non-owner
        uint256[] memory tokenIds = new uint256[](1);
        tokenIds[0] = 1;
        vm.expectRevert(RemyVaultHook.Unauthorized.selector);
        hook.addNFTsToInventory(tokenIds);

        vm.stopPrank();
    }

    /**
     * @notice Test collecting ETH fees
     */
    function testCollectETHFees() public {
        // Set up ETH balance
        uint256 balance = 1 ether;
        vm.deal(address(hook), balance);

        // Expect event to be emitted
        vm.expectEmit(true, true, true, true);
        emit FeesCollected(feeRecipient, balance);

        // Collect fees
        vm.prank(feeRecipient);
        hook.collectETHFees();

        // Check balances
        assertEq(address(hook).balance, 0);
        assertEq(feeRecipient.balance, balance);
    }

    /**
     * @notice Test collecting tokens
     */
    function testCollectTokens() public {
        // Mock token balance
        uint256 balance = 1000;
        vm.mockCall(
            mockVaultToken, abi.encodeWithSelector(IERC20Minimal.balanceOf.selector, address(hook)), abi.encode(balance)
        );

        // Mock transfer
        vm.mockCall(
            mockVaultToken, abi.encodeWithSelector(IERC20Minimal.transfer.selector, owner, balance), abi.encode(true)
        );

        // Collect tokens
        vm.prank(owner);
        hook.collectTokens();
    }

    // Additional tests would be implemented to cover pool initialization,
    // NFT buying/selling through swaps, and all edge cases
}
