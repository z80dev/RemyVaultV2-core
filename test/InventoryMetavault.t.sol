// SPDX-License-Identifier: MIT
pragma solidity ^0.8.13;

import "forge-std/Test.sol";
import "src/interfaces/IInventoryMetavault.sol";
import "src/interfaces/IRemyVault.sol";
import "src/interfaces/IERC20.sol";
import "src/interfaces/IERC4626.sol";
import {ReentrancyAttacker} from "./helpers/ReentrancyAttacker.sol";

// Additional ERC20 functions for our mock tokens
interface IMockERC20 is IERC20 {
    function mint(address to, uint256 value) external;
    function burn(uint256 amount) external;
}

interface IManagedToken is IERC20 {
    function mint(address to, uint256 amount) external;
    function burn(address from, uint256 amount) external;
    function manager() external view returns (address);
    function change_manager(address new_manager) external;
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
 * This test suite validates all aspects of the NFT Staking Metavault protocol including:
 * - Basic deposit/withdraw functionality
 * - NFT tracking and management
 * - ERC20 balance invariants
 * - Core vault integration
 * - StakingVault compliance
 */
contract InventoryMetavaultTest is Test {
    // Mock ERC721 token for NFTs
    IMockERC721 public nft;

    // Mock ERC20 token for core vault
    IMockERC20 public vaultToken;

    // RemyVault contract instance
    IRemyVault public coreVault;

    // ManagedToken (mvREMY) contract instance
    IManagedToken public mvREMY;

    // StakingVault (ERC4626) contract instance
    IERC4626 public stakingVault;

    // InventoryMetavault contract instance
    IInventoryMetavault public metavault;

    // Test user addresses
    address public alice;
    address public bob;
    address public charlie;
    address public owner;

    // Unit value constant from the Remy protocol
    uint256 constant UNIT = 1000 * 10 ** 18;

    // Purchase markup in the metavault (10%)
    uint256 constant MARKUP_BPS = 1000;
    uint256 constant BPS_DENOMINATOR = 10000;

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
        nft = IMockERC721(deployCode("src/mock/MockERC721.vy", abi.encode("MOCK", "MOCK", "https://", "MOCK", "1.0")));
        vaultToken = IMockERC20(deployCode("src/mock/MockERC20.vy", abi.encode("REMY", "REMY", 18, "REMY Token", "1.0")));

        // Deploy core vault
        coreVault = IRemyVault(deployCode("src/RemyVault.vy", abi.encode(address(vaultToken), address(nft))));

        // Transfer ownership of tokens to the vault
        vm.prank(owner);
        Ownable(address(vaultToken)).transfer_ownership(address(coreVault));

        vm.prank(owner);
        Ownable(address(nft)).transfer_ownership(address(coreVault));

        // Deploy mvREMY token (managed token)
        mvREMY = IManagedToken(deployCode("src/ManagedToken.vy", abi.encode("Managed Vault REMY", "mvREMY", owner)));

        // Deploy StakingVault
        stakingVault = IERC4626(
            deployCode(
                "src/StakingVault.vy",
                abi.encode("Staking Metavault", "stMV", address(mvREMY), 0, "Metavault Staking", "1")
            )
        );

        // Deploy InventoryMetavault
        metavault = IInventoryMetavault(
            deployCode(
                "src/InventoryMetavault.vy", abi.encode(address(coreVault), address(mvREMY), address(stakingVault))
            )
        );

        // Transfer management of mvREMY to the metavault
        vm.prank(owner);
        mvREMY.change_manager(address(metavault));
    }

    /**
     * @dev Test basic setup of the metavault
     */
    function testSetup() public {
        // Print debug information
        console.log("metavault.remy_vault():", metavault.remy_vault());
        console.log("expected remy_vault:", address(coreVault));
        console.log("metavault.internal_token():", metavault.internal_token());
        console.log("expected internal_token:", address(mvREMY));
        console.log("metavault.staking_vault():", metavault.staking_vault());
        console.log("expected staking_vault:", address(stakingVault));

        // Verify metavault references are correct
        assertEq(metavault.remy_vault(), address(coreVault));
        assertEq(metavault.internal_token(), address(mvREMY));
        assertEq(metavault.staking_vault(), address(stakingVault));
        assertEq(metavault.nft_collection(), address(nft));

        // Verify mvREMY token management
        assertEq(mvREMY.manager(), address(metavault));

        // Verify initial inventory is empty
        assertEq(metavault.get_available_inventory(), 0);

        // Verify markup is set to the default
        assertEq(metavault.MARKUP_BPS(), MARKUP_BPS);

        // Verify ERC4626 specific setup for StakingVault
        assertEq(stakingVault.name(), "Staking Metavault");
        assertEq(stakingVault.symbol(), "stMV");
        assertEq(stakingVault.decimals(), 18);
        assertEq(stakingVault.totalSupply(), 0);
        assertEq(stakingVault.totalAssets(), 0);
    }


