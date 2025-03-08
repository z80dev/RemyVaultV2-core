// SPDX-License-Identifier: MIT
pragma solidity ^0.8.13;

import "forge-std/Test.sol";
import "src/interfaces/IInventoryMetavault.sol";
import "src/interfaces/IRemyVault.sol";
import "src/interfaces/IERC20.sol";
import {ReentrancyAttacker} from "./helpers/ReentrancyAttacker.sol";

// Additional ERC20 functions for our mock tokens
interface IMockERC20 is IERC20 {
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
 * This test suite validates all aspects of the single-collection InventoryMetavault protocol including:
 * - Basic deposit/withdraw functionality
 * - NFT tracking and management
 * - ERC20 balance invariants
 * - Core vault integration
 * - ERC4626 compliance
 */
contract InventoryMetavaultTest is Test {
    // Mock ERC721 token for NFTs
    IMockERC721 public nft;
    
    // Mock ERC20 token for core vault
    address public vaultToken;
    
    // RemyVault contract instance
    IRemyVault public coreVault;
    
    // InventoryMetavault contract instance
    IInventoryMetavault public metavault;
    
    // Test user addresses
    address public alice;
    address public bob;
    address public charlie;
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
        charlie = makeAddr("charlie");
        
        // Deploy mock contracts
        nft = IMockERC721(deployCode("MockERC721", abi.encode("MOCK", "MOCK", "https://", "MOCK", "1.0")));
        vaultToken = deployCode("MockERC20");
        
        // Deploy core vault
        coreVault = IRemyVault(deployCode("RemyVault", abi.encode(vaultToken, address(nft))));
        
        // Transfer ownership of tokens to the vault
        vm.prank(owner);
        Ownable(vaultToken).transfer_ownership(address(coreVault));
        
        vm.prank(owner);
        Ownable(address(nft)).transfer_ownership(address(coreVault));
        
        // Deploy metavault as an ERC4626
        // For the constructor, we pass the remy_vault address, name, and symbol
        metavault = IInventoryMetavault(deployCode("InventoryMetavault", 
            abi.encode(address(coreVault), "MetaVault Shares", "MVS")));
    }
    
