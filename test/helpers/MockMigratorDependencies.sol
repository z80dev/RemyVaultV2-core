// SPDX-License-Identifier: MIT

pragma solidity >=0.8.17;

interface IERC721Receiver {
    function onERC721Received(address operator, address from, uint256 tokenId, bytes calldata data)
        external
        returns (bytes4);
}

contract MockERC20DN404 {
    string public name;
    string public symbol;
    uint8 public constant decimals = 18;

    uint256 public totalSupply;
    mapping(address => uint256) public balanceOf;
    mapping(address => mapping(address => uint256)) public allowance;
    mapping(address => bool) public minters;

    address public owner;
    bool public skipNFT;

    event Transfer(address indexed from, address indexed to, uint256 amount);
    event Approval(address indexed owner, address indexed spender, uint256 amount);

    modifier onlyOwner() {
        require(msg.sender == owner, "not owner");
        _;
    }

    modifier onlyMinter() {
        require(minters[msg.sender], "not minter");
        _;
    }

    constructor(string memory name_, string memory symbol_) {
        owner = msg.sender;
        name = name_;
        symbol = symbol_;
    }

    function setMinter(address minter, bool allowed) external onlyOwner {
        minters[minter] = allowed;
    }

    function mint(address to, uint256 amount) external onlyMinter {
        require(to != address(0), "zero address");
        totalSupply += amount;
        balanceOf[to] += amount;
        emit Transfer(address(0), to, amount);
    }

    function burn(address from, uint256 amount) internal {
        require(balanceOf[from] >= amount, "insufficient balance");
        balanceOf[from] -= amount;
        totalSupply -= amount;
        emit Transfer(from, address(0), amount);
    }

    function burnFrom(address from, uint256 amount) external {
        if (msg.sender != from) {
            uint256 allowed = allowance[from][msg.sender];
            require(allowed >= amount, "insufficient allowance");
            if (allowed != type(uint256).max) {
                allowance[from][msg.sender] = allowed - amount;
                emit Approval(from, msg.sender, allowance[from][msg.sender]);
            }
        }
        burn(from, amount);
    }

    function transfer(address to, uint256 amount) external returns (bool) {
        _transfer(msg.sender, to, amount);
        return true;
    }

    function transferFrom(address from, address to, uint256 amount) external returns (bool) {
        if (from != msg.sender) {
            uint256 allowed = allowance[from][msg.sender];
            require(allowed >= amount, "insufficient allowance");
            if (allowed != type(uint256).max) {
                allowance[from][msg.sender] = allowed - amount;
                emit Approval(from, msg.sender, allowance[from][msg.sender]);
            }
        }
        _transfer(from, to, amount);
        return true;
    }

    function approve(address spender, uint256 amount) external returns (bool) {
        allowance[msg.sender][spender] = amount;
        emit Approval(msg.sender, spender, amount);
        return true;
    }

    function _transfer(address from, address to, uint256 amount) internal {
        require(to != address(0), "zero address");
        require(balanceOf[from] >= amount, "insufficient balance");
        balanceOf[from] -= amount;
        balanceOf[to] += amount;
        emit Transfer(from, to, amount);
    }

    function setSkipNFT(bool skip) external returns (bool) {
        skipNFT = skip;
        return true;
    }
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
}

