// SPDX-License-Identifier: MIT

pragma solidity >=0.8.7 <0.9.0;

import {Test} from "forge-std/Test.sol";
import {IwNFT} from "../src/interfaces/IwNFT.sol";
import {IERC721} from "../src/interfaces/IERC721.sol";
import {IERC20} from "../src/interfaces/IERC20.sol";
import {StdInvariant} from "forge-std/StdInvariant.sol";
import {ReentrancyAttacker} from "./helpers/ReentrancyAttacker.sol";
import {wNFT} from "../src/wNFT.sol";
import {wNFTEIP712} from "../src/wNFTEIP712.sol";
import {MockERC721Simple} from "./helpers/MockERC721Simple.sol";

interface IMockERC721 is IERC721 {
    function mint(address to, uint256 tokenId) external;
    function burn(uint256 tokenId) external;
    function setApprovalForAll(address operator, bool approved) external;
    function getApproved(uint256 tokenId) external view returns (address);
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
 * @title RemyVaultTest
 * @dev Comprehensive test suite for the wNFT contract
 *
 * This test suite validates all aspects of the wNFT protocol including:
 * - Deposit/withdraw functionality for single and multiple NFTs
 * - Token balance tracking and invariants
 * - Security properties (reentrancy protection)
 * - Edge cases (empty arrays, approval failures, etc.)
 * - Boundary conditions (max token limits)
 */
contract RemyVaultTest is Test {
    uint256 internal UNIT;
    /// @notice Mock ERC721 token representing NFTs
    IMockERC721 public nft;

    /// @notice Mock ERC20 token representing fungible tokens
    IERC20 public token;

    /// @notice wNFT contract instance being tested (also the ERC20 token)
    IwNFT public vault;

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
     * 1. Deploys the mock ERC721 contract
     * 2. Deploys the wNFT contract which mints/burns its own ERC20 supply
     * 3. Transfers ownership of the NFT contract to the vault so it can mint/burn
     * 4. Creates test user addresses and the reentrancy attack contract
     * 5. Configures Foundry's invariant testing properties
     */
    function setUp() public {
        // Deploy mock contracts
        MockERC721Simple deployed = new MockERC721Simple("MOCK", "MOCK");
        nft = IMockERC721(address(deployed));

        // Deploy the vault (which manages its own ERC20 supply)
        wNFT deployedVault = new wNFT(address(nft));
        vault = IwNFT(address(deployedVault));
        UNIT = deployedVault.quoteDeposit(1);

        // Treat the vault itself as the ERC20 token
        token = IERC20(address(vault));

        // Transfer ownership of the mock NFT to the vault so it can mint/burn
        Ownable(address(nft)).transfer_ownership(address(vault));

        // Create test addresses
        alice = makeAddr("alice");
        bob = makeAddr("bob");

        // Deploy the reentrancy attacker contract
        attacker = new ReentrancyAttacker(address(vault), address(nft), address(token));

        // Configure invariant test properties
        excludeSender(address(vault));

        bytes4[] memory selectors = new bytes4[](2);
        selectors[0] = IwNFT.deposit.selector;
        selectors[1] = IwNFT.withdraw.selector;
        targetSelector(StdInvariant.FuzzSelector({addr: address(vault), selectors: selectors}));
    }

    function testManualTransferWithApproval() public {
        vm.prank(address(vault));
        nft.mint(address(this), 2);

        nft.approve(address(vault), 2);

        vm.prank(address(vault));
        nft.transferFrom(address(this), address(vault), 2);

        assertEq(nft.ownerOf(2), address(vault));
    }

    function testSetup() public view {
        assertEq(nft.balanceOf(address(vault)), 0);
        assertEq(token.balanceOf(address(vault)), 0);
        assertNotEq(address(nft), address(0));
    }

    function testSingleDeposit() public {
        // mint a token to this contract
        vm.prank(address(vault));
        nft.mint(address(this), 1);

        // approve the vault to transfer the token
        nft.approve(address(vault), 1);

        // sanity check approval recorded
        assertEq(nft.getApproved(1), address(vault));

        // create array with single tokenId
        uint256[] memory tokenIds = new uint256[](1);
        tokenIds[0] = 1;

        // deposit the token
        vault.deposit(tokenIds, address(this));

        // check the vault now owns 1 token
        assertEq(nft.balanceOf(address(vault)), 1);

        // check the specific token is owned by the vault
        assertEq(nft.ownerOf(1), address(vault));

        // check the vault minted us 1 token
        assertEq(token.balanceOf(address(this)), UNIT);
    }

    function testBatchDeposit(uint256 n) public {
        // batch deposits limited to 100 tokenIds for gas reasons
        vm.assume(n < 101);
        vm.assume(n > 0);

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
        vault.deposit(tokenIds, address(this));

        // check the vault now owns n tokens
        assertEq(nft.balanceOf(address(vault)), n);

        // check the vault minted us 1 token per tokenId
        assertEq(token.balanceOf(address(this)), n * UNIT);
    }

    function testSingleWithdraw() public {
        // mint a token to this contract
        vm.prank(address(vault));
        nft.mint(address(this), 1);

        // approve the vault to transfer the token
        nft.approve(address(vault), 1);

        // create array with single tokenId
        uint256[] memory tokenIds = new uint256[](1);
        tokenIds[0] = 1;

        // deposit the token
        vault.deposit(tokenIds, address(this));

        // legacy approve retained for parity with original vault (not required in ERC20 version)
        token.approve(address(vault), UNIT);

        // withdraw the token
        vault.withdraw(tokenIds, address(this));

        // check the vault no longer owns the token
        assertEq(nft.balanceOf(address(vault)), 0);

        // check the specific token is owned by this contract
        assertEq(nft.ownerOf(1), address(this));

        // check the vault no longer owns 1 token
        assertEq(token.balanceOf(address(this)), 0);
    }

    /**
     * @dev Tests that users cannot withdraw NFTs that were directly transferred to the vault
     *
     * This test verifies the contract doesn't allow withdrawing NFTs that were transferred
     * directly to the vault (bypassing the deposit function). This is important to prevent
     * users from claiming tokens for NFTs they didn't properly deposit.
     */
    function testDirectNFTTransferBypass() public {
        // Mint a token to this contract
        vm.prank(address(vault));
        nft.mint(address(this), 999);

        // Transfer the NFT directly to the vault, bypassing the deposit function
        nft.transferFrom(address(this), address(vault), 999);

        // Verify the vault now directly owns the NFT
        assertEq(nft.ownerOf(999), address(vault));

        // We didn't get any tokens because we bypassed deposit
        assertEq(token.balanceOf(address(this)), 0);

        // Approve the vault to burn tokens (when we try to withdraw)
        token.approve(address(vault), UNIT);

        // Try to withdraw the NFT - should revert since we never deposited it properly
        // The withdraw function checks the vault owns the token (which it does), but we
        // have no tokens to burn for withdrawal
        uint256[] memory tokenIds = new uint256[](1);
        tokenIds[0] = 999;
        vm.expectRevert();
        vault.withdraw(tokenIds, address(this));

        // Verify the NFT is still in the vault
        assertEq(nft.ownerOf(999), address(vault));

        // Now let's try another approach - try to get tokens by depositing a different NFT
        // then use those tokens to withdraw the directly transferred NFT

        // Mint and deposit a second token properly
        vm.prank(address(vault));
        nft.mint(address(this), 888);
        nft.approve(address(vault), 888);

        uint256[] memory depositTokenIds = new uint256[](1);
        depositTokenIds[0] = 888;
        vault.deposit(depositTokenIds, address(this));

        // We now have 1 token
        assertEq(token.balanceOf(address(this)), UNIT);

        // Try to use these tokens to withdraw the directly transferred NFT
        token.approve(address(vault), UNIT);

        // This should succeed technically, as the withdraw function only checks:
        // 1. The vault owns the token (it does)
        // 2. The caller has enough tokens to burn (they do)
        // But this represents a security vulnerability if it succeeds
        uint256[] memory withdrawTokenIds = new uint256[](1);
        withdrawTokenIds[0] = 999;
        vault.withdraw(withdrawTokenIds, address(this));

        // Check if the directly transferred NFT was withdrawn
        // If this passes, we have a security issue!
        assertEq(nft.ownerOf(999), address(this));

        // The token balance should now be 0 since we burned tokens
        assertEq(token.balanceOf(address(this)), 0);

        // check that safeTransferFrom reverts
        vm.expectRevert();
        nft.safeTransferFrom(address(vault), address(this), 999);
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
        vault.deposit(tokenIds, address(this));

        // legacy approve retained for parity with original vault (not required in ERC20 version)
        token.approve(address(vault), n * UNIT);

        // withdraw the tokens
        vault.withdraw(tokenIds, address(this));

        // check the vault no longer owns the tokens
        assertEq(nft.balanceOf(address(vault)), 0);

        // check the vault no longer owns 1 token per tokenId
        assertEq(token.balanceOf(address(this)), 0);
    }

    // Empty array tests
    function testEmptyArrayDeposit() public {
        uint256[] memory tokenIds = new uint256[](0);
        // expect revert
        vm.expectRevert();
        vault.deposit(tokenIds, address(this));
    }

    function testEmptyArrayWithdraw() public {
        uint256[] memory tokenIds = new uint256[](0);
        // expect revert
        vm.expectRevert();
        vault.withdraw(tokenIds, address(this));
    }

    // Different recipient tests
    function testDepositToAnotherAddress() public {
        // mint a token to this contract
        vm.prank(address(vault));
        nft.mint(address(this), 1);

        // approve the vault to transfer the token
        nft.approve(address(vault), 1);

        // create array with single tokenId
        uint256[] memory tokenIds = new uint256[](1);
        tokenIds[0] = 1;

        // deposit the token but send ERC20 to alice
        vault.deposit(tokenIds, alice);

        // check the vault now owns 1 token
        assertEq(nft.balanceOf(address(vault)), 1);

        // check alice received the tokens
        assertEq(token.balanceOf(alice), UNIT);

        // this contract should have 0 tokens
        assertEq(token.balanceOf(address(this)), 0);
    }

    function testWithdrawToAnotherAddress() public {
        // mint a token to this contract
        vm.prank(address(vault));
        nft.mint(address(this), 1);

        // approve the vault to transfer the token
        nft.approve(address(vault), 1);

        // create array with single tokenId
        uint256[] memory tokenIds = new uint256[](1);
        tokenIds[0] = 1;

        // deposit the token
        vault.deposit(tokenIds, address(this));

        // legacy approve retained for parity with original vault (not required in ERC20 version)
        token.approve(address(vault), UNIT);

        // withdraw the token but send it to alice
        vault.withdraw(tokenIds, alice);

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
        uint256[] memory tokenIds = new uint256[](1);
        tokenIds[0] = 1;

        // try deposit - should fail
        vm.expectRevert();
        vault.deposit(tokenIds, address(this));
    }

    function testWithdrawWithoutApproval() public {
        // mint a token to this contract
        vm.prank(address(vault));
        nft.mint(address(this), 1);

        // approve and deposit the token
        nft.approve(address(vault), 1);

        uint256[] memory tokenIds = new uint256[](1);
        tokenIds[0] = 1;
        vault.deposit(tokenIds, address(this));

        // do NOT approve the vault to transfer the tokens back (not required in the ERC20 version)
        vault.withdraw(tokenIds, address(this));

        // verify withdrawal succeeded without prior approval
        assertEq(nft.ownerOf(1), address(this));
        assertEq(token.balanceOf(address(this)), 0);
    }

    // Attempt to withdraw token not owned by vault
    function testWithdrawNonexistentToken() public {
        // mint a token to this contract but don't deposit it
        vm.prank(address(vault));
        nft.mint(address(this), 999);

        // approve the vault to transfer ERC20 tokens
        token.approve(address(vault), UNIT);

        // try withdraw - should fail because vault doesn't own the token
        uint256[] memory tokenIds = new uint256[](1);
        tokenIds[0] = 999;
        vm.expectRevert();
        vault.withdraw(tokenIds, address(this));
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
        assertEq(token.balanceOf(address(attacker)), UNIT);
    }

    /**
     * @dev Tests that reentrancy protection works during withdraw
     *
     * This test deposits a token, then attempts a reentrancy attack during withdrawal.
     * When the NFT is transferred to the attacker during withdraw, onERC721Received
     * is called, where the attacker attempts to call withdraw again. This should fail
     * because the tokens have already been burned.
     */
    function testReentrancyProtectionOnWithdraw() public {
        // Set up the attack - mint token to attacker
        vm.prank(address(vault));
        nft.mint(address(attacker), 42);

        // Configure the attacker
        attacker.setTokenId(42);
        attacker.approveAll();

        // First perform a legitimate deposit
        attacker.attack(42);

        // Verify deposit succeeded - attacker has tokens and vault has NFT
        assertEq(token.balanceOf(address(attacker)), UNIT);
        assertEq(nft.ownerOf(42), address(vault));

        // Configure the attack for withdraw phase
        attacker.setAttackOnWithdraw(true);
        attacker.setAttacked(false);

        // Perform the withdrawal - this will trigger reentrancy attempt in onERC721Received
        attacker.withdrawAttack();

        // Verify the withdrawal succeeded despite reentrancy attempt
        assertEq(nft.balanceOf(address(vault)), 0);
        assertEq(nft.ownerOf(42), address(attacker));
        // Tokens should be burned - reentrancy attempt should not have minted more
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
        vault.deposit(tokenIds, address(this));

        // check balances
        assertEq(nft.balanceOf(address(vault)), n);
        assertEq(token.balanceOf(address(this)), n * UNIT);
    }

    // Quote function tests
    function testQuoteFunctions(uint256 n) public view {
        vm.assume(n < 1000); // Reasonable upper bound to avoid overflow

        uint256 quoteDepositAmount = vault.quoteDeposit(n);
        uint256 quoteWithdrawAmount = vault.quoteWithdraw(n);

        // Both should be equal and follow the formula: n * UNIT
        assertEq(quoteDepositAmount, n * UNIT);
        assertEq(quoteWithdrawAmount, n * UNIT);
        assertEq(quoteDepositAmount, quoteWithdrawAmount);
    }

    function testSequentialDepositWithdraw() public {
        // Test that depositing and withdrawing multiple times in sequence works correctly
        for (uint256 i = 0; i < 5; i++) {
            // Mint and deposit
            vm.prank(address(vault));
            nft.mint(address(this), i);
            nft.approve(address(vault), i);

            uint256[] memory tokenIds = new uint256[](1);
            tokenIds[0] = i;
            vault.deposit(tokenIds, address(this));

            // Verify state after deposit
            assertEq(nft.ownerOf(i), address(vault));
            assertEq(token.balanceOf(address(this)), (i + 1) * UNIT);
        }

        for (uint256 i = 0; i < 5; i++) {
            // Withdraw
            token.approve(address(vault), UNIT);

            uint256[] memory tokenIds = new uint256[](1);
            tokenIds[0] = i;
            vault.withdraw(tokenIds, address(this));

            // Verify state after withdrawal
            assertEq(nft.ownerOf(i), address(this));
            assertEq(token.balanceOf(address(this)), (4 - i) * UNIT);
        }
    }

    function testPartialBatchWithdraw() public {
        uint256 n = 10;

        // Mint and deposit 10 tokens
        uint256[] memory allTokenIds = new uint256[](n);
        for (uint256 i = 0; i < n; i++) {
            vm.prank(address(vault));
            nft.mint(address(this), i);
            allTokenIds[i] = i;
        }

        nft.setApprovalForAll(address(vault), true);
        vault.deposit(allTokenIds, address(this));

        // Withdraw only half of them
        uint256[] memory halfTokenIds = new uint256[](n / 2);
        for (uint256 i = 0; i < n / 2; i++) {
            halfTokenIds[i] = i;
        }

        token.approve(address(vault), (n * UNIT) / 2);
        vault.withdraw(halfTokenIds, address(this));

        // Verify state: should have half NFTs and half tokens remaining
        assertEq(nft.balanceOf(address(vault)), n / 2);
        assertEq(token.balanceOf(address(this)), (n * UNIT) / 2);
    }

    function testNonManagerCannotMintBurn() public {
        // Try to directly mint tokens
        vm.prank(alice);
        vm.expectRevert();
        vault.mint(alice, UNIT);

        // Try to directly burn tokens
        vm.prank(alice);
        vm.expectRevert();
        vault.burn(UNIT);
    }

    /**
     * @dev Invariant test to verify core protocol balance relationship
     *
     * This test ensures that the fundamental invariant of the wNFT protocol is maintained:
     * token_total_supply = vault_nft_balance * UNIT
     *
     * This invariant should hold true no matter what operations are performed on the vault.
     * If this invariant is ever broken, it indicates a severe bug in the protocol that could
     * lead to insolvency (more tokens than NFTs) or trapped assets (more NFTs than tokens).
     */
    function invariant_tokenSupply() public view {
        // Calculate the actual NFT balance of the vault
        uint256 vaultNftBalance = nft.balanceOf(address(vault));

        // Get the current total supply of the ERC20 token
        uint256 totalSupply = token.totalSupply();

        // Calculate what the ERC20 supply should be based on the NFT count
        uint256 expectedSupply = vault.quoteDeposit(vaultNftBalance);

        // Verify the invariant holds
        assertEq(totalSupply, expectedSupply, "Invariant broken: token supply != NFT balance * UNIT");
    }

    function testSafeTransferToVault() public {
        // Mint a token to this contract
        vm.prank(address(vault));
        nft.mint(address(this), 42);

        // Verify initial state
        assertEq(nft.ownerOf(42), address(this));
        assertEq(nft.balanceOf(address(vault)), 0);

        // Safe transfer the NFT to the vault
        nft.safeTransferFrom(address(this), address(vault), 42);

        // Verify the vault received the NFT
        assertEq(nft.ownerOf(42), address(vault));
        assertEq(nft.balanceOf(address(vault)), 1);

        // Verify we didn't get any tokens (since we bypassed deposit)
        assertEq(token.balanceOf(address(this)), 0);
    }

    function testNonCompliantNFTDeploymentFails() public {
        // Deploy a contract that doesn't implement ERC721Metadata
        NonCompliantNFT nonCompliant = new NonCompliantNFT();

        // Attempt to deploy a vault for this non-compliant NFT should fail
        vm.expectRevert(
            abi.encodeWithSelector(wNFTEIP712.MetadataQueryFailed.selector, address(nonCompliant))
        );
        new wNFT(address(nonCompliant));
    }

    function onERC721Received(address, address, uint256, bytes memory) public pure returns (bytes4) {
        return this.onERC721Received.selector;
    }
}

/**
 * @title NonCompliantNFT
 * @dev A minimal contract that implements basic ERC721 functions but NOT the metadata interface
 * Used to test that vault deployment fails for non-compliant NFTs
 */
contract NonCompliantNFT {
    function balanceOf(address) external pure returns (uint256) {
        return 0;
    }

    function ownerOf(uint256) external pure returns (address) {
        return address(0);
    }

    // Deliberately does NOT implement name() and symbol()
}