    /**
     * @dev Test basic setup of the metavault
     */
    function testSetup() public {
        // Print debug information
        console.log("metavault.remy_vault():", metavault.remy_vault());
        console.log("expected remy_vault:", address(coreVault));
        console.log("metavault.asset():", metavault.asset());
        console.log("expected asset:", vaultToken);
        console.log("metavault.decimals():", metavault.decimals());
        
        // Verify metavault references are correct
        assertEq(metavault.remy_vault(), address(coreVault));
        assertEq(metavault.asset(), vaultToken);
        assertEq(metavault.nft_collection(), address(nft));
        
        // Verify initial inventory is empty
        assertEq(metavault.get_available_inventory(), 0);
        
        // Verify markup is set to the default
        assertEq(metavault.MARKUP_BPS(), 1100);
        
        // Verify contract is not paused initially
        assertFalse(metavault.paused());
        
        // Verify ERC4626 specific setup
        assertEq(metavault.name(), "MetaVault Shares");
        assertEq(metavault.symbol(), "MVS");
        assertEq(metavault.decimals(), 18);
        assertEq(metavault.totalSupply(), 0);
        assertEq(metavault.totalAssets(), 0);
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
        uint256 sharesMinted = metavault.deposit_nfts(toArray(1), alice);
        vm.stopPrank();
        
        // Verify metavault now owns the NFT
        assertEq(nft.ownerOf(1), address(metavault));
        
        // Verify metavault inventory was updated
        assertEq(metavault.get_available_inventory(), 1);
        assertTrue(metavault.is_token_in_inventory(1));
        
        // Verify Alice received correct amount of shares tokens
        assertEq(metavault.balanceOf(alice), sharesMinted);
        assertEq(sharesMinted, UNIT); // First deposit gets 1:1 ratio
        
        // Verify totalAssets and totalSupply are updated correctly
        assertEq(metavault.totalAssets(), UNIT);
        assertEq(metavault.totalSupply(), UNIT);
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
        uint256 sharesMinted = metavault.deposit_nfts(tokenIds, alice);
        vm.stopPrank();
        
        // Verify metavault now owns the NFTs
        for (uint256 i = 0; i < numNfts; i++) {
            assertEq(nft.ownerOf(tokenIds[i]), address(metavault));
            assertTrue(metavault.is_token_in_inventory(tokenIds[i]));
        }
        
        // Verify metavault inventory was updated
        assertEq(metavault.get_available_inventory(), numNfts);
        
        // Verify Alice received correct amount of shares tokens
        assertEq(metavault.balanceOf(alice), sharesMinted);
        assertEq(sharesMinted, numNfts * UNIT);
        
        // Verify totalAssets and totalSupply are updated correctly
        assertEq(metavault.totalAssets(), numNfts * UNIT);
        assertEq(metavault.totalSupply(), numNfts * UNIT);
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
        metavault.deposit_nfts(toArray(1), alice);
        
        // Get initial balances
        uint256 initialSharesBalance = metavault.balanceOf(alice);
        
        // Approve and withdraw the NFT
        metavault.approve(address(metavault), UNIT);
        (uint256 sharesBurned, uint256 feeTokensClaimed) = metavault.withdraw_nfts(toArray(1), true, alice);
        vm.stopPrank();
        
        // Verify Alice now owns the NFT
        assertEq(nft.ownerOf(1), alice);
        
        // Verify metavault inventory was updated
        assertEq(metavault.get_available_inventory(), 0);
        assertFalse(metavault.is_token_in_inventory(1));
        
        // Verify Alice's shares were burned
        assertEq(metavault.balanceOf(alice), initialSharesBalance - sharesBurned);
        assertEq(sharesBurned, UNIT);
        
        // Initially there should be no fee tokens claimed as no purchases have occurred yet
        assertEq(feeTokensClaimed, 0);
        
        // Verify totalAssets and totalSupply are updated correctly
        assertEq(metavault.totalAssets(), 0);
        assertEq(metavault.totalSupply(), 0);
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
        uint256 initialVaultTokenBalance = IMockERC20(vaultToken).balanceOf(alice);
        assertEq(initialVaultTokenBalance, UNIT);
        
        // To withdraw through metavault, Alice needs to have shares
        // So first deposit another NFT to get shares
        vm.startPrank(address(coreVault));
        nft.mint(alice, 2);
        vm.stopPrank();
        
        vm.startPrank(alice);
        nft.approve(address(metavault), 2);
        metavault.deposit_nfts(toArray(2), alice);
        
        // Now Alice can withdraw NFT #1 from the core vault through the metavault
        uint256 initialSharesBalance = metavault.balanceOf(alice);
        metavault.approve(address(metavault), UNIT);
        
        // Transfer some vault tokens to metavault for the core vault withdrawal
        IMockERC20(vaultToken).transfer(address(metavault), UNIT);
        
        // Withdraw the NFT from core vault
        (uint256 sharesBurned, uint256 feeTokensClaimed) = metavault.withdraw_nfts(toArray(1), true, alice);
        vm.stopPrank();
        
        // Verify Alice now owns NFT #1
        assertEq(nft.ownerOf(1), alice);
        
        // Verify Alice's shares were burned
        assertEq(metavault.balanceOf(alice), initialSharesBalance - sharesBurned);
        
        // Since there were no purchases yet, fees should be zero
        assertEq(feeTokensClaimed, 0);
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
        metavault.deposit_nfts(toArray(1), alice);
        vm.stopPrank();
        
        // Give Bob some vault tokens to purchase the NFT
        vm.startPrank(address(coreVault));
        IMockERC20(vaultToken).mint(bob, UNIT * 2);
        vm.stopPrank();
        
        // Calculate purchase price with 10% markup
        uint256 expectedPrice = UNIT * MARKUP_BPS / BPS_DENOMINATOR;
        
        // Record initial total assets
        uint256 initialTotalAssets = metavault.totalAssets();
        
        // Bob purchases the NFT
        vm.startPrank(bob);
        IMockERC20(vaultToken).approve(address(metavault), expectedPrice);
        uint256 pricePaid = metavault.purchase_nfts(toArray(1));
        vm.stopPrank();
        
        // Verify Bob now owns the NFT
        assertEq(nft.ownerOf(1), bob);
        
        // Verify metavault inventory was updated
        assertEq(metavault.get_available_inventory(), 0);
        assertFalse(metavault.is_token_in_inventory(1));
        
        // Verify correct price was paid
        assertEq(pricePaid, expectedPrice);
        assertEq(IMockERC20(vaultToken).balanceOf(bob), UNIT * 2 - pricePaid);
        assertEq(IMockERC20(vaultToken).balanceOf(address(metavault)), pricePaid);
        
        // Verify fee accumulation
        uint256 feeAmount = pricePaid - UNIT;
        assertEq(metavault.accumulated_fees(), feeAmount);
        
        // Verify totalAssets reflects the change - inventory value decreased but fee tokens increased
        uint256 expectedTotalAssets = initialTotalAssets - UNIT + feeAmount;
        assertEq(metavault.totalAssets(), expectedTotalAssets);
    }
    
