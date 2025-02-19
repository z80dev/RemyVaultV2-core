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
    function approve(address to, uint256 tokenId) external;
    function setApprovalForAll(address operator, bool approved) external;
}

interface IERC20 {
    function transfer(address to, uint256 value) external returns (bool);
    function transferFrom(address from, address to, uint256 value) external returns (bool);
    function balanceOf(address owner) external view returns (uint256);
    function approve(address spender, uint256 value) external returns (bool);
    function allowance(address owner, address spender) external view returns (uint256);
    function totalSupply() external view returns (uint256);
}

interface Ownable {
    function owner() external view returns (address);
    function transfer_ownership(address newOwner) external;
}

interface IVault {
    function deposit(uint256 tokenId, address recipient) external;
    function batchDeposit(uint256[] calldata tokenIds, address recipient) external returns (uint256) ;
    function withdraw(uint256 tokenId) external;
    function batchWithdraw(uint256[] calldata tokenIds, address recipient) external returns (uint256) ;
    function quoteDeposit(uint256 tokenId) external view returns (uint256);
}

contract RemyVaultTest is Test {

    IERC721 public nft;
    IERC20 public token;
    IVault public vault;

    function setUp() public {
        nft = IERC721(deployCode("MockERC721", abi.encode("MOCK", "MOCK", "https://", "MOCK", "1.0")));
        token = IERC20(deployCode("MockERC20"));
        vault = IVault(deployCode("RemyVault", abi.encode(address(token), address(nft), [0,0])));
        Ownable(address(token)).transfer_ownership(address(vault));
        Ownable(address(nft)).transfer_ownership(address(vault));
    }

    function testSetup() public view {
        assertEq(nft.balanceOf(address(vault)), 0);
        assertEq(token.balanceOf(address(vault)), 0);
        assertNotEq(address(nft), address(0));
    }

    function testDeposit() public {
        // mint a token to this contract
        nft.mint(address(this), 1);

        // approve the vault to transfer the token
        nft.approve(address(vault), 1);

        // deposit the token
        vault.deposit(1, address(this));

        // check the vault now owns 1 token
        assertEq(nft.balanceOf(address(vault)), 1);

        // check the specific token is owned by the vault
        assertEq(nft.ownerOf(1), address(vault));

        // check the vault minted us 1000 tokens
        assertEq(token.balanceOf(address(this)), 1000 * 10**18);
    }

    function testBatchDeposit(uint256 n) public {
        // batch deposits limited to 100 tokenIds for gas reasons
        vm.assume(n < 101);

        // mint n tokens to this contract & store their tokenIds
        uint256[] memory tokenIds = new uint256[](n);
        for (uint256 i = 0; i < n; i++) {
            nft.mint(address(this), i);
            tokenIds[i] = i;
        }

        // approve the vault to transfer the tokens
        nft.setApprovalForAll(address(vault), true);

        // deposit the tokens
        vault.batchDeposit(tokenIds, address(this));

        // check the vault now owns n tokens
        assertEq(nft.balanceOf(address(vault)), n);

        // check the specific tokens are owned by the vault

        // check the vault minted us 1000 tokens per tokenId
        assertEq(token.balanceOf(address(this)), n * 1000 * 10**18);
    }

    function testWithdraw() public {
        // mint a token to this contract
        nft.mint(address(this), 1);

        // approve the vault to transfer the token
        nft.approve(address(vault), 1);

        // deposit the token
        vault.deposit(1, address(this));

        // approve the vault to move out erc20 tokens
        token.approve(address(vault), 1000 * 10**18);

        // withdraw the token
        vault.withdraw(1);

        // check the vault no longer owns the token
        assertEq(nft.balanceOf(address(vault)), 0);

        // check the specific token is owned by this contract
        assertEq(nft.ownerOf(1), address(this));

        // check the vault no longer owns 1000 tokens
        assertEq(token.balanceOf(address(this)), 0);
    }

    function testBatchWithdraw(uint256 n) public {
        // batch deposits limited to 100 tokenIds for gas reasons
        vm.assume(n < 5);

        // mint n tokens to this contract & store their tokenIds
        uint256[] memory tokenIds = new uint256[](n);
        for (uint256 i = 0; i < n; i++) {
            nft.mint(address(this), i);
            tokenIds[i] = i;
        }

        // approve the vault to transfer the tokens
        nft.setApprovalForAll(address(vault), true);

        // deposit the tokens
        vault.batchDeposit(tokenIds, address(this));

        // approve the vault to move out erc20 tokens
        token.approve(address(vault), n * 1000 * 10**18);

        // withdraw the tokens
        vault.batchWithdraw(tokenIds, address(this));

        // check the vault no longer owns the tokens
        assertEq(nft.balanceOf(address(vault)), 0);

        // check the vault no longer owns 1000 tokens per tokenId
        assertEq(token.balanceOf(address(this)), 0);
    }

    function invariant_tokenSupply() public view {
        // token's totalSupply should be equal to the number of tokenIds the vault owns, * UNIT
        // we can get that number with quoteDeposit
        uint256 vaultNFTBalance = nft.balanceOf(address(vault));
        uint256 totalSupply = token.totalSupply();
        uint256 quoteDeposit = vault.quoteDeposit(vaultNFTBalance);
        assertEq(totalSupply, quoteDeposit);
    }

    function onERC721Received(address, address, uint256, bytes memory) public pure returns (bytes4) {
        return this.onERC721Received.selector;
    }

}
