// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";

import {MinterRemyVault} from "../src/MinterRemyVault.sol";
import {RemyVaultNFT} from "../src/RemyVaultNFT.sol";

contract MinterRemyVaultTest is Test {
    MinterRemyVault internal vault;
    RemyVaultNFT internal nft;
    address internal alice;

    function setUp() public {
        alice = makeAddr("alice");
        nft = new RemyVaultNFT("Derivative", "DRV", "ipfs://", address(this));
        vault = new MinterRemyVault("Derivative Token", "dDRV", address(nft), 10);
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

    function testMintLimitEnforced() public {
        vm.prank(address(this));
        vault.mint(10, address(this));

        vm.expectRevert(MinterRemyVault.MintLimitExceeded.selector);
        vault.mint(1, address(this));
    }

    function testDepositAndWithdrawFlow() public {
        // Mint two NFTs through the vault first.
        uint256[] memory tokenIds = vault.mint(2, address(this));
        nft.setApprovalForAll(address(vault), true);
        uint256 balanceBefore = vault.balanceOf(address(this));
        uint256 mintedAmount = vault.deposit(tokenIds, address(this));
        assertEq(mintedAmount, 2 * vault.UNIT(), "deposit mint mismatch");
        assertEq(vault.balanceOf(address(this)) - balanceBefore, mintedAmount, "deposit balance mismatch");

        vault.withdraw(tokenIds, address(this));
        assertEq(vault.balanceOf(address(this)), balanceBefore, "withdraw balance mismatch");
    }

    function testMintZeroRecipientReverts() public {
        vm.expectRevert(MinterRemyVault.RecipientZero.selector);
        vault.mint(1, address(0));
    }

    function testMintZeroCountReverts() public {
        vm.expectRevert(MinterRemyVault.MintZeroCount.selector);
        vault.mint(0, address(this));
    }
}
