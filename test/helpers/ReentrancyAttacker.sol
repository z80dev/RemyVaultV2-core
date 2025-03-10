// SPDX-License-Identifier: MIT
pragma solidity >=0.8.7 <0.9.0;

/**
 * @title ReentrancyAttacker
 * @dev A contract designed to test reentrancy protection in RemyVault contracts
 *
 * This contract attempts to exploit potential reentrancy vulnerabilities by invoking
 * additional vault functions during callback hooks (like onERC721Received). It can be
 * configured to attack during deposit or withdraw operations.
 *
 * Usage:
 * 1. Deploy this contract with target vault, NFT, and token addresses
 * 2. Configure attack parameters (tokenId, attack type)
 * 3. Approve tokens
 * 4. Call attack methods to test vault's reentrancy protection
 *
 * Security Notes:
 * - This contract is for testing purposes only
 * - In actual exploits, attackers might use more complex mechanisms
 * - A proper reentrancy guard should prevent any attack scenarios implemented here
 */
interface IVault {
    function deposit(uint256[] calldata tokenIds, address recipient) external returns (uint256);
    function withdraw(uint256[] calldata tokenIds, address recipient) external returns (uint256);
}

interface IERC721 {
    function setApprovalForAll(address operator, bool approved) external;
    function approve(address to, uint256 tokenId) external;
}

interface IERC20 {
    function approve(address spender, uint256 value) external returns (bool);
}

contract ReentrancyAttacker {
    /// @notice The vault contract being tested for reentrancy protection
    IVault public vault;

    /// @notice The NFT contract used for deposits
    IERC721 public nft;

    /// @notice The ERC20 token received for deposits
    IERC20 public token;

    /// @notice Flag to enable attack during deposit callbacks
    bool public attackOnDeposit;

    /// @notice Flag to enable attack during withdraw callbacks
    bool public attackOnWithdraw;

    /// @notice Flag to track if an attack has been attempted (prevents infinite loops)
    bool public attacked;

    /// @notice The token ID being used in the attack
    uint256 public tokenId;

    /// @notice The owner of this attack contract
    address public owner;

    /**
     * @dev Emitted when an attack attempt is made
     * @param attackType The type of attack (deposit/withdraw)
     * @param tokenId The token ID involved in the attack
     * @param success Whether the attack succeeded
     */
    event AttackAttempted(string attackType, uint256 tokenId, bool success);

    /**
     * @dev Constructor initializes the attacker with target contracts
     * @param _vault Address of the vault contract to attack
     * @param _nft Address of the NFT contract
     * @param _token Address of the ERC20 token contract
     */
    constructor(address _vault, address _nft, address _token) {
        vault = IVault(_vault);
        nft = IERC721(_nft);
        token = IERC20(_token);
        owner = msg.sender;
    }

    /**
     * @dev Set whether to attempt reentrancy attack during deposit
     * @param _attack True to enable attack during deposit
     */
    function setAttackOnDeposit(bool _attack) external {
        require(msg.sender == owner, "Only owner");
        attackOnDeposit = _attack;
    }

    /**
     * @dev Set whether to attempt reentrancy attack during withdraw
     * @param _attack True to enable attack during withdraw
     */
    function setAttackOnWithdraw(bool _attack) external {
        require(msg.sender == owner, "Only owner");
        attackOnWithdraw = _attack;
    }

    /**
     * @dev Set the token ID to use in the attack
     * @param _tokenId The NFT token ID
     */
    function setTokenId(uint256 _tokenId) external {
        require(msg.sender == owner, "Only owner");
        tokenId = _tokenId;
    }

    /**
     * @dev Reset the attacked flag for a new attack attempt
     * @param _attacked New value for the attacked flag
     */
    function setAttacked(bool _attacked) external {
        require(msg.sender == owner, "Only owner");
        attacked = _attacked;
    }

    /**
     * @dev Approve vault for both NFT and tokens (max amount)
     * This must be called before attempting attacks
     */
    function approveAll() external {
        nft.setApprovalForAll(address(vault), true);
        token.approve(address(vault), type(uint256).max);
    }

    /**
     * @dev Initiate a deposit attack
     * @param _tokenId The token ID to deposit
     *
     * This function approves and deposits an NFT. If attackOnDeposit is set,
     * the attack will be attempted in the onERC721Received callback.
     */
    function attack(uint256 _tokenId) external {
        tokenId = _tokenId;
        nft.approve(address(vault), tokenId);

        // Create token IDs array with a single token
        uint256[] memory tokenIds = new uint256[](1);
        tokenIds[0] = tokenId;

        // Initial legitimate deposit
        vault.deposit(tokenIds, address(this));

        // If we reached here, either no attack was attempted or it failed silently
    }

    /**
     * @dev Initiate a withdraw attack
     * @param _tokenId The token ID to withdraw
     */
    function attackWithdraw(uint256 _tokenId) external {
        tokenId = _tokenId;
        token.approve(address(vault), 1000 * 10 ** 18);
        
        // Create token IDs array with a single token
        uint256[] memory tokenIds = new uint256[](1);
        tokenIds[0] = tokenId;
        
        vault.withdraw(tokenIds, address(this));
    }

    /**
     * @dev ERC721 receiver callback - the point of reentrancy attack during deposit
     *
     * When an NFT is transferred to this contract, this function is called.
     * If attackOnDeposit is enabled, it will attempt to call the vault's deposit function again,
     * which should be prevented by proper reentrancy protection.
     */
    function onERC721Received(address, address, uint256, bytes memory) external returns (bytes4) {
        if (attackOnDeposit && !attacked) {
            attacked = true;

            // Create token IDs array with a single token
            uint256[] memory tokenIds = new uint256[](1);
            tokenIds[0] = tokenId;

            // Try to call deposit again during the first deposit's callback
            // This should fail if reentrancy protection is working
            bool success = false;
            try vault.deposit(tokenIds, address(this)) {
                success = true;
            } catch {
                // Expected to fail due to reentrancy protection
            }

            emit AttackAttempted("deposit", tokenId, success);
        }

        // Must return this value for ERC721 compatibility
        return this.onERC721Received.selector;
    }

    /**
     * @dev Perform withdraw followed by a reentrancy attack if configured
     *
     * This function doesn't directly demonstrate reentrancy during withdraw
     * because the vault uses safeTransferFrom which doesn't have a pre-withdrawal hook.
     * It serves as a helper to perform withdrawals for testing.
     */
    function withdrawAttack() external {
        token.approve(address(vault), 1000 * 10 ** 18);

        // Create token IDs array with a single token
        uint256[] memory tokenIds = new uint256[](1);
        tokenIds[0] = tokenId;

        // Normal withdrawal
        vault.withdraw(tokenIds, address(this));

        // In production, a reentrancy attack would try to occur during the NFT transfer callback,
        // but we're just testing the normal path since reentrancy should be blocked
    }

    /**
     * @dev Allow the owner to rescue any stuck tokens
     * @param tokenAddress Address of the token to rescue
     * @param to Address to send tokens to
     * @param amount Amount of tokens to rescue
     */
    function rescueTokens(address tokenAddress, address to, uint256 amount) external {
        require(msg.sender == owner, "Only owner");
        IERC20(tokenAddress).approve(to, amount);
    }
}