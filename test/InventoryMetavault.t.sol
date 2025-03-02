// SPDX-License-Identifier: MIT
pragma solidity ^0.8.13;

import "forge-std/Test.sol";
import "src/interfaces/IInventoryMetavault.sol";
import "src/interfaces/IRemyVault.sol";
import {ReentrancyAttacker} from "./helpers/ReentrancyAttacker.sol";

interface IERC20 {
    function transfer(address to, uint256 value) external returns (bool);
    function transferFrom(address from, address to, uint256 value) external returns (bool);
    function balanceOf(address owner) external view returns (uint256);
    function approve(address spender, uint256 value) external returns (bool);
    function allowance(address owner, address spender) external view returns (uint256);
    function totalSupply() external view returns (uint256);
    function mint(address to, uint256 value) external;
    function burn(uint256 amount) external;
}

interface IMockERC721 {
    function mint(address to, uint256 tokenId) external;
    function burn(uint256 tokenId) external;
    function ownerOf(uint256 tokenId) external view returns (address);
    function balanceOf(address owner) external view returns (uint256);
    function isApprovedForAll(address owner, address operator) external view returns (bool);
    function safeTransferFrom(address from, address to, uint256 tokenId) external;
    function transferFrom(address from, address to, uint256 tokenId) external;
    function approve(address to, uint256 tokenId) external;
    function setApprovalForAll(address operator, bool approved) external;
    function getApproved(uint256 tokenId) external view returns (address);
}

/**
 * @title InventoryMetavaultTest
 * @dev Comprehensive test suite for the InventoryMetavault contract
 *
 * This test suite validates all aspects of the InventoryMetavault protocol including:
 * - Basic deposit/withdraw functionality
 * - NFT tracking and management
 * - ERC20 balance invariants
 * - Core vault integration
 */
