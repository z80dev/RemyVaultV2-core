// SPDX-License-Identifier: MIT

pragma solidity >=0.8.7 <0.9.0;

import {Test} from "forge-std/Test.sol";
import {ReentrancyAttacker} from "./helpers/ReentrancyAttacker.sol";

/**
 * @title IERC721
 * @dev Interface for the mock ERC721 token used in tests
 */
interface IERC721 {
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
 * @title IERC20
 * @dev Interface for the mock ERC20 token used in tests
 */
interface IERC20 {
    function transfer(address to, uint256 value) external returns (bool);
    function transferFrom(address from, address to, uint256 value) external returns (bool);
    function balanceOf(address owner) external view returns (uint256);
    function approve(address spender, uint256 value) external returns (bool);
    function allowance(address owner, address spender) external view returns (uint256);
    function totalSupply() external view returns (uint256);
    function mint(address to, uint256 value) external;
    function burn(uint256 amount) external;
}

/**
 * @title Ownable
 * @dev Interface for the ownable pattern implemented in mock contracts
 */
interface Ownable {
    function owner() external view returns (address);
    function transfer_ownership(address newOwner) external;
}

/**
 * @title IVault
 * @dev Interface for the RemyVault contract being tested
 */
interface IVault {
    function deposit(uint256 tokenId, address recipient) external;
    function batchDeposit(uint256[] calldata tokenIds, address recipient) external returns (uint256);
    function withdraw(uint256 tokenId, address recipient) external;
    function batchWithdraw(uint256[] calldata tokenIds, address recipient) external returns (uint256);
    function quoteDeposit(uint256 count) external pure returns (uint256);
    function quoteWithdraw(uint256 count) external pure returns (uint256);
    function erc20() external view returns (address);
    function erc721() external view returns (address);
}

/**
 * @title IManagedToken
 * @dev Interface for the ManagedToken functions used by the vault
 */
interface IManagedToken {
    function mint(address to, uint256 value) external;
    function burn(uint256 amount) external;
}

/**
 * @title RemyVaultTest
 * @dev Comprehensive test suite for the RemyVault contract
 *
 * This test suite validates all aspects of the RemyVault protocol including:
 * - Basic deposit/withdraw functionality
 * - Batch operations
 * - Token balance tracking and invariants
 * - Security properties (reentrancy protection)
 * - Edge cases (empty arrays, approval failures, etc.)
 * - Boundary conditions (max token limits)
 */
contract RemyVaultTest is Test {
    /// @notice Mock ERC721 token representing NFTs
    IERC721 public nft;
    
    /// @notice Mock ERC20 token representing fungible tokens
    IERC20 public token;
    
    /// @notice RemyVault contract instance being tested
    IVault public vault;
    
    /// @notice Test user address
    address public alice;
    
    /// @notice Second test user address
    address public bob;
    
    /// @notice Reentrancy attack contract for security testing
    ReentrancyAttacker public attacker;

    /**
     * @dev Setup function to deploy contracts and initialize test environment
     *
     * This function:
     * 1. Deploys mock ERC721 and ERC20 contracts
     * 2. Deploys the RemyVault contract with the token addresses
     * 3. Transfers ownership of token contracts to the vault (for minting/burning)
     * 4. Creates test user addresses and the reentrancy attack contract
     * 5. Configures Foundry's invariant testing properties
     */
    function setUp() public {
        // Deploy mock contracts
        nft = IERC721(deployCode("MockERC721", abi.encode("MOCK", "MOCK", "https://", "MOCK", "1.0")));
        token = IERC20(deployCode("MockERC20"));
        
        // Deploy vault and configure ownership
        vault = IVault(deployCode("RemyVault", abi.encode(address(token), address(nft))));
        Ownable(address(token)).transfer_ownership(address(vault));
        Ownable(address(nft)).transfer_ownership(address(vault));
        
        // Create test addresses
        alice = makeAddr("alice");
        bob = makeAddr("bob");
        
        // Deploy the reentrancy attacker contract
        attacker = new ReentrancyAttacker(address(vault), address(nft), address(token));
        
        // Configure invariant test properties
        excludeSender(address(vault));
    }

    function testSetup() public view {
        assertEq(nft.balanceOf(address(vault)), 0);
        assertEq(token.balanceOf(address(vault)), 0);
        assertNotEq(address(nft), address(0));
    }

    function testDeposit() public {
        // mint a token to this contract
        vm.prank(address(vault));
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
            vm.prank(address(vault));
            nft.mint(address(this), i);
            tokenIds[i] = i;
        }

        // approve the vault to transfer the tokens
        nft.setApprovalForAll(address(vault), true);

        // deposit the tokens
        vault.batchDeposit(tokenIds, address(this));

        // check the vault now owns n tokens
        assertEq(nft.balanceOf(address(vault)), n);

        // check the vault minted us 1000 tokens per tokenId
        assertEq(token.balanceOf(address(this)), n * 1000 * 10**18);
    }

