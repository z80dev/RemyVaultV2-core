// SPDX-License-Identifier: MIT
pragma solidity >=0.8.17;

interface IERC721Receiver {
    function onERC721Received(address operator, address from, uint256 tokenId, bytes calldata data)
        external
        returns (bytes4);
}

contract MockERC721Simple {
    string public name;
    string public symbol;

    mapping(uint256 => address) public ownerOf;
    mapping(address => uint256) public balanceOf;
    mapping(uint256 => address) public getApproved;
    mapping(address => mapping(address => bool)) public isApprovedForAll;
    mapping(address => mapping(uint256 => uint256)) internal ownedTokens;
    mapping(uint256 => uint256) internal ownedTokensIndex;

    address public owner;

    event Transfer(address indexed from, address indexed to, uint256 indexed tokenId);
    event Approval(address indexed owner, address indexed spender, uint256 indexed tokenId);
    event ApprovalForAll(address indexed owner, address indexed operator, bool approved);

    modifier onlyOwner() {
        require(msg.sender == owner, "not owner");
        _;
    }

    constructor(string memory name_, string memory symbol_) {
        owner = msg.sender;
        name = name_;
        symbol = symbol_;
    }

    function mint(address to, uint256 tokenId) external onlyOwner {
        require(to != address(0), "zero address");
        require(ownerOf[tokenId] == address(0), "already minted");
        ownerOf[tokenId] = to;
        _addTokenToOwnerEnumeration(to, tokenId);
        balanceOf[to] += 1;
        emit Transfer(address(0), to, tokenId);
    }

    function approve(address spender, uint256 tokenId) external {
        address tokenOwner = ownerOf[tokenId];
        require(tokenOwner != address(0), "nonexistent");
        require(msg.sender == tokenOwner || isApprovedForAll[tokenOwner][msg.sender], "not authorized");
        getApproved[tokenId] = spender;
        emit Approval(tokenOwner, spender, tokenId);
    }

    function setApprovalForAll(address operator, bool approved) external {
        isApprovedForAll[msg.sender][operator] = approved;
        emit ApprovalForAll(msg.sender, operator, approved);
    }

    function transferFrom(address from, address to, uint256 tokenId) public {
        require(ownerOf[tokenId] == from, "not owner");
        require(to != address(0), "zero address");
        require(
            msg.sender == from || isApprovedForAll[from][msg.sender] || getApproved[tokenId] == msg.sender,
            "not approved"
        );
        _removeTokenFromOwnerEnumeration(from, tokenId);
        balanceOf[from] -= 1;
        ownerOf[tokenId] = to;
        _addTokenToOwnerEnumeration(to, tokenId);
        balanceOf[to] += 1;
        delete getApproved[tokenId];
        emit Transfer(from, to, tokenId);
    }

    function safeTransferFrom(address from, address to, uint256 tokenId) public {
        safeTransferFrom(from, to, tokenId, "");
    }

    function safeTransferFrom(address from, address to, uint256 tokenId, bytes memory data) public {
        transferFrom(from, to, tokenId);
        if (to.code.length > 0) {
            require(
                IERC721Receiver(to).onERC721Received(msg.sender, from, tokenId, data)
                    == IERC721Receiver.onERC721Received.selector,
                "unsafe recipient"
            );
        }
    }

    function tokenOfOwnerByIndex(address account, uint256 index) external view returns (uint256) {
        require(index < balanceOf[account], "index out of bounds");
        return ownedTokens[account][index];
    }

    function _addTokenToOwnerEnumeration(address to, uint256 tokenId) internal {
        uint256 length = balanceOf[to];
        ownedTokens[to][length] = tokenId;
        ownedTokensIndex[tokenId] = length;
    }

    function _removeTokenFromOwnerEnumeration(address from, uint256 tokenId) internal {
        uint256 lastTokenIndex = balanceOf[from] - 1;
        uint256 tokenIndex = ownedTokensIndex[tokenId];

        if (tokenIndex != lastTokenIndex) {
            uint256 lastTokenId = ownedTokens[from][lastTokenIndex];
            ownedTokens[from][tokenIndex] = lastTokenId;
            ownedTokensIndex[lastTokenId] = tokenIndex;
        }

        delete ownedTokensIndex[tokenId];
        delete ownedTokens[from][lastTokenIndex];
    }
}