contract InventoryMetavaultTest is Test {
    // Mock ERC721 token for NFTs
    IMockERC721 public nft;
    
    // Mock ERC20 token for core vault
    address public vaultToken;
    
    // Mock ERC20 token for metavault shares
    address public sharesToken;
    
    // RemyVault contract instance
    IRemyVault public coreVault;
    
    // InventoryMetavault contract instance
    IInventoryMetavault public metavault;
    
    // Test user addresses
    address public alice;
    address public bob;
    address public owner;
    
    // Unit value constant from the Remy protocol
    uint256 constant UNIT = 1000 * 10**18;
    
    // Purchase markup in the metavault (110%)
    uint256 constant MARKUP_BPS = 1100;
    uint256 constant BPS_DENOMINATOR = 1000;

    /**
     * @dev Setup function to deploy contracts and initialize test environment
     */
    function setUp() public {
        // Create test addresses
        owner = address(this);
        alice = makeAddr("alice");
        bob = makeAddr("bob");
        
        // Deploy mock contracts
        nft = IMockERC721(deployCode("MockERC721", abi.encode("MOCK", "MOCK", "https://", "MOCK", "1.0")));
        vaultToken = deployCode("MockERC20");
        sharesToken = deployCode("MockERC20");
        
        // Deploy core vault
        coreVault = IRemyVault(deployCode("RemyVault", abi.encode(vaultToken, address(nft))));
        
        // Transfer ownership of tokens to the vault
        vm.prank(owner);
        Ownable(vaultToken).transfer_ownership(address(coreVault));
        
        vm.prank(owner);
        Ownable(address(nft)).transfer_ownership(address(coreVault));
        
        // Deploy metavault
        metavault = IInventoryMetavault(deployCode("InventoryMetavault", abi.encode(address(coreVault), sharesToken)));
        
        // Transfer ownership of shares token to the metavault
        vm.prank(owner);
        Ownable(sharesToken).transfer_ownership(address(metavault));
        
        // Add NFT contract to metavault supported contracts
        vm.prank(owner);
        metavault.add_nft_contract(address(nft));
    }

    /**
     * @dev Test basic setup of the metavault
     */
    function testSetup() public view {
        // Verify metavault references are correct
        assertEq(metavault.remy_vault(), address(coreVault));
        assertEq(metavault.vault_erc20(), vaultToken);
        assertEq(metavault.shares_token(), sharesToken);
        
        // Verify NFT contract is supported
        assertTrue(metavault.is_supported_contract(address(nft)));
        
        // Verify initial inventory is empty
        assertEq(metavault.get_available_inventory(address(nft)), 0);
    }

    /**
     * @dev Test depositing a single NFT into the metavault
     */
    function testDeposit() public {
        // Mint an NFT to Alice
        vm.startPrank(address(coreVault));
        nft.mint(alice, 1);
        vm.stopPrank();
        
        // Alice deposits the NFT into the metavault
        vm.startPrank(alice);
        nft.approve(address(metavault), 1);
        uint256 sharesMinted = metavault.deposit_nfts(address(nft), toArray(1));
        vm.stopPrank();
        
        // Verify metavault now owns the NFT
        assertEq(nft.ownerOf(1), address(metavault));
        
        // Verify metavault inventory was updated
        assertEq(metavault.get_available_inventory(address(nft)), 1);
        
        // Verify Alice received correct amount of shares tokens
        assertEq(IERC20(sharesToken).balanceOf(alice), sharesMinted);
        assertEq(sharesMinted, UNIT);
    }

    /**
     * @dev Test depositing multiple NFTs into the metavault
     */
    function testBatchDeposit() public {
        uint256 numNfts = 3;
        uint256[] memory tokenIds = new uint256[](numNfts);
        
        // Mint NFTs to Alice
        vm.startPrank(address(coreVault));
        for (uint256 i = 0; i < numNfts; i++) {
            tokenIds[i] = i + 1;
            nft.mint(alice, tokenIds[i]);
        }
        vm.stopPrank();
        
        // Alice deposits the NFTs into the metavault
        vm.startPrank(alice);
        nft.setApprovalForAll(address(metavault), true);
        uint256 sharesMinted = metavault.deposit_nfts(address(nft), tokenIds);
        vm.stopPrank();
        
        // Verify metavault now owns the NFTs
        for (uint256 i = 0; i < numNfts; i++) {
            assertEq(nft.ownerOf(tokenIds[i]), address(metavault));
        }
        
        // Verify metavault inventory was updated
        assertEq(metavault.get_available_inventory(address(nft)), numNfts);
        
        // Verify Alice received correct amount of shares tokens
        assertEq(IERC20(sharesToken).balanceOf(alice), sharesMinted);
        assertEq(sharesMinted, numNfts * UNIT);
    }

    /**
     * @dev Test withdrawing a single NFT from the metavault
     */
    function testWithdrawFromMetavault() public {
        // Mint and deposit an NFT
        vm.startPrank(address(coreVault));
        nft.mint(alice, 1);
        vm.stopPrank();
        
        vm.startPrank(alice);
        nft.approve(address(metavault), 1);
        metavault.deposit_nfts(address(nft), toArray(1));
        
        // Get initial balances
        uint256 initialSharesBalance = IERC20(sharesToken).balanceOf(alice);
        
        // Approve and withdraw the NFT
        IERC20(sharesToken).approve(address(metavault), UNIT);
        uint256 sharesBurned = metavault.withdraw_nfts(address(nft), toArray(1));
        vm.stopPrank();
        
        // Verify Alice now owns the NFT
        assertEq(nft.ownerOf(1), alice);
        
        // Verify metavault inventory was updated
        assertEq(metavault.get_available_inventory(address(nft)), 0);
        
        // Verify Alice's shares were burned
        assertEq(IERC20(sharesToken).balanceOf(alice), initialSharesBalance - sharesBurned);
        assertEq(sharesBurned, UNIT);
    }

    /**
     * @dev Test withdrawing an NFT from the core vault through the metavault
     */
    function testWithdrawFromCoreVault() public {
        // Mint and deposit an NFT to the core vault
        vm.startPrank(address(coreVault));
        nft.mint(alice, 1);
        vm.stopPrank();
        
        vm.startPrank(alice);
        nft.approve(address(coreVault), 1);
        coreVault.deposit(1, alice);
        
        // Alice should now have vault tokens
        uint256 initialVaultTokenBalance = IERC20(vaultToken).balanceOf(alice);
        assertEq(initialVaultTokenBalance, UNIT);
        
        // To withdraw through metavault, Alice needs to have shares
        // So first deposit another NFT to get shares
        vm.startPrank(address(coreVault));
        nft.mint(alice, 2);
        vm.stopPrank();
        
        vm.startPrank(alice);
        nft.approve(address(metavault), 2);
        metavault.deposit_nfts(address(nft), toArray(2));
        
        // Now Alice can withdraw NFT #1 from the core vault through the metavault
        uint256 initialSharesBalance = IERC20(sharesToken).balanceOf(alice);
        IERC20(sharesToken).approve(address(metavault), UNIT);
        
        // Transfer some vault tokens to metavault for the core vault withdrawal
        IERC20(vaultToken).transfer(address(metavault), UNIT);
        
        // Withdraw the NFT from core vault
        uint256 sharesBurned = metavault.withdraw_nfts(address(nft), toArray(1));
        vm.stopPrank();
        
        // Verify Alice now owns NFT #1
        assertEq(nft.ownerOf(1), alice);
        
        // Verify Alice's shares were burned
        assertEq(IERC20(sharesToken).balanceOf(alice), initialSharesBalance - sharesBurned);
    }

    /**
     * @dev Test purchasing an NFT from the metavault
     */
    function testPurchaseNFT() public {
        // Mint and deposit an NFT to the metavault
        vm.startPrank(address(coreVault));
        nft.mint(alice, 1);
        vm.stopPrank();
        
        vm.startPrank(alice);
        nft.approve(address(metavault), 1);
        metavault.deposit_nfts(address(nft), toArray(1));
        vm.stopPrank();
        
        // Give Bob some vault tokens to purchase the NFT
        vm.startPrank(address(coreVault));
        IERC20(vaultToken).mint(bob, UNIT * 2);
        vm.stopPrank();
        
        // Calculate purchase price with 10% markup
        uint256 expectedPrice = UNIT * MARKUP_BPS / BPS_DENOMINATOR;
        
        // Bob purchases the NFT
        vm.startPrank(bob);
        IERC20(vaultToken).approve(address(metavault), expectedPrice);
        uint256 pricePaid = metavault.purchase_nfts(address(nft), toArray(1));
        vm.stopPrank();
        
        // Verify Bob now owns the NFT
        assertEq(nft.ownerOf(1), bob);
        
        // Verify metavault inventory was updated
        assertEq(metavault.get_available_inventory(address(nft)), 0);
        
        // Verify correct price was paid
        assertEq(pricePaid, expectedPrice);
        assertEq(IERC20(vaultToken).balanceOf(bob), UNIT * 2 - pricePaid);
        assertEq(IERC20(vaultToken).balanceOf(address(metavault)), pricePaid);
    }

    /**
     * @dev Test that ERC20 share balances can only increase for users
     */
    function testSharesBalanceOnlyIncrease() public {
        // Mint multiple NFTs to Alice for testing
        vm.startPrank(address(coreVault));
        for (uint256 i = 1; i <= 5; i++) {
            nft.mint(alice, i);
        }
        vm.stopPrank();

        // Initial balance should be 0
        assertEq(IERC20(sharesToken).balanceOf(alice), 0);
        
        // Deposit NFTs one by one and verify balance only increases
        uint256 currentBalance = 0;
        vm.startPrank(alice);
        
        for (uint256 i = 1; i <= 5; i++) {
            nft.approve(address(metavault), i);
            metavault.deposit_nfts(address(nft), toArray(i));
            
            uint256 newBalance = IERC20(sharesToken).balanceOf(alice);
            assertGt(newBalance, currentBalance, "Balance should increase after deposit");
            currentBalance = newBalance;
        }
        
        vm.stopPrank();
    }

    /**
     * @dev Test withdrawing multiple NFTs
     */
    function testBatchWithdraw() public {
        uint256 numNfts = 3;
        uint256[] memory tokenIds = new uint256[](numNfts);
        
        // Mint and deposit NFTs
        vm.startPrank(address(coreVault));
        for (uint256 i = 0; i < numNfts; i++) {
            tokenIds[i] = i + 1;
            nft.mint(alice, tokenIds[i]);
        }
        vm.stopPrank();
        
        vm.startPrank(alice);
        nft.setApprovalForAll(address(metavault), true);
        uint256 sharesMinted = metavault.deposit_nfts(address(nft), tokenIds);
        
        // Approve and withdraw the NFTs
        IERC20(sharesToken).approve(address(metavault), sharesMinted);
        uint256 sharesBurned = metavault.withdraw_nfts(address(nft), tokenIds);
        vm.stopPrank();
        
        // Verify Alice now owns the NFTs
        for (uint256 i = 0; i < numNfts; i++) {
            assertEq(nft.ownerOf(tokenIds[i]), alice);
        }
        
        // Verify metavault inventory was updated
        assertEq(metavault.get_available_inventory(address(nft)), 0);
        
        // Verify shares were burned correctly
        assertEq(sharesBurned, sharesMinted);
        assertEq(IERC20(sharesToken).balanceOf(alice), 0);
    }

    /**
     * @dev Test admin functions for adding and removing NFT contracts
     */
    function testAddRemoveNftContract() public {
        // Deploy a new NFT contract
        address newNft = deployCode("MockERC721", abi.encode("NEW", "NEW", "https://", "NEW", "1.0"));
        
        // Initially the new NFT shouldn't be supported
        assertFalse(metavault.is_supported_contract(newNft));
        
        // Add the new NFT contract
        vm.prank(owner);
        metavault.add_nft_contract(newNft);
        
        // Verify it's now supported
        assertTrue(metavault.is_supported_contract(newNft));
        
        // Remove the NFT contract
        vm.prank(owner);
        metavault.remove_nft_contract(newNft);
        
        // Verify it's no longer supported
        assertFalse(metavault.is_supported_contract(newNft));
    }

    /**
     * @dev Test that attempting to deposit an unsupported NFT contract fails
     */
    function testDepositUnsupportedContract() public {
        // Deploy a new NFT contract
        address newNft = deployCode("MockERC721", abi.encode("NEW", "NEW", "https://", "NEW", "1.0"));
        
        // Mint an NFT to Alice
        vm.prank(owner);
        IMockERC721(newNft).mint(alice, 1);
        
        // Attempt to deposit should fail
        vm.startPrank(alice);
        IMockERC721(newNft).approve(address(metavault), 1);
        vm.expectRevert(); // "NFT contract not supported"
        metavault.deposit_nfts(newNft, toArray(1));
        vm.stopPrank();
    }

    /**
     * @dev Test the purchase quote function
     */
    function testQuotePurchase() public {
        // Quote for 1 NFT
        uint256 quote1 = metavault.quote_purchase(address(nft), 1);
        assertEq(quote1, UNIT * MARKUP_BPS / BPS_DENOMINATOR);
        
        // Quote for multiple NFTs
        uint256 count = 5;
        uint256 quote5 = metavault.quote_purchase(address(nft), count);
        assertEq(quote5, count * UNIT * MARKUP_BPS / BPS_DENOMINATOR);
    }

    /**
     * @dev Test depositing with insufficient approval fails
     */
    function testDepositWithoutApproval() public {
        // Mint an NFT to Alice
        vm.prank(address(coreVault));
        nft.mint(alice, 1);
        
        // Attempt to deposit without approval should fail
        vm.startPrank(alice);
        vm.expectRevert();
        metavault.deposit_nfts(address(nft), toArray(1));
        vm.stopPrank();
    }

    /**
     * @dev Test withdrawing without sufficient shares token approval fails
     */
    function testWithdrawWithoutTokenApproval() public {
        // Mint and deposit an NFT
        vm.startPrank(address(coreVault));
        nft.mint(alice, 1);
        vm.stopPrank();
        
        vm.startPrank(alice);
        nft.approve(address(metavault), 1);
        metavault.deposit_nfts(address(nft), toArray(1));
        
        // Attempt to withdraw without shares token approval should fail
        // Don't approve the shares token
        vm.expectRevert();
        metavault.withdraw_nfts(address(nft), toArray(1));
        vm.stopPrank();
    }

    /**
     * @dev Test purchasing without sufficient vault token approval fails
     */
    function testPurchaseWithoutTokenApproval() public {
        // Mint and deposit an NFT to the metavault
        vm.startPrank(address(coreVault));
        nft.mint(alice, 1);
        vm.stopPrank();
        
        vm.startPrank(alice);
        nft.approve(address(metavault), 1);
        metavault.deposit_nfts(address(nft), toArray(1));
        vm.stopPrank();
        
        // Give Bob some vault tokens
        vm.prank(address(coreVault));
        IERC20(vaultToken).mint(bob, UNIT * 2);
        
        // Attempt to purchase without token approval should fail
        vm.startPrank(bob);
        vm.expectRevert();
        metavault.purchase_nfts(address(nft), toArray(1));
        vm.stopPrank();
    }

    /**
     * @dev Test purchasing with insufficient balance fails
     */
    function testPurchaseInsufficientBalance() public {
        // Mint and deposit an NFT to the metavault
        vm.startPrank(address(coreVault));
        nft.mint(alice, 1);
        vm.stopPrank();
        
        vm.startPrank(alice);
        nft.approve(address(metavault), 1);
        metavault.deposit_nfts(address(nft), toArray(1));
        vm.stopPrank();
        
        // Give Bob insufficient vault tokens
        uint256 price = metavault.quote_purchase(address(nft), 1);
        vm.prank(address(coreVault));
        IERC20(vaultToken).mint(bob, price - 1);
        
        // Attempt to purchase with insufficient balance should fail
        vm.startPrank(bob);
        IERC20(vaultToken).approve(address(metavault), price);
        vm.expectRevert();
        metavault.purchase_nfts(address(nft), toArray(1));
        vm.stopPrank();
    }

    /**
     * @dev Test purchasing non-existent inventory fails
     */
    function testPurchaseNonExistentInventory() public {
        // Give Bob some vault tokens
        vm.prank(address(coreVault));
        IERC20(vaultToken).mint(bob, UNIT * 2);
        
        // Attempt to purchase non-existent inventory
        vm.startPrank(bob);
        IERC20(vaultToken).approve(address(metavault), UNIT * 2);
        vm.expectRevert(); // "Not enough inventory"
        metavault.purchase_nfts(address(nft), toArray(1));
        vm.stopPrank();
    }

    // Helper function to convert a single uint256 to an array
    function toArray(uint256 value) internal pure returns (uint256[] memory) {
        uint256[] memory arr = new uint256[](1);
        arr[0] = value;
        return arr;
    }
}

interface Ownable {
    function owner() external view returns (address);
    function transfer_ownership(address newOwner) external;
}