    /**
     * @dev Test ERC4626 standard compliance - convertToShares
     */
    function testConvertToSharesWithFees() public {
        // 1. Initial deposit by Alice
        vm.startPrank(address(coreVault));
        nft.mint(alice, 1);
        vm.stopPrank();
        
        vm.startPrank(alice);
        nft.approve(address(metavault), 1);
        uint256 aliceShares = metavault.deposit_nfts(toArray(1), alice);
        vm.stopPrank();
        
        // Verify initial 1:1 ratio
        assertEq(aliceShares, UNIT);
        assertEq(metavault.convertToShares(UNIT), UNIT);
        
        // 2. Bob buys the NFT with markup, generating fees
        vm.startPrank(address(coreVault));
        IMockERC20(vaultToken).mint(bob, UNIT * 2);
        vm.stopPrank();
        
        vm.startPrank(bob);
        IMockERC20(vaultToken).approve(address(metavault), UNIT * 2);
        uint256 pricePaid = metavault.purchase_nfts(toArray(1));
        vm.stopPrank();
        
        // Fee amount is the markup
        uint256 feeAmount = pricePaid - UNIT;
        
        // 3. Verify conversion rate changed due to fees
        // Now totalAssets = feeAmount, totalSupply = UNIT
        // So 1 token should convert to less than 1 share
        uint256 sharesPerToken = metavault.convertToShares(UNIT);
        assertLt(sharesPerToken, UNIT);
        
        // Precise calculation: shares = assets * totalSupply / totalAssets
        uint256 expectedShares = UNIT * UNIT / feeAmount;
        assertEq(sharesPerToken, expectedShares);
    }
    
    /**
     * @dev Test ERC4626 standard compliance - convertToAssets
     */
    function testConvertToAssetsWithFees() public {
        // 1. Initial deposit by Alice
        vm.startPrank(address(coreVault));
        nft.mint(alice, 1);
        vm.stopPrank();
        
        vm.startPrank(alice);
        nft.approve(address(metavault), 1);
        uint256 aliceShares = metavault.deposit_nfts(toArray(1), alice);
        vm.stopPrank();
        
        // Verify initial 1:1 ratio
        assertEq(aliceShares, UNIT);
        assertEq(metavault.convertToAssets(UNIT), UNIT);
        
        // 2. Bob buys the NFT with markup, generating fees
        vm.startPrank(address(coreVault));
        IMockERC20(vaultToken).mint(bob, UNIT * 2);
        vm.stopPrank();
        
        vm.startPrank(bob);
        IMockERC20(vaultToken).approve(address(metavault), UNIT * 2);
        uint256 pricePaid = metavault.purchase_nfts(toArray(1));
        vm.stopPrank();
        
        // Fee amount is the markup
        uint256 feeAmount = pricePaid - UNIT;
        
        // 3. Verify conversion rate changed due to fees
        // Now totalAssets = feeAmount, totalSupply = UNIT
        // So 1 share should convert to more than 1 token
        uint256 assetsPerShare = metavault.convertToAssets(UNIT);
        assertEq(assetsPerShare, feeAmount);
    }
    
    /**
     * @dev Test ERC4626 standard compliance - maxWithdraw and previewWithdraw
     */
    function testMaxWithdrawAndPreview() public {
        // 1. Initial deposit by Alice
        vm.startPrank(address(coreVault));
        nft.mint(alice, 1);
        vm.stopPrank();
        
        vm.startPrank(alice);
        nft.approve(address(metavault), 1);
        uint256 aliceShares = metavault.deposit_nfts(toArray(1), alice);
        vm.stopPrank();
        
        // 2. Verify maxWithdraw returns Alice's share of total assets
        uint256 maxWithdraw = metavault.maxWithdraw(alice);
        assertEq(maxWithdraw, UNIT);
        
        // 3. Generate fees through purchase
        vm.startPrank(address(coreVault));
        IMockERC20(vaultToken).mint(bob, UNIT * 2);
        vm.stopPrank();
        
        vm.startPrank(bob);
        IMockERC20(vaultToken).approve(address(metavault), UNIT * 2);
        uint256 pricePaid = metavault.purchase_nfts(toArray(1));
        vm.stopPrank();
        
        uint256 feeAmount = pricePaid - UNIT;
        
        // 4. After fees, Alice's maxWithdraw should be the fee amount
        maxWithdraw = metavault.maxWithdraw(alice);
        assertEq(maxWithdraw, feeAmount);
        
        // 5. previewWithdraw should show how many shares needed for a given asset amount
        uint256 sharesToBurn = metavault.previewWithdraw(feeAmount);
        assertEq(sharesToBurn, aliceShares);
    }
    