contract MockVaultV1 is IERC721Receiver {
    uint256 public constant UNIT = 1000 * 1e18;

    MockERC20DN404 public immutable token;
    MockERC721Simple public immutable nft;

    bool public isActive;
    address public vaultOwner;

    constructor(MockERC20DN404 token_, MockERC721Simple nft_) {
        token = token_;
        nft = nft_;
        vaultOwner = msg.sender;
    }

    function set_active(bool newActive) external {
        isActive = newActive;
    }

    function set_fee_exempt(address, bool) external {}

    function set_fees(uint256[2] calldata) external {}

    function set_rbtoken_fee_receiver(address) external {}

    function transfer_owner(address newOwner) external {
        vaultOwner = newOwner;
    }

    function charge_fee(uint256) external {}

    function fee_exempt(address) external pure returns (bool) {
        return false;
    }

    function rbtoken_fee_receiver() external pure returns (address) {
        return address(0);
    }

    function active() external view returns (bool) {
        return isActive;
    }

    function owner() external view returns (address) {
        return vaultOwner;
    }

    function mint_fee() external pure returns (uint256) {
        return 0;
    }

    function redeem_fee() external pure returns (uint256) {
        return 0;
    }

    function erc20() external view returns (address) {
        return address(token);
    }

    function erc721() external view returns (address) {
        return address(nft);
    }

    function quote_redeem(uint256 count, bool) external pure returns (uint256) {
        return count * UNIT;
    }

    function quote_mint(uint256 count, bool) external pure returns (uint256) {
        return count * UNIT;
    }

    function quote_redeem_fee(address, uint256) external pure returns (uint256) {
        return 0;
    }

    function quote_mint_fee(address, uint256) external pure returns (uint256) {
        return 0;
    }

    function mint_batch(uint256[] calldata tokenIds, address recipient, bool) external returns (uint256 minted) {
        require(isActive, "inactive");
        minted = tokenIds.length * UNIT;
        for (uint256 i = 0; i < tokenIds.length; i++) {
            nft.safeTransferFrom(msg.sender, address(this), tokenIds[i]);
        }
        token.mint(recipient, minted);
    }

    function redeem_batch(uint256[] calldata tokenIds, address recipient, bool) external returns (uint256 burned) {
        require(isActive, "inactive");
        burned = tokenIds.length * UNIT;
        token.burnFrom(msg.sender, burned);
        for (uint256 i = 0; i < tokenIds.length; i++) {
            nft.safeTransferFrom(address(this), recipient, tokenIds[i]);
        }
    }

    function onERC721Received(address, address, uint256, bytes calldata) external pure returns (bytes4) {
        return IERC721Receiver.onERC721Received.selector;
    }
}

contract MockVaultV2 is IERC721Receiver {
    uint256 public constant UNIT = 1000 * 1e18;

    MockERC20DN404 public immutable token;
    MockERC721Simple public immutable nft;
    uint256 public mintMultiplier = 1e18;

    constructor(MockERC20DN404 token_, MockERC721Simple nft_) {
        token = token_;
        nft = nft_;
    }

    function setMintMultiplier(uint256 newMultiplier) external {
        mintMultiplier = newMultiplier;
    }

    function deposit(uint256[] calldata tokenIds, address recipient) external returns (uint256 minted) {
        minted = (tokenIds.length * UNIT * mintMultiplier) / 1e18;
        for (uint256 i = 0; i < tokenIds.length; i++) {
            nft.safeTransferFrom(msg.sender, address(this), tokenIds[i]);
        }
        token.mint(recipient, minted);
    }

    function withdraw(uint256[] calldata tokenIds, address recipient) external returns (uint256 burned) {
        burned = tokenIds.length * UNIT;
        token.burnFrom(msg.sender, burned);
        for (uint256 i = 0; i < tokenIds.length; i++) {
            nft.safeTransferFrom(address(this), recipient, tokenIds[i]);
        }
    }

    function quoteDeposit(uint256 count) external pure returns (uint256) {
        return count * UNIT;
    }

    function quoteWithdraw(uint256 count) external pure returns (uint256) {
        return count * UNIT;
    }

    function erc20() external view returns (address) {
        return address(token);
    }

    function onERC721Received(address, address, uint256, bytes calldata) external pure returns (bytes4) {
        return IERC721Receiver.onERC721Received.selector;
    }
}

contract MockOldRouter {
    address public immutable vault_address;
    address public immutable weth;
    address public immutable v3router_address;
    address public immutable erc4626_address;

    constructor(address vault, address weth_, address v3router, address erc4626) {
        vault_address = vault;
        weth = weth_;
        v3router_address = v3router;
        erc4626_address = erc4626;
    }
}