    /**
     * @dev Test depositing NFTs into the metavault
     */
    function testDepositNFTs() public {
        // Mint an NFT to Alice
        vm.startPrank(address(coreVault));
        nft.mint(alice, 1);
        vm.stopPrank();

        // Alice approves the metavault to transfer her NFT
        vm.startPrank(alice);
        nft.setApprovalForAll(address(metavault), true);

        // Alice deposits the NFT
        uint256[] memory tokenIds = toArray(1);
        uint256 sharesMinted = metavault.deposit_nfts(tokenIds, alice);
        vm.stopPrank();

        // Verify NFT is now in the metavault's inventory
        assertTrue(metavault.is_token_in_inventory(1));
        assertEq(metavault.get_available_inventory(), 1);

        // Verify Alice received shares from the deposit
        assertEq(sharesMinted, UNIT);  // Should be 1000 REMY worth
        assertEq(stakingVault.balanceOf(alice), UNIT);

        // Verify internal accounting is correct
        assertEq(nft.ownerOf(1), address(metavault));
        assertEq(mvREMY.totalSupply(), UNIT);
    }

    /**
     * @dev Test depositing multiple NFTs in a batch
     */
    function testBatchDepositNFTs() public {
        // Mint several NFTs to Alice
        vm.startPrank(address(coreVault));
        for (uint256 i = 1; i <= 5; i++) {
            nft.mint(alice, i);
        }
        vm.stopPrank();

        // Alice approves and deposits multiple NFTs
        vm.startPrank(alice);
        nft.setApprovalForAll(address(metavault), true);

        uint256[] memory tokenIds = new uint256[](5);
        for (uint256 i = 0; i < 5; i++) {
            tokenIds[i] = i + 1;
        }

        uint256 sharesMinted = metavault.deposit_nfts(tokenIds, alice);
        vm.stopPrank();

        // Verify NFTs are in inventory
        assertEq(metavault.get_available_inventory(), 5);

        // Verify Alice received the correct amount of shares
        assertEq(sharesMinted, 5 * UNIT);
        assertEq(stakingVault.balanceOf(alice), 5 * UNIT);

        // Verify internal accounting
        assertEq(mvREMY.totalSupply(), 5 * UNIT);
    }

    function testRedeemForAssets() public {
        // Setup: Alice deposits an NFT
        vm.startPrank(address(coreVault));
        nft.mint(alice, 1);
        vm.stopPrank();

        vm.startPrank(alice);
        nft.setApprovalForAll(address(metavault), true);
        metavault.deposit_nfts(toArray(1), alice);

        // Alice redeems her shares
        // approve the staking vault to transfer shares
        stakingVault.approve(address(metavault), UNIT);
        uint256 assetsRedeemed = metavault.redeem_for_assets(UNIT, alice);
        vm.stopPrank();

        // Verify assets were redeemed correctly
        assertEq(assetsRedeemed, UNIT);
        assertEq(nft.ownerOf(1), alice);
        assertEq(stakingVault.balanceOf(alice), 0);
    }

    /**
     * @dev Test purchasing NFTs from the metavault
     */
    function testPurchaseNFTs() public {
        // Setup: Alice deposits an NFT
        vm.startPrank(address(coreVault));
        nft.mint(alice, 1);
        vm.stopPrank();

        vm.startPrank(alice);
        nft.setApprovalForAll(address(metavault), true);
        metavault.deposit_nfts(toArray(1), alice);
        vm.stopPrank();

        // Bob gets REMY tokens and purchases the NFT
        uint256 purchasePrice = UNIT * (10000 + MARKUP_BPS) / 10000; // 1100 REMY
        vm.prank(address(coreVault));
        vaultToken.mint(bob, purchasePrice);

        vm.startPrank(bob);
        vaultToken.approve(address(metavault), purchasePrice);
        uint256 totalPaid = metavault.purchase_nfts(toArray(1));
        vm.stopPrank();

        // Verify purchase was successful
        assertEq(totalPaid, purchasePrice);
        assertEq(nft.ownerOf(1), bob);
        assertFalse(metavault.is_token_in_inventory(1));

        // Verify the purchasePrice remains in the metavault
        assertEq(vaultToken.balanceOf(address(metavault)), purchasePrice);

        // Verify Alice's shares still have value (now backed by REMY tokens)
        // And that their value has increased due to the premium
        assertEq(stakingVault.balanceOf(alice), UNIT);
        
        // The premium is now properly distributed to shareholders
        uint256 premium = UNIT * MARKUP_BPS / BPS_DENOMINATOR; // 100 REMY
        uint256 expectedAssetValue = UNIT + premium; // 1100 REMY
        
        uint256 actualAssetValue = metavault.convertToAssets(UNIT);
        assertApproxEqAbs(actualAssetValue, expectedAssetValue, 1); // Allow small rounding error
    }