    /**
     * @dev Test the sequential deposit with fee in between scenario
     */
    function testSequentialDepositWithFeeInBetween() public {
        // 1. First user deposits
        vm.startPrank(address(coreVault));
        nft.mint(alice, 1);
        vm.stopPrank();
        
        vm.startPrank(alice);
        nft.approve(address(metavault), 1);
        uint256 aliceShares = metavault.deposit_nfts(toArray(1), alice);
        vm.stopPrank();
        
        // 2. Second user deposits
        vm.startPrank(address(coreVault));
        nft.mint(bob, 2);
        vm.stopPrank();
        
        vm.startPrank(bob);
        nft.approve(address(metavault), 2);
        uint256 bobShares = metavault.deposit_nfts(toArray(2), bob);
        vm.stopPrank();
        
        // Both should get the same shares per NFT ratio at this point
        assertEq(bobShares, aliceShares);
        
        // 3. Charlie buys an NFT, generating fees
        vm.startPrank(address(coreVault));
        IMockERC20(vaultToken).mint(charlie, UNIT * 2);
        vm.stopPrank();
        
        vm.startPrank(charlie);
        IMockERC20(vaultToken).approve(address(metavault), UNIT * 2);
        uint256 pricePaid = metavault.purchase_nfts(toArray(1));
        vm.stopPrank();
        
        uint256 feeAmount = pricePaid - UNIT;
        
        // 4. New user deposits after fees accumulated
        vm.startPrank(address(coreVault));
        nft.mint(address(0xdead), 3);
        vm.stopPrank();
        
        vm.startPrank(address(0xdead));
        nft.approve(address(metavault), 3);
        uint256 newShares = metavault.deposit_nfts(toArray(3), address(0xdead));
        vm.stopPrank();
        
        // New user should get fewer shares than previous users for the same amount of NFTs
        assertLt(newShares, aliceShares);
        
        // Calculate expected shares: assets * totalSupply / totalAssets
        // Now totalAssets = 1 NFT + fee amount, totalSupply = 2 * UNIT
        uint256 totalAssets = UNIT + feeAmount;
        uint256 totalSupply = 2 * UNIT; // Alice and Bob combined
        uint256 expectedShares = UNIT * totalSupply / totalAssets;
        assertEq(newShares, expectedShares);
    }
    
    /**
     * @dev Test redeem_for_tokens function
     */
    function testRedeemForTokens() public {
        // 1. Alice deposits an NFT
        vm.startPrank(address(coreVault));
        nft.mint(alice, 1);
        vm.stopPrank();
        
        vm.startPrank(alice);
        nft.approve(address(metavault), 1);
        uint256 aliceShares = metavault.deposit_nfts(toArray(1), alice);
        vm.stopPrank();
        
        // 2. Bob buys the NFT, generating fees
        vm.startPrank(address(coreVault));
        IMockERC20(vaultToken).mint(bob, UNIT * 2);
        vm.stopPrank();
        
        vm.startPrank(bob);
        IMockERC20(vaultToken).approve(address(metavault), UNIT * 2);
        uint256 pricePaid = metavault.purchase_nfts(toArray(1));
        vm.stopPrank();
        
        uint256 feeAmount = pricePaid - UNIT;
        
        // 3. Alice redeems half her shares for tokens
        uint256 sharesToRedeem = aliceShares / 2;
        uint256 expectedTokens = sharesToRedeem * feeAmount / aliceShares;
        
        vm.startPrank(alice);
        metavault.approve(address(metavault), sharesToRedeem);
        uint256 tokensReceived = metavault.redeem_for_tokens(sharesToRedeem, alice);
        vm.stopPrank();
        
        // Verify tokens received
        assertEq(tokensReceived, expectedTokens);
        assertEq(IMockERC20(vaultToken).balanceOf(alice), expectedTokens);
        
        // Verify shares were burned
        assertEq(metavault.balanceOf(alice), aliceShares - sharesToRedeem);
        
        // Verify accumulated fees were reduced
        assertEq(metavault.accumulated_fees(), feeAmount - expectedTokens);
    }
    
