// SPDX-License-Identifier: MIT

pragma solidity >=0.8.7 <0.9.0;

import {Test} from "forge-std/Test.sol";

interface IERC721 {
    function mint(address to, uint256 tokenId) external;
    function burn(uint256 tokenId) external;
    function ownerOf(uint256 tokenId) external view returns (address);
    function balanceOf(address owner) external view returns (uint256);
    function isApprovedForAll(address owner, address operator) external view returns (bool);
    function safeTransferFrom(address from, address to, uint256 tokenId) external;
}

interface IERC20 {
    function transfer(address to, uint256 value) external returns (bool);
    function transferFrom(address from, address to, uint256 value) external returns (bool);
    function balanceOf(address owner) external view returns (uint256);
    function approve(address spender, uint256 value) external returns (bool);
    function allowance(address owner, address spender) external view returns (uint256);
}

contract RemyVaultTest is Test {

    IERC721 public nft;
    IERC20 public token;
    address public vault;

    function setUp() public {
        nft = IERC721(deployCode("MockERC721", abi.encode("MOCK", "MOCK", "https://", "MOCK", "1.0")));
        token = IERC20(deployCode("MockERC20"));
        vault = deployCode("RemyVault", abi.encode(address(token), address(nft), [0,0]));
    }

    function testSetup()public {
        assertEq(nft.balanceOf(vault), 0);
        assertEq(token.balanceOf(vault), 0);
        assertNotEq(address(nft), address(0));
    }

}