    /**
     * @dev Test batch purchasing multiple NFTs
     */
    function testBatchPurchaseNFTs() public {
        // Setup: Alice deposits multiple NFTs
        vm.startPrank(address(coreVault));
        for (uint256 i = 1; i <= 3; i++) {
            nft.mint(alice, i);
        }
        vm.stopPrank();

        vm.startPrank(alice);
        nft.setApprovalForAll(address(metavault), true);
        uint256[] memory depositIds = new uint256[](3);
        for (uint256 i = 0; i < 3; i++) {
            depositIds[i] = i + 1;
        }
        metavault.deposit_nfts(depositIds, alice);
        vm.stopPrank();

        // Bob purchases two of the NFTs
        uint256[] memory purchaseIds = toArray2(1, 2);
        uint256 purchasePrice = 2 * UNIT * (10000 + MARKUP_BPS) / 10000; // 2200 REMY

        vm.prank(address(coreVault));
        vaultToken.mint(bob, purchasePrice);

        vm.startPrank(bob);
        vaultToken.approve(address(metavault), purchasePrice);
        uint256 totalPaid = metavault.purchase_nfts(purchaseIds);
        vm.stopPrank();

        // Verify purchase results
        assertEq(totalPaid, purchasePrice);
        assertEq(nft.ownerOf(1), bob);
        assertEq(nft.ownerOf(2), bob);
        assertEq(nft.ownerOf(3), address(metavault));

        // Verify inventory state
        assertEq(metavault.get_available_inventory(), 1);
        assertTrue(metavault.is_token_in_inventory(3));

        // The metavault now holds the full purchase price
        uint256 purchaseAmount = 2 * UNIT * (10000 + MARKUP_BPS) / 10000;
        assertEq(vaultToken.balanceOf(address(metavault)), purchaseAmount);
    }

    /**
     * @dev Test quoting a purchase price
     */
    function testQuotePurchase() public {
        // Verify that quoting works with correct markup
        uint256 price = metavault.quote_purchase(1);
        assertEq(price, UNIT * (10000 + MARKUP_BPS) / 10000);

        // Test with multiple NFTs
        price = metavault.quote_purchase(5);
        assertEq(price, 5 * UNIT * (10000 + MARKUP_BPS) / 10000);
    }

