// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Test} from "forge-std/Test.sol";

import {wNFTNFT} from "../src/wNFTNFT.sol";
import {ERC721} from "solady/tokens/ERC721.sol";

contract RemyVaultNFTBatchTest is Test {
    wNFTNFT internal nft;
    address internal holder;

    function setUp() public {
        holder = makeAddr("holder");
        nft = new wNFTNFT("Remy NFT", "RMN", "ipfs://remy/", address(this));
        nft.setMinter(address(this), true);
    }

    function testBatchMint_MintsSequentialTokens() public {
        string[] memory suffixes = new string[](3);
        suffixes[0] = "zero.json";
        suffixes[1] = "one.json";
        suffixes[2] = "two.json";

        uint256[] memory tokenIds = nft.batchMint(holder, 3, suffixes);

        assertEq(tokenIds.length, 3);
        assertEq(tokenIds[0], 0);
        assertEq(tokenIds[2], 2);
        assertEq(nft.totalSupply(), 3);
        assertEq(nft.ownerOf(1), holder);
        assertEq(nft.tokenURI(2), "ipfs://remy/two.json");
    }

    function testBatchMint_UsesDefaultSuffixWhenEmptyArray() public {
        uint256[] memory tokenIds = nft.batchMint(holder, 2, new string[](0));

        assertEq(tokenIds.length, 2);
        assertEq(tokenIds[0], 0);
        assertEq(nft.ownerOf(tokenIds[1]), holder);
        assertEq(nft.tokenURI(tokenIds[1]), "ipfs://remy/1");
    }

    function testBatchMint_RevertsOnInvalidLengths() public {
        string[] memory suffixes = new string[](1);
        suffixes[0] = "only.json";

        vm.expectRevert(wNFTNFT.InvalidBatchLength.selector);
        nft.batchMint(holder, 2, suffixes);

        vm.expectRevert(wNFTNFT.InvalidBatchLength.selector);
        nft.batchMint(holder, 0, new string[](0));
    }

    function testBatchBurn_RemovesAllTokens() public {
        uint256[] memory minted = nft.batchMint(holder, 2, new string[](0));

        vm.prank(holder);
        nft.batchBurn(minted);

        assertEq(nft.totalSupply(), 0);
        assertEq(nft.balanceOf(holder), 0);

        vm.expectRevert(ERC721.TokenDoesNotExist.selector);
        nft.ownerOf(minted[0]);
    }

    function testSupportsInterfaceEnumeration() public view {
        // ERC721 interface ID
        bytes4 erc721InterfaceId = 0x80ac58cd;
        assertTrue(nft.supportsInterface(erc721InterfaceId), "should support ERC721");

        // ERC721Metadata interface ID
        bytes4 erc721MetadataInterfaceId = 0x5b5e139f;
        assertTrue(nft.supportsInterface(erc721MetadataInterfaceId), "should support ERC721Metadata");

        // ERC721Enumerable interface ID (0x780e9d63)
        bytes4 erc721EnumerableInterfaceId = 0x780e9d63;
        assertTrue(nft.supportsInterface(erc721EnumerableInterfaceId), "should support ERC721Enumerable");

        // ERC165 interface ID
        bytes4 erc165InterfaceId = 0x01ffc9a7;
        assertTrue(nft.supportsInterface(erc165InterfaceId), "should support ERC165");

        // Random interface ID (should not be supported)
        bytes4 randomInterfaceId = 0x12345678;
        assertFalse(nft.supportsInterface(randomInterfaceId), "should not support random interface");
    }
}
