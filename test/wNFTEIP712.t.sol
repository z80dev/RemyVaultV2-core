// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Test} from "forge-std/Test.sol";
import {wNFT} from "../src/wNFT.sol";
import {IERC721} from "../src/interfaces/IERC721.sol";
import {IERC20} from "../src/interfaces/IERC20.sol";

interface IMockERC721 is IERC721 {
    function mint(address to, uint256 tokenId) external;
    function burn(uint256 tokenId) external;
    function setApprovalForAll(address operator, bool approved) external;
}

interface Ownable {
    function owner() external view returns (address);
    function transfer_ownership(address newOwner) external;
}

/**
 * @title RemyVaultEIP712Test
 * @dev Comprehensive test suite for EIP712 permit functionality in wNFT
 *
 * Tests cover:
 * - Valid permit signatures with correct parameters
 * - Signature replay protection
 * - Deadline enforcement
 * - Invalid signature detection
 * - Nonce management
 * - Domain separator validation
 * - Edge cases (max approvals, expired permits)
 */
contract RemyVaultEIP712Test is Test {
    wNFT public vault;
    IMockERC721 public nft;

    address public owner;
    uint256 public ownerPrivateKey;
    address public spender;
    address public alice;

    uint256 internal constant UNIT = 1e18;

    // EIP712 type hash for permit
    bytes32 public constant PERMIT_TYPEHASH =
        keccak256("Permit(address owner,address spender,uint256 value,uint256 nonce,uint256 deadline)");

    function setUp() public {
        // Setup test accounts
        ownerPrivateKey = 0xA11CE;
        owner = vm.addr(ownerPrivateKey);
        spender = makeAddr("spender");
        alice = makeAddr("alice");

        // Deploy contracts
        nft = IMockERC721(deployCode("MockERC721", abi.encode("MOCK", "MOCK", "https://", "MOCK", "1.0")));
        vault = new wNFT(address(nft));

        // Transfer NFT ownership to vault for minting
        Ownable(address(nft)).transfer_ownership(address(vault));

        // Give owner some tokens by depositing NFTs
        vm.startPrank(address(vault));
        nft.mint(owner, 1);
        nft.mint(owner, 2);
        nft.mint(owner, 3);
        vm.stopPrank();

        vm.startPrank(owner);
        nft.setApprovalForAll(address(vault), true);
        uint256[] memory tokenIds = new uint256[](3);
        tokenIds[0] = 1;
        tokenIds[1] = 2;
        tokenIds[2] = 3;
        vault.deposit(tokenIds, owner);
        vm.stopPrank();

        assertEq(vault.balanceOf(owner), 3 * UNIT, "owner should have 3 UNIT tokens");
    }

    function testPermit_ValidSignature() public {
        uint256 value = 1 * UNIT;
        uint256 deadline = block.timestamp + 1 hours;
        uint256 nonce = vault.nonces(owner);

        bytes32 structHash = keccak256(abi.encode(PERMIT_TYPEHASH, owner, spender, value, nonce, deadline));

        bytes32 digest = _getDigest(structHash);
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(ownerPrivateKey, digest);

        // Verify no approval before permit
        assertEq(vault.allowance(owner, spender), 0, "should have no allowance before permit");

        // Execute permit
        vault.permit(owner, spender, value, deadline, v, r, s);

        // Verify approval after permit
        assertEq(vault.allowance(owner, spender), value, "allowance should match permit value");
        assertEq(vault.nonces(owner), nonce + 1, "nonce should increment");
    }

    function testPermit_MaxApproval() public {
        uint256 value = type(uint256).max;
        uint256 deadline = block.timestamp + 1 hours;
        uint256 nonce = vault.nonces(owner);

        bytes32 structHash = keccak256(abi.encode(PERMIT_TYPEHASH, owner, spender, value, nonce, deadline));

        bytes32 digest = _getDigest(structHash);
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(ownerPrivateKey, digest);

        vault.permit(owner, spender, value, deadline, v, r, s);

        assertEq(vault.allowance(owner, spender), type(uint256).max, "should allow max uint256");
    }

    function testPermit_ExpiredDeadline() public {
        uint256 value = 1 * UNIT;
        uint256 deadline = block.timestamp - 1; // Already expired
        uint256 nonce = vault.nonces(owner);

        bytes32 structHash = keccak256(abi.encode(PERMIT_TYPEHASH, owner, spender, value, nonce, deadline));

        bytes32 digest = _getDigest(structHash);
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(ownerPrivateKey, digest);

        // Should revert on expired deadline
        vm.expectRevert();
        vault.permit(owner, spender, value, deadline, v, r, s);
    }

    function testPermit_ReplayProtection() public {
        uint256 value = 1 * UNIT;
        uint256 deadline = block.timestamp + 1 hours;
        uint256 nonce = vault.nonces(owner);

        bytes32 structHash = keccak256(abi.encode(PERMIT_TYPEHASH, owner, spender, value, nonce, deadline));

        bytes32 digest = _getDigest(structHash);
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(ownerPrivateKey, digest);

        // First permit should succeed
        vault.permit(owner, spender, value, deadline, v, r, s);
        assertEq(vault.allowance(owner, spender), value);

        // Second permit with same signature should fail (nonce mismatch)
        vm.expectRevert();
        vault.permit(owner, spender, value, deadline, v, r, s);
    }

    function testPermit_InvalidSignature() public {
        uint256 value = 1 * UNIT;
        uint256 deadline = block.timestamp + 1 hours;
        uint256 nonce = vault.nonces(owner);

        bytes32 structHash = keccak256(abi.encode(PERMIT_TYPEHASH, owner, spender, value, nonce, deadline));

        bytes32 digest = _getDigest(structHash);

        // Sign with wrong private key
        uint256 wrongPrivateKey = 0xBAD;
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(wrongPrivateKey, digest);

        // Should revert with invalid signature
        vm.expectRevert();
        vault.permit(owner, spender, value, deadline, v, r, s);
    }

    function testPermit_WrongNonce() public {
        uint256 value = 1 * UNIT;
        uint256 deadline = block.timestamp + 1 hours;
        uint256 wrongNonce = vault.nonces(owner) + 1; // Use wrong nonce

        bytes32 structHash = keccak256(abi.encode(PERMIT_TYPEHASH, owner, spender, value, wrongNonce, deadline));

        bytes32 digest = _getDigest(structHash);
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(ownerPrivateKey, digest);

        // Should revert with wrong nonce
        vm.expectRevert();
        vault.permit(owner, spender, value, deadline, v, r, s);
    }

    function testPermit_WrongValue() public {
        uint256 signedValue = 1 * UNIT;
        uint256 submittedValue = 2 * UNIT; // Different value
        uint256 deadline = block.timestamp + 1 hours;
        uint256 nonce = vault.nonces(owner);

        bytes32 structHash = keccak256(abi.encode(PERMIT_TYPEHASH, owner, spender, signedValue, nonce, deadline));

        bytes32 digest = _getDigest(structHash);
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(ownerPrivateKey, digest);

        // Should revert when submitted value doesn't match signed value
        vm.expectRevert();
        vault.permit(owner, spender, submittedValue, deadline, v, r, s);
    }

    function testPermit_WrongSpender() public {
        uint256 value = 1 * UNIT;
        uint256 deadline = block.timestamp + 1 hours;
        uint256 nonce = vault.nonces(owner);
        address wrongSpender = makeAddr("wrongSpender");

        bytes32 structHash = keccak256(abi.encode(PERMIT_TYPEHASH, owner, spender, value, nonce, deadline));

        bytes32 digest = _getDigest(structHash);
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(ownerPrivateKey, digest);

        // Should revert when spender doesn't match
        vm.expectRevert();
        vault.permit(owner, wrongSpender, value, deadline, v, r, s);
    }

    function testPermit_WrongOwner() public {
        uint256 value = 1 * UNIT;
        uint256 deadline = block.timestamp + 1 hours;
        uint256 nonce = vault.nonces(owner);

        bytes32 structHash = keccak256(abi.encode(PERMIT_TYPEHASH, owner, spender, value, nonce, deadline));

        bytes32 digest = _getDigest(structHash);
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(ownerPrivateKey, digest);

        // Should revert when owner doesn't match signature
        vm.expectRevert();
        vault.permit(alice, spender, value, deadline, v, r, s);
    }

    function testPermit_MultiplePermitsIncrementNonce() public {
        uint256 value = 1 * UNIT;
        uint256 deadline = block.timestamp + 1 hours;

        for (uint256 i = 0; i < 3; i++) {
            uint256 nonce = vault.nonces(owner);
            assertEq(nonce, i, "nonce should match iteration");

            address currentSpender = makeAddr(string(abi.encodePacked("spender", i)));

            bytes32 structHash = keccak256(abi.encode(PERMIT_TYPEHASH, owner, currentSpender, value, nonce, deadline));

            bytes32 digest = _getDigest(structHash);
            (uint8 v, bytes32 r, bytes32 s) = vm.sign(ownerPrivateKey, digest);

            vault.permit(owner, currentSpender, value, deadline, v, r, s);
            assertEq(vault.allowance(owner, currentSpender), value);
        }

        assertEq(vault.nonces(owner), 3, "nonce should be 3 after 3 permits");
    }

    function testPermit_CanSpendAfterPermit() public {
        uint256 value = 1 * UNIT;
        uint256 deadline = block.timestamp + 1 hours;
        uint256 nonce = vault.nonces(owner);

        bytes32 structHash = keccak256(abi.encode(PERMIT_TYPEHASH, owner, spender, value, nonce, deadline));

        bytes32 digest = _getDigest(structHash);
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(ownerPrivateKey, digest);

        vault.permit(owner, spender, value, deadline, v, r, s);

        // Spender should be able to transfer tokens
        vm.prank(spender);
        vault.transferFrom(owner, alice, value);

        assertEq(vault.balanceOf(alice), value, "alice should receive tokens");
        assertEq(vault.balanceOf(owner), 2 * UNIT, "owner balance should decrease");
        assertEq(vault.allowance(owner, spender), 0, "allowance should be consumed");
    }

    function testPermit_FuzzValidPermit(uint256 value, uint256 timeOffset) public {
        // Bound inputs to reasonable ranges
        value = bound(value, 0, 3 * UNIT); // Owner has 3 UNIT
        timeOffset = bound(timeOffset, 1, 365 days);

        uint256 deadline = block.timestamp + timeOffset;
        uint256 nonce = vault.nonces(owner);

        bytes32 structHash = keccak256(abi.encode(PERMIT_TYPEHASH, owner, spender, value, nonce, deadline));

        bytes32 digest = _getDigest(structHash);
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(ownerPrivateKey, digest);

        vault.permit(owner, spender, value, deadline, v, r, s);

        assertEq(vault.allowance(owner, spender), value);
    }

    function testDomainSeparator() public view {
        bytes32 domainSeparator = vault.DOMAIN_SEPARATOR();
        assertNotEq(domainSeparator, bytes32(0), "domain separator should not be zero");
    }

    function testEIP712Version() public view {
        // The vault should use version "1.0" and name from the NFT collection
        bytes32 domainSeparator = vault.DOMAIN_SEPARATOR();

        bytes32 expectedDomainSeparator = keccak256(
            abi.encode(
                keccak256("EIP712Domain(string name,string version,uint256 chainId,address verifyingContract)"),
                keccak256(bytes(vault.name())),
                keccak256(bytes("1.0")),
                block.chainid,
                address(vault)
            )
        );

        assertEq(domainSeparator, expectedDomainSeparator, "domain separator mismatch");
    }

    // Helper function to compute EIP712 digest
    function _getDigest(bytes32 structHash) internal view returns (bytes32) {
        return keccak256(abi.encodePacked("\x19\x01", vault.DOMAIN_SEPARATOR(), structHash));
    }
}