    function testWithdraw() public {
        // mint a token to this contract
        vm.prank(address(vault));
        nft.mint(address(this), 1);

        // approve the vault to transfer the token
        nft.approve(address(vault), 1);

        // deposit the token
        vault.deposit(1, address(this));

        // approve the vault to move out erc20 tokens
        token.approve(address(vault), 1000 * 10**18);

        // withdraw the token
        vault.withdraw(1, address(this));

        // check the vault no longer owns the token
        assertEq(nft.balanceOf(address(vault)), 0);

        // check the specific token is owned by this contract
        assertEq(nft.ownerOf(1), address(this));

        // check the vault no longer owns 1000 tokens
        assertEq(token.balanceOf(address(this)), 0);
    }

    function testBatchWithdraw(uint256 n) public {
        vm.assume(n > 0 && n <= 100);

        // mint n tokens to this contract & store their tokenIds
        uint256[] memory tokenIds = new uint256[](n);
        for (uint256 i = 0; i < n; i++) {
            vm.prank(address(vault));
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

    // Empty array tests - current contract allows empty arrays but returns 0
    function testEmptyArrayDeposit() public {
        uint256[] memory tokenIds = new uint256[](0);
        // Should return 0 with empty array
        uint256 mintAmount = vault.batchDeposit(tokenIds, address(this));
        assertEq(mintAmount, 0);
    }

    function testEmptyArrayWithdraw() public {
        uint256[] memory tokenIds = new uint256[](0);
        // Should return 0 with empty array
        uint256 burnAmount = vault.batchWithdraw(tokenIds, address(this));
        assertEq(burnAmount, 0);
    }

    // Different recipient tests
    function testDepositToAnotherAddress() public {
        // mint a token to this contract
        vm.prank(address(vault));
        nft.mint(address(this), 1);

        // approve the vault to transfer the token
        nft.approve(address(vault), 1);

        // deposit the token but send ERC20 to alice
        vault.deposit(1, alice);

        // check the vault now owns 1 token
        assertEq(nft.balanceOf(address(vault)), 1);

        // check alice received the tokens
        assertEq(token.balanceOf(alice), 1000 * 10**18);
        
        // this contract should have 0 tokens
        assertEq(token.balanceOf(address(this)), 0);
    }

    function testWithdrawToAnotherAddress() public {
        // mint a token to this contract
        vm.prank(address(vault));
        nft.mint(address(this), 1);

        // approve the vault to transfer the token
        nft.approve(address(vault), 1);

        // deposit the token
        vault.deposit(1, address(this));

        // approve the vault to move out erc20 tokens
        token.approve(address(vault), 1000 * 10**18);

        // withdraw the token but send it to alice
        vault.withdraw(1, alice);

        // check the vault no longer owns the token
        assertEq(nft.balanceOf(address(vault)), 0);

        // check alice owns the token now
        assertEq(nft.ownerOf(1), alice);
        
        // this contract should have 0 tokens
        assertEq(token.balanceOf(address(this)), 0);
    }

    // Approval tests
    function testDepositWithoutApproval() public {
        // mint a token to this contract
        vm.prank(address(vault));
        nft.mint(address(this), 1);

        // do NOT approve the vault to transfer the token

        // try deposit - should fail
        vm.expectRevert();
        vault.deposit(1, address(this));
    }
    
    function testWithdrawWithoutApproval() public {
        // mint a token to this contract
        vm.prank(address(vault));
        nft.mint(address(this), 1);

        // approve and deposit the token
        nft.approve(address(vault), 1);
        vault.deposit(1, address(this));

        // do NOT approve the vault to transfer the tokens back
        // try withdraw - should fail
        vm.expectRevert();
        vault.withdraw(1, address(this));
    }

    // Attempt to withdraw token not owned by vault
    function testWithdrawNonexistentToken() public {
        // mint a token to this contract but don't deposit it
        vm.prank(address(vault));
        nft.mint(address(this), 999);
        
        // approve the vault to transfer ERC20 tokens
        token.approve(address(vault), 1000 * 10**18);

        // try withdraw - should fail because vault doesn't own the token
        vm.expectRevert();
        vault.withdraw(999, address(this));
    }

    /**
     * @dev Tests that reentrancy protection works during deposit
     * 
     * This test attempts to perform a reentrancy attack during the ERC721 transfer 
     * callback by calling deposit again within onERC721Received. The nonreentrant
     * decorator in the vault should prevent this attack.
     */
    function testReentrancyProtectionOnDeposit() public {
        // Set up the attack by minting a token to the attacker
        vm.prank(address(vault));
        nft.mint(address(attacker), 42);
        
        // Configure the attacker to attempt reentrancy during deposit
        attacker.setTokenId(42);
        attacker.setAttackOnDeposit(true);
        attacker.approveAll();
        
        // Execute the attack (initial deposit with reentrancy attempt)
        attacker.attack(42);
        
        // Verify only one token was minted (reentrancy failed)
        // If reentrancy succeeded, balance would be 2000 * 10**18
        assertEq(token.balanceOf(address(attacker)), 1000 * 10**18);
    }
    
    /**
     * @dev Tests that reentrancy protection works during withdraw
     * 
     * This test first deposits a token, then attempts a theoretical reentrancy
     * attack during the withdrawal process. Although our implementation doesn't 
     * directly trigger the attack (due to safeTransferFrom behavior), this test 
     * validates that a standard withdraw functions correctly with the reentrancy 
     * guard in place.
     */
    function testReentrancyProtectionOnWithdraw() public {
        // Set up the attack 
        vm.prank(address(vault));
        nft.mint(address(attacker), 42);
        
        // Configure the attacker
        attacker.setTokenId(42);
        attacker.approveAll();
        
        // First perform a legitimate deposit
        attacker.attack(42);
        
        // Configure the attack for withdraw phase
        attacker.setAttackOnWithdraw(true);
        attacker.setAttacked(false);
        
        // Perform the withdrawal with theoretical attack attempt
        attacker.withdrawAttack();
        
        // Verify tokens were burned and NFT was withdrawn properly
        assertEq(nft.balanceOf(address(vault)), 0);
        assertEq(nft.ownerOf(42), address(attacker));
        assertEq(token.balanceOf(address(attacker)), 0);
    }

    // Max token tests
    function testMaxTokensInBatch() public {
        uint256 n = 100; // Max allowed by the contract
        
        // mint n tokens to this contract & store their tokenIds
        uint256[] memory tokenIds = new uint256[](n);
        for (uint256 i = 0; i < n; i++) {
            vm.prank(address(vault));
            nft.mint(address(this), i);
            tokenIds[i] = i;
        }

        // approve the vault to transfer the tokens
        nft.setApprovalForAll(address(vault), true);

        // deposit should succeed with max tokens
        vault.batchDeposit(tokenIds, address(this));
        
        // check balances
        assertEq(nft.balanceOf(address(vault)), n);
        assertEq(token.balanceOf(address(this)), n * 1000 * 10**18);
    }
    
    function testOverMaxTokensInBatch() public {
        uint256 n = 101; // One over max allowed
        
        // mint n tokens to this contract & store their tokenIds
        uint256[] memory tokenIds = new uint256[](n);
        for (uint256 i = 0; i < n; i++) {
            vm.prank(address(vault));
            nft.mint(address(this), i);
            tokenIds[i] = i;
        }

        // approve the vault to transfer the tokens
        nft.setApprovalForAll(address(vault), true);

        // deposit should fail with more than max tokens
        vm.expectRevert();
        vault.batchDeposit(tokenIds, address(this));
    }

    // Quote function tests
    function testQuoteFunctions(uint256 n) public view {
        vm.assume(n < 1000); // Reasonable upper bound to avoid overflow
        
        uint256 quoteDepositAmount = vault.quoteDeposit(n);
        uint256 quoteWithdrawAmount = vault.quoteWithdraw(n);
        
        // Both should be equal and follow the formula: n * UNIT
        assertEq(quoteDepositAmount, n * 1000 * 10**18);
        assertEq(quoteWithdrawAmount, n * 1000 * 10**18);
        assertEq(quoteDepositAmount, quoteWithdrawAmount);
    }

    /**
     * @dev Invariant test to verify core protocol balance relationship
     * 
     * This test ensures that the fundamental invariant of the RemyVault protocol is maintained:
     * token_total_supply = vault_nft_balance * UNIT
     * 
     * This invariant should hold true no matter what operations are performed on the vault.
     * If this invariant is ever broken, it indicates a severe bug in the protocol that could
     * lead to insolvency (more tokens than NFTs) or trapped assets (more NFTs than tokens).
     */
    function invariant_tokenSupply() public view {
        // Calculate the actual NFT balance of the vault
        uint256 vaultNFTBalance = nft.balanceOf(address(vault));
        
        // Get the current total supply of the ERC20 token
        uint256 totalSupply = token.totalSupply();
        
        // Calculate what the ERC20 supply should be based on the NFT count
        uint256 expectedSupply = vault.quoteDeposit(vaultNFTBalance);
        
        // Verify the invariant holds
        assertEq(totalSupply, expectedSupply, "Invariant broken: token supply != NFT balance * UNIT");
    }

    function onERC721Received(address, address, uint256, bytes memory) public pure returns (bytes4) {
        return this.onERC721Received.selector;
    }
}