    /**
     * @dev Test converting between shares and assets
     */
    function testConversions() public {
        // Setup: Add assets to the metavault
        vm.startPrank(address(coreVault));
        nft.mint(alice, 1);
        vm.stopPrank();

        vm.startPrank(alice);
        nft.setApprovalForAll(address(metavault), true);
        metavault.deposit_nfts(toArray(1), alice);
        vm.stopPrank();

        // Test initial conversion (should be 1:1 initially)
        assertEq(metavault.convertToShares(UNIT), UNIT);
        assertEq(metavault.convertToAssets(UNIT), UNIT);

        // Record the initial total supply
        uint256 initialTotalSupply = mvREMY.totalSupply();
        assertEq(initialTotalSupply, UNIT);

        // Add premium (through purchase)
        uint256 purchasePrice = UNIT * (10000 + MARKUP_BPS) / 10000; // 1100 REMY
        uint256 premium = UNIT * MARKUP_BPS / BPS_DENOMINATOR; // 100 REMY
        vm.prank(address(coreVault));
        vaultToken.mint(bob, purchasePrice);

        vm.startPrank(bob);
        vaultToken.approve(address(metavault), purchasePrice);
        metavault.purchase_nfts(toArray(1));
        vm.stopPrank();

        // Get the current conversion rate after the purchase
        uint256 assetValue = metavault.convertToAssets(UNIT);
        console.log("Asset value for 1 UNIT of shares:", assetValue);
        
        // After purchase:
        // 1. The NFT is gone, replaced by 1000 REMY in the metavault
        // 2. 100 REMY worth of premium has been converted to mvREMY and staked
        // 3. Total mvREMY supply is now 1000 (initial) + 100 (premium) = 1100
        // 4. StakingVault shares (stMV) for Alice remain at 1000
        // 5. Since there are now 1100 mvREMY backing 1000 stMV shares, each share is worth 1.1 mvREMY

        // Debug StakingVault state
        uint256 totalMvREMY = mvREMY.totalSupply();
        uint256 stakingVaultBalance = mvREMY.balanceOf(address(stakingVault));
        uint256 totalShares = stakingVault.totalSupply();
        
        console.log("Total mvREMY supply:", totalMvREMY);
        console.log("StakingVault mvREMY balance:", stakingVaultBalance);
        console.log("Total stMV shares:", totalShares);
        
        // Debug conversion rates
        uint256 directConversion = stakingVault.convertToAssets(UNIT);
        console.log("Direct StakingVault convertToAssets(UNIT):", directConversion);
        
        // Verify total mvREMY supply increased by the premium amount
        assertEq(mvREMY.totalSupply(), initialTotalSupply + premium);
        
        // We expect that StakingVault's mvREMY balance should match the total supply
        assertEq(stakingVaultBalance, totalMvREMY);
        
        // Check asset value has increased due to the premium being staked
        uint256 expectedValue = UNIT * (10000 + MARKUP_BPS) / 10000; // 1100 REMY
        assertApproxEqAbs(assetValue, expectedValue, 10); // Allow rounding errors
        
        // Converting in the other direction
        // 1100 REMY should convert to approximately 1000 shares
        uint256 sharesForPurchasePrice = metavault.convertToShares(purchasePrice);
        
        // Expected conversion: 1100 REMY corresponds to approximately 1000 shares
        // after accounting for the premium added to the StakingVault
        uint256 expectedShares = UNIT;
        assertApproxEqAbs(sharesForPurchasePrice, expectedShares, 10); // Allow small rounding errors
    }

    /**
     * @dev Test yield accumulation after multiple NFT purchases
     */
    function testYieldAccumulation() public {
        // Setup: Alice deposits 5 NFTs
        vm.startPrank(address(coreVault));
        for (uint256 i = 1; i <= 5; i++) {
            nft.mint(alice, i);
        }
        vm.stopPrank();

        vm.startPrank(alice);
        nft.setApprovalForAll(address(metavault), true);
        uint256[] memory aliceIds = new uint256[](5);
        for (uint256 i = 0; i < 5; i++) {
            aliceIds[i] = i + 1;
        }
        metavault.deposit_nfts(aliceIds, alice);
        vm.stopPrank();

        // Record Alice's initial share value
        uint256 initialShareValue = metavault.convertToAssets(UNIT);
        console.log("Initial value of 1 UNIT of shares:", initialShareValue);
        assertEq(initialShareValue, UNIT);
        
        // Bob buys NFT #1 (10% premium)
        uint256 purchasePrice = UNIT * (10000 + MARKUP_BPS) / 10000;
        vm.prank(address(coreVault));
        vaultToken.mint(bob, purchasePrice);
        
        vm.startPrank(bob);
        vaultToken.approve(address(metavault), purchasePrice);
        metavault.purchase_nfts(toArray(1));
        vm.stopPrank();
        
        // Check Alice's share value after first purchase
        uint256 valueAfterFirstPurchase = metavault.convertToAssets(UNIT);
        console.log("Share value after first purchase:", valueAfterFirstPurchase);
        
        // Value should have increased by approximately 2% (100 REMY premium distributed across 5000 shares)
        // Expected: ~1020 REMY per 1000 shares
        uint256 expectedFirstIncrease = initialShareValue + (UNIT * MARKUP_BPS / BPS_DENOMINATOR / 5);
        assertApproxEqAbs(valueAfterFirstPurchase, expectedFirstIncrease, 10);
        
        // Charlie buys NFT #2 (10% premium)
        vm.prank(address(coreVault));
        vaultToken.mint(charlie, purchasePrice);
        
        vm.startPrank(charlie);
        vaultToken.approve(address(metavault), purchasePrice);
        metavault.purchase_nfts(toArray(2));
        vm.stopPrank();
        
        // Check Alice's share value after second purchase
        uint256 valueAfterSecondPurchase = metavault.convertToAssets(UNIT);
        console.log("Share value after second purchase:", valueAfterSecondPurchase);
        
        // Value should have increased again
        assertGt(valueAfterSecondPurchase, valueAfterFirstPurchase);
        
        // Bob buys NFT #3 (10% premium)
        vm.prank(address(coreVault));
        vaultToken.mint(bob, purchasePrice);
        
        vm.startPrank(bob);
        vaultToken.approve(address(metavault), purchasePrice);
        metavault.purchase_nfts(toArray(3));
        vm.stopPrank();
        
        // Check Alice's share value after third purchase
        uint256 valueAfterThirdPurchase = metavault.convertToAssets(UNIT);
        console.log("Share value after third purchase:", valueAfterThirdPurchase);
        
        // Value should have increased again
        assertGt(valueAfterThirdPurchase, valueAfterSecondPurchase);
        
        // Calculate total yield (in percentage terms)
        uint256 totalYieldBips = (valueAfterThirdPurchase - UNIT) * BPS_DENOMINATOR / UNIT;
        console.log("Total yield in basis points:", totalYieldBips);
        
        // After 3 NFT purchases with 10% premium each, we should have accumulated approximately 
        // 300 REMY in premiums distributed across remaining 2000 UNIT of shares
        // Expected yield: ~15% (1500 basis points)
        assertGt(totalYieldBips, 0);
        
        // Instead of actual withdrawal, let's calculate how many shares would be needed 
        // for a specific amount of assets
        uint256 assetAmount = 2 * UNIT; // 2000 REMY
        uint256 sharesNeeded = metavault.convertToShares(assetAmount);
        console.log("Shares needed for 2000 REMY after yield accumulation:", sharesNeeded);
        
        // At the beginning, 2000 REMY would require 2000 shares (1:1)
        // After yield accumulation, we should need fewer shares
        uint256 originalSharesNeeded = 2 * UNIT;
        console.log("Original shares needed for 2000 REMY:", originalSharesNeeded);
        
        // Verify fewer shares are now needed to represent the same asset value
        assertLt(sharesNeeded, originalSharesNeeded);
        
        // Calculate the efficiency gain (how many fewer shares needed)
        uint256 efficiencyGainBips = (originalSharesNeeded - sharesNeeded) * BPS_DENOMINATOR / originalSharesNeeded;
        console.log("Efficiency gain in basis points:", efficiencyGainBips);
        
        // This should approximately match our yield calculation
        // Allow for some rounding differences in calculations
        assertApproxEqAbs(efficiencyGainBips, totalYieldBips, 50);
    }
    
    /**
     * @dev Test failure cases
     */
    function testAllFailureCases() public {
        // Test depositing non-existent NFT
        vm.startPrank(alice);
        vm.expectRevert();
        metavault.deposit_nfts(toArray(999), alice);
        vm.stopPrank();

        // Test withdrawing NFT not in inventory
        vm.startPrank(address(coreVault));
        nft.mint(alice, 1);
        vm.stopPrank();

        vm.startPrank(alice);
        nft.setApprovalForAll(address(metavault), true);
        metavault.deposit_nfts(toArray(1), alice);

        vm.expectRevert();
        metavault.withdraw_nfts(toArray(2), alice);
        vm.stopPrank();

        // Test purchasing NFT not in inventory
        vm.prank(address(coreVault));
        vaultToken.mint(bob, 10000 * 10**18);

        vm.startPrank(bob);
        vaultToken.approve(address(metavault), 10000 * 10**18);

        vm.expectRevert();
        metavault.purchase_nfts(toArray(999));
        vm.stopPrank();

        // Test redeeming more shares than owned
        vm.startPrank(alice);
        uint256 aliceShares = stakingVault.balanceOf(alice);

        vm.expectRevert();
        metavault.redeem_for_assets(aliceShares + 1, alice);
        vm.stopPrank();
    }

    // Helper function to convert a single uint256 to an array
    function toArray(uint256 value) internal pure returns (uint256[] memory) {
        uint256[] memory arr = new uint256[](1);
        arr[0] = value;
        return arr;
    }

    // Helper function to convert two uint256 values to an array
    function toArray2(uint256 value1, uint256 value2) internal pure returns (uint256[] memory) {
        uint256[] memory arr = new uint256[](2);
        arr[0] = value1;
        arr[1] = value2;
        return arr;
    }

    function onERC721Received(
        address operator,
        address from,
        uint256 tokenId,
        bytes calldata data
    ) external pure returns (bytes4) {
        return 0x150b7a02;
    }
}

interface Ownable {
    function owner() external view returns (address);
    function transfer_ownership(address newOwner) external;
}
