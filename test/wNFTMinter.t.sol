// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";

import {wNFTMinter} from "../src/wNFTMinter.sol";
import {wNFTNFT} from "../src/wNFTNFT.sol";

contract MinterRemyVaultTest is Test {
    wNFTMinter internal vault;
    wNFTNFT internal nft;
    address internal alice;
    address internal bob;

    function setUp() public {
        alice = makeAddr("alice");
        bob = makeAddr("bob");
        nft = new wNFTNFT("Derivative", "DRV", "ipfs://", address(this));
        vault = new wNFTMinter(address(nft), 10);
        nft.setMinter(address(vault), true);
    }

    function onERC721Received(address, address, uint256, bytes calldata) external pure returns (bytes4) {
        return this.onERC721Received.selector;
    }

    function testConstructorPreMintsSupply() public {
        uint256 expectedSupply = vault.UNIT() * 10;
        assertEq(vault.totalSupply(), expectedSupply, "total supply mismatch");
        assertEq(vault.balanceOf(address(this)), expectedSupply, "creator balance mismatch");
        assertEq(vault.maxSupply(), 10, "max supply mismatch");
        assertEq(vault.name(), string.concat("Wrapped ", nft.name()), "vault should mirror NFT name");
        assertEq(vault.symbol(), string.concat("w", nft.symbol()), "vault should mirror NFT symbol");
    }

    function testConstructorWithZeroMaxSupply() public {
        wNFTNFT zeroNft = new wNFTNFT("Zero", "ZERO", "ipfs://", address(this));
        wNFTMinter zeroVault = new wNFTMinter(address(zeroNft), 0);

        assertEq(zeroVault.totalSupply(), 0, "should have zero supply");
        assertEq(zeroVault.maxSupply(), 0, "should have zero max supply");
        assertEq(zeroVault.mintedCount(), 0, "should have zero minted count");
    }

    function testConstructorSupplyOverflow() public {
        wNFTNFT overflowNft = new wNFTNFT("Overflow", "OVR", "ipfs://", address(this));

        // Try to create vault with maxSupply that would overflow when multiplied by UNIT
        uint256 overflowSupply = type(uint256).max / vault.UNIT() + 1;

        vm.expectRevert(wNFTMinter.SupplyOverflow.selector);
        new wNFTMinter(address(overflowNft), overflowSupply);
    }

    function testMintBurnsAndIssuesNfts() public {
        uint256 cost = 2 * vault.UNIT();
        vault.transfer(alice, cost);

        vm.prank(alice);
        uint256[] memory mintedIds = vault.mint(2, alice);
        assertEq(mintedIds.length, 2, "mint count mismatch");
        assertEq(vault.balanceOf(alice), 0, "tokens not burned");
        assertEq(nft.balanceOf(alice), 2, "nfts not received");
        assertEq(vault.mintedCount(), 2, "mint counter mismatch");
    }

    function testMintSingleNFT() public {
        uint256 cost = 1 * vault.UNIT();
        vault.transfer(alice, cost);

        vm.prank(alice);
        uint256[] memory mintedIds = vault.mint(1, alice);

        assertEq(mintedIds.length, 1, "should mint exactly one");
        assertEq(vault.balanceOf(alice), 0, "tokens should be burned");
        assertEq(nft.balanceOf(alice), 1, "should receive one NFT");
        assertEq(vault.mintedCount(), 1, "counter should be 1");
    }

    function testMintToMultipleRecipients() public {
        uint256 cost = 3 * vault.UNIT();

        // Distribute tokens to different users
        vault.transfer(alice, cost);
        vault.transfer(bob, cost);

        // Each user mints independently
        vm.prank(alice);
        uint256[] memory aliceMints = vault.mint(3, alice);

        vm.prank(bob);
        uint256[] memory bobMints = vault.mint(3, bob);

        assertEq(aliceMints.length, 3);
        assertEq(bobMints.length, 3);
        assertEq(nft.balanceOf(alice), 3);
        assertEq(nft.balanceOf(bob), 3);
        assertEq(vault.mintedCount(), 6);
    }

    function testMintExactlyAtLimit() public {
        uint256 cost = 10 * vault.UNIT();

        vm.prank(address(this));
        uint256[] memory mintedIds = vault.mint(10, address(this));

        assertEq(mintedIds.length, 10, "should mint all 10");
        assertEq(vault.mintedCount(), 10, "should reach exact limit");
        assertEq(nft.balanceOf(address(this)), 10, "should receive all 10 NFTs");
    }

    function testMintLimitEnforced() public {
        vm.prank(address(this));
        vault.mint(10, address(this));

        vm.expectRevert(wNFTMinter.MintLimitExceeded.selector);
        vault.mint(1, address(this));
    }

    function testMintExceedsLimitByMultiple() public {
        vm.prank(address(this));
        vault.mint(5, address(this));

        // Try to mint 6 more when only 5 remain
        vm.expectRevert(wNFTMinter.MintLimitExceeded.selector);
        vault.mint(6, address(this));
    }

    function testMintWithoutEnoughTokens() public {
        uint256 cost = 5 * vault.UNIT();
        vault.transfer(alice, cost - 1); // Transfer 1 wei less than needed

        vm.prank(alice);
        vm.expectRevert(); // ERC20 InsufficientBalance
        vault.mint(5, alice);
    }

    function testMintCounterTracking() public {
        assertEq(vault.mintedCount(), 0, "should start at 0");

        vault.mint(3, address(this));
        assertEq(vault.mintedCount(), 3, "should be 3 after first mint");

        vault.mint(2, address(this));
        assertEq(vault.mintedCount(), 5, "should be 5 after second mint");

        vault.mint(5, address(this));
        assertEq(vault.mintedCount(), 10, "should be 10 after third mint");
    }

    function testDepositAndWithdrawFlow() public {
        // Must mint 99% (10 NFTs) before deposits are allowed
        uint256[] memory allTokenIds = vault.mint(10, address(this));

        // Now deposits should work - deposit 2 NFTs
        uint256[] memory tokenIds = new uint256[](2);
        tokenIds[0] = allTokenIds[0];
        tokenIds[1] = allTokenIds[1];

        nft.setApprovalForAll(address(vault), true);
        uint256 balanceBefore = vault.balanceOf(address(this));
        uint256 mintedAmount = vault.deposit(tokenIds, address(this));
        assertEq(mintedAmount, 2 * vault.UNIT(), "deposit mint mismatch");
        assertEq(vault.balanceOf(address(this)) - balanceBefore, mintedAmount, "deposit balance mismatch");

        vault.withdraw(tokenIds, address(this));
        assertEq(vault.balanceOf(address(this)), balanceBefore, "withdraw balance mismatch");
    }

    function testMintDepositWithdrawCycle() public {
        // Must mint 99% first (10 NFTs for maxSupply=10)
        uint256[] memory allTokenIds = vault.mint(10, address(this));
        assertEq(nft.balanceOf(address(this)), 10);

        // Now deposits are allowed - deposit 5 NFTs
        uint256[] memory tokenIds = new uint256[](5);
        for (uint256 i = 0; i < 5; i++) {
            tokenIds[i] = allTokenIds[i];
        }

        nft.setApprovalForAll(address(vault), true);
        uint256 balanceBefore = vault.balanceOf(address(this));
        vault.deposit(tokenIds, address(this));
        assertEq(vault.balanceOf(address(this)), balanceBefore + 5 * vault.UNIT());

        // Withdraw them again
        vault.withdraw(tokenIds, address(this));
        assertEq(vault.balanceOf(address(this)), balanceBefore);
        assertEq(nft.balanceOf(address(this)), 10);

        // Mint counter should still be at 10
        assertEq(vault.mintedCount(), 10);
    }

    function testCannotMintAfterReachingLimit() public {
        // Mint all 10 (this also unlocks deposits since 100% > 99%)
        vault.mint(10, address(this));

        // Deposits are now allowed - deposit some NFTs to get tokens back
        uint256[] memory someIds = new uint256[](2);
        someIds[0] = 0;
        someIds[1] = 1;
        nft.setApprovalForAll(address(vault), true);
        vault.deposit(someIds, address(this));

        // Now have tokens but still cannot mint more NFTs
        vm.expectRevert(wNFTMinter.MintLimitExceeded.selector);
        vault.mint(1, address(this));
    }

    function testMintZeroRecipientReverts() public {
        vm.expectRevert(wNFTMinter.RecipientZero.selector);
        vault.mint(1, address(0));
    }

    function testMintZeroCountReverts() public {
        vm.expectRevert(wNFTMinter.MintZeroCount.selector);
        vault.mint(0, address(this));
    }

    function testFuzz_MintValidAmounts(uint256 amount) public {
        // Bound to valid range: 1 to maxSupply
        amount = bound(amount, 1, vault.maxSupply());

        uint256 cost = amount * vault.UNIT();

        vm.prank(address(this));
        uint256[] memory mintedIds = vault.mint(amount, address(this));

        assertEq(mintedIds.length, amount);
        assertEq(vault.mintedCount(), amount);
        assertEq(nft.balanceOf(address(this)), amount);
    }

    function testFuzz_CannotExceedLimit(uint256 firstMint, uint256 secondMint) public {
        // Bound first mint to 1..maxSupply
        firstMint = bound(firstMint, 1, vault.maxSupply());
        // Bound second mint to exceed remaining capacity
        secondMint = bound(secondMint, vault.maxSupply() - firstMint + 1, vault.maxSupply() * 2);

        vault.mint(firstMint, address(this));

        vm.expectRevert(wNFTMinter.MintLimitExceeded.selector);
        vault.mint(secondMint, address(this));
    }

    function testFuzz_MultipleMintsUpToLimit(uint256 count1, uint256 count2, uint256 count3) public {
        uint256 maxSupply = vault.maxSupply();

        // Ensure counts sum to maxSupply
        count1 = bound(count1, 1, maxSupply / 3);
        count2 = bound(count2, 1, (maxSupply - count1) / 2);
        count3 = maxSupply - count1 - count2;

        vm.assume(count3 > 0);

        vault.mint(count1, address(this));
        vault.mint(count2, address(this));
        vault.mint(count3, address(this));

        assertEq(vault.mintedCount(), maxSupply);
        assertEq(nft.balanceOf(address(this)), maxSupply);
    }

    function testEmittedEventOnMint() public {
        uint256[] memory expectedIds = new uint256[](3);
        expectedIds[0] = 0;
        expectedIds[1] = 1;
        expectedIds[2] = 2;

        vm.expectEmit(true, false, false, true);
        emit wNFTMinter.DerivativeMint(address(this), 3, expectedIds);

        vault.mint(3, address(this));
    }

    function testBatchMintGasConsistency() public {
        uint256 gasBefore = gasleft();
        vault.mint(5, address(this));
        uint256 gasUsed = gasBefore - gasleft();

        // Ensure reasonable gas usage (rough check)
        assertLt(gasUsed, 2_000_000, "gas usage too high for batch mint");
    }

    function testMaxSupplyImmutable() public view {
        assertEq(vault.maxSupply(), 10, "maxSupply should be immutable");
    }

    function testUnitConstant() public view {
        assertEq(vault.UNIT(), 1e18, "UNIT should be 1e18");
    }

    function testInvariant_TotalSupplyMatchesFormula() public {
        uint256 maxSupply = vault.maxSupply();
        uint256 expectedTotalSupply = maxSupply * vault.UNIT();

        // Total supply should equal maxSupply * UNIT (accounting for mints/burns)
        uint256 totalSupply = vault.totalSupply();
        uint256 mintedCount = vault.mintedCount();

        // totalSupply = (maxSupply - mintedCount) * UNIT + deposited NFTs * UNIT
        // On setup: totalSupply = maxSupply * UNIT (all pre-minted)
        assertEq(totalSupply, expectedTotalSupply - (mintedCount * vault.UNIT()));
    }

    function testDepositLockedBefore99PercentMinted() public {
        // Mint only 5 out of 10 (50%)
        uint256[] memory tokenIds = vault.mint(5, address(this));
        nft.setApprovalForAll(address(vault), true);

        // Try to deposit - should revert
        vm.expectRevert(wNFTMinter.DepositsLocked.selector);
        vault.deposit(tokenIds, address(this));
    }

    function testDepositLockedAt98Percent() public {
        // Create vault with larger maxSupply for better precision testing
        wNFTNFT largeNft = new wNFTNFT("Large", "LRG", "ipfs://", address(this));
        wNFTMinter largeVault = new wNFTMinter(address(largeNft), 100);
        largeNft.setMinter(address(largeVault), true);

        // Mint 98 out of 100 (98%)
        uint256[] memory tokenIds = largeVault.mint(98, address(this));
        largeNft.setApprovalForAll(address(largeVault), true);

        // Try to deposit - should still be locked at 98%
        uint256[] memory depositIds = new uint256[](1);
        depositIds[0] = tokenIds[0];
        vm.expectRevert(wNFTMinter.DepositsLocked.selector);
        largeVault.deposit(depositIds, address(this));
    }

    function testDepositUnlockedAt99Percent() public {
        // Create vault with larger maxSupply
        wNFTNFT largeNft = new wNFTNFT("Large", "LRG", "ipfs://", address(this));
        wNFTMinter largeVault = new wNFTMinter(address(largeNft), 100);
        largeNft.setMinter(address(largeVault), true);

        // Mint exactly 99 out of 100 (99%)
        uint256[] memory tokenIds = largeVault.mint(99, address(this));
        largeNft.setApprovalForAll(address(largeVault), true);

        // Now deposits should work
        uint256[] memory depositIds = new uint256[](1);
        depositIds[0] = tokenIds[0];
        uint256 mintedAmount = largeVault.deposit(depositIds, address(this));
        assertEq(mintedAmount, largeVault.UNIT());
    }

    function testDepositUnlockedAt100Percent() public {
        // Mint all 10 (100%)
        uint256[] memory tokenIds = vault.mint(10, address(this));
        nft.setApprovalForAll(address(vault), true);

        // Deposits should work
        uint256[] memory depositIds = new uint256[](1);
        depositIds[0] = tokenIds[0];
        uint256 mintedAmount = vault.deposit(depositIds, address(this));
        assertEq(mintedAmount, vault.UNIT());
    }

    function testDepositWithZeroMaxSupplyAlwaysAllowed() public {
        // Create vault with zero maxSupply
        wNFTNFT zeroNft = new wNFTNFT("Zero", "ZERO", "ipfs://", address(this));
        wNFTMinter zeroVault = new wNFTMinter(address(zeroNft), 0);

        // Mint an NFT directly (not through vault) - need to set this contract as minter first
        zeroNft.setMinter(address(this), true);
        zeroNft.safeMint(address(this), "");
        zeroNft.setApprovalForAll(address(zeroVault), true);

        // Deposits should work even with 0 maxSupply
        uint256[] memory tokenIds = new uint256[](1);
        tokenIds[0] = 0;
        uint256 mintedAmount = zeroVault.deposit(tokenIds, address(this));
        assertEq(mintedAmount, zeroVault.UNIT());
    }
}
