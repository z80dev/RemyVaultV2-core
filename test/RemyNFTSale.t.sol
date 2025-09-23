// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Test} from "forge-std/Test.sol";

interface IManagedToken {
    function mint(address to, uint256 amount) external;
    function approve(address spender, uint256 value) external returns (bool);
    function transfer(address to, uint256 value) external returns (bool);
    function transferFrom(address from, address to, uint256 value) external returns (bool);
    function balanceOf(address account) external view returns (uint256);
}

interface IRemyVaultNFT {
    function set_minter(address minter, bool status) external;
    function totalSupply() external view returns (uint256);
    function ownerOf(uint256 tokenId) external view returns (address);
    function tokenURI(uint256 tokenId) external view returns (string memory);
    function tokenByIndex(uint256 index) external view returns (uint256);
    function tokenOfOwnerByIndex(address owner, uint256 index) external view returns (uint256);
    function supportsInterface(bytes4 interfaceId) external view returns (bool);
}

interface IRemyNFTSale {
    function purchase_self(uint256 amount) external;
    function purchase(address recipient, uint256 amount) external;
    function price_for(uint256 amount) external view returns (uint256);
    function set_price(uint256 newPrice) external;
    function set_default_token_uri(string calldata newURI) external;
    function set_funds_recipient(address newRecipient) external;
    function price() external view returns (uint256);
    function funds_recipient() external view returns (address);
}

contract RemyNFTSaleTest is Test {
    IManagedToken public paymentToken;
    IRemyVaultNFT public nft;
    IRemyNFTSale public sale;

    address public treasury;
    address public buyer;
    address public altBuyer;

    uint256 public unitPrice;

    function setUp() public {
        treasury = makeAddr("treasury");
        buyer = makeAddr("buyer");
        altBuyer = makeAddr("altBuyer");
        unitPrice = 5 ether;

        paymentToken = IManagedToken(deployCode("ManagedToken", abi.encode("Payment Token", "PAY", address(this))));

        nft = IRemyVaultNFT(deployCode("RemyVaultNFT", abi.encode("Remy NFT", "RMN", "ipfs://remy/", address(this))));

        sale = IRemyNFTSale(
            deployCode("RemyNFTSale", abi.encode(address(nft), address(paymentToken), unitPrice, treasury, ""))
        );

        nft.set_minter(address(sale), true);

        paymentToken.mint(buyer, 1000 ether);
        vm.prank(buyer);
        paymentToken.approve(address(sale), type(uint256).max);
    }

    function testPurchaseSelf_MintsAndTransfers() public {
        vm.prank(buyer);
        sale.purchase_self(2);

        assertEq(nft.totalSupply(), 2);
        assertEq(nft.ownerOf(0), buyer);
        assertEq(nft.ownerOf(1), buyer);
        assertEq(nft.tokenByIndex(0), 0);
        assertEq(nft.tokenOfOwnerByIndex(buyer, 0), 0);
        assertEq(paymentToken.balanceOf(treasury), unitPrice * 2);
        assertEq(sale.price_for(2), unitPrice * 2);
        assertEq(nft.tokenURI(0), "ipfs://remy/0");
    }

    function testPurchaseForRecipient_MintsToRecipient() public {
        address recipient = makeAddr("recipient");

        vm.prank(buyer);
        sale.purchase(recipient, 1);

        assertEq(nft.totalSupply(), 1);
        assertEq(nft.ownerOf(0), recipient);
        assertEq(paymentToken.balanceOf(treasury), unitPrice);
    }

    function testPurchase_RevertsWithoutMinterRole() public {
        // remove sale contract as minter
        nft.set_minter(address(sale), false);

        vm.prank(buyer);
        vm.expectRevert(bytes("RemyNFTSale: not authorised minter"));
        sale.purchase_self(1);
    }

    function testPurchase_RevertsOnZeroAmount() public {
        vm.prank(buyer);
        vm.expectRevert(bytes("RemyNFTSale: amount zero"));
        sale.purchase_self(0);
    }

    function testAdminUpdates_AffectSubsequentSales() public {
        sale.set_price(unitPrice * 2);
        assertEq(sale.price(), unitPrice * 2);

        sale.set_funds_recipient(altBuyer);
        assertEq(sale.funds_recipient(), altBuyer);

        sale.set_default_token_uri("metadata.json");

        vm.prank(buyer);
        sale.purchase_self(1);

        assertEq(nft.totalSupply(), 1);
        assertEq(nft.tokenURI(0), "ipfs://remy/metadata.json");
        assertEq(nft.tokenByIndex(0), 0);
        assertEq(nft.tokenOfOwnerByIndex(buyer, 0), 0);
        assertEq(paymentToken.balanceOf(altBuyer), unitPrice * 2);
    }

    function testSupportsEnumerableInterface() public view {
        assertTrue(nft.supportsInterface(0x780e9d63));
    }
}