    /**
     * @dev Test claim_fees function
     */
    function testClaimFees() public {
        // 1. Alice deposits an NFT
        vm.startPrank(address(coreVault));
        nft.mint(alice, 1);
        vm.stopPrank();
        
        vm.startPrank(alice);
        nft.approve(address(metavault), 1);
        uint256 aliceShares = metavault.deposit_nfts(toArray(1), alice);
        vm.stopPrank();
        
        // 2. Bob buys the NFT, generating fees
        vm.startPrank(address(coreVault));
        IMockERC20(vaultToken).mint(bob, UNIT * 2);
        vm.stopPrank();
        
        vm.startPrank(bob);
        IMockERC20(vaultToken).approve(address(metavault), UNIT * 2);
        uint256 pricePaid = metavault.purchase_nfts(toArray(1));
        vm.stopPrank();
        
        uint256 feeAmount = pricePaid - UNIT;
        
        // 3. Alice claims her fees
        uint256 expectedFees = metavault.get_user_fee_share(alice);
        assertEq(expectedFees, feeAmount); // Alice should get all fees as the only shareholder
        
        vm.startPrank(alice);
        uint256 claimedFees = metavault.claim_fees();
        vm.stopPrank();
        
        // Verify fees claimed
        assertEq(claimedFees, expectedFees);
        assertEq(IMockERC20(vaultToken).balanceOf(alice), claimedFees);
        
        // Verify accumulated fees were reduced
        assertEq(metavault.accumulated_fees(), 0);
    }
    
    /**
     * @dev Test multiple depositors and fee distribution
     */
    function testMultipleDepositorsAndFeeDistribution() public {
        // 1. Alice and Bob both deposit an NFT
        vm.startPrank(address(coreVault));
        nft.mint(alice, 1);
        nft.mint(bob, 2);
        vm.stopPrank();
        
        vm.startPrank(alice);
        nft.approve(address(metavault), 1);
        uint256 aliceShares = metavault.deposit_nfts(toArray(1), alice);
        vm.stopPrank();
        
        vm.startPrank(bob);
        nft.approve(address(metavault), 2);
        uint256 bobShares = metavault.deposit_nfts(toArray(2), bob);
        vm.stopPrank();
        
        // 2. Charlie buys one of the NFTs
        vm.startPrank(address(coreVault));
        IMockERC20(vaultToken).mint(charlie, UNIT * 2);
        vm.stopPrank();
        
        vm.startPrank(charlie);
        IMockERC20(vaultToken).approve(address(metavault), UNIT * 2);
        uint256 pricePaid = metavault.purchase_nfts(toArray(1));
        vm.stopPrank();
        
        uint256 feeAmount = pricePaid - UNIT;
        
        // 3. Verify fee shares
        uint256 totalShares = aliceShares + bobShares;
        uint256 aliceFeeShare = aliceShares * feeAmount / totalShares;
        uint256 bobFeeShare = bobShares * feeAmount / totalShares;
        
        assertEq(metavault.get_user_fee_share(alice), aliceFeeShare);
        assertEq(metavault.get_user_fee_share(bob), bobFeeShare);
        
        // 4. Alice claims her fees
        vm.startPrank(alice);
        uint256 aliceClaimedFees = metavault.claim_fees();
        vm.stopPrank();
        
        assertEq(aliceClaimedFees, aliceFeeShare);
        assertEq(IMockERC20(vaultToken).balanceOf(alice), aliceFeeShare);
        
        // 5. Bob withdraws with his NFT + fees
        vm.startPrank(bob);
        metavault.approve(address(metavault), bobShares);
        (uint256 sharesBurned, uint256 feeTokensClaimed) = metavault.withdraw_nfts(toArray(2), true, bob);
        vm.stopPrank();
        
        assertEq(feeTokensClaimed, bobFeeShare);
        assertEq(IMockERC20(vaultToken).balanceOf(bob), bobFeeShare);
        
        // 6. Verify all fees are now distributed
        assertEq(metavault.accumulated_fees(), 0);
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