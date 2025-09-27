// SPDX-License-Identifier: MIT
pragma solidity >=0.8.7 <0.9.0;

import {Test} from "forge-std/Test.sol";
import {StdInvariant} from "forge-std/StdInvariant.sol";
import {IERC721} from "../src/interfaces/IERC721.sol";
import {IERC20} from "../src/interfaces/IERC20.sol";
import {RemyVaultSol} from "../src/RemyVaultSol.sol";

interface IMockERC721 is IERC721 {
    function mint(address to, uint256 tokenId) external;
    function burn(uint256 tokenId) external;
    function setApprovalForAll(address operator, bool approved) external;
}

interface Ownable {
    function transfer_ownership(address newOwner) external;
}

/// @notice Invariant suite verifying per-account bookkeeping of deposits and withdrawals.
contract RemyVaultAccountInvariantTest is Test {
    uint256 internal constant MAX_BATCH = 5;

    IMockERC721 internal nft;
    IERC20 internal token;
    RemyVaultSol internal vault;
    uint256 internal unit;

    address[] internal actors;
    mapping(address => bool) internal hasApproval;
    mapping(address => uint256) internal mintedFor;
    mapping(address => uint256) internal burnedFor;
    mapping(address => uint256[]) internal claimableIds;

    uint256 internal nextTokenId;

    function setUp() public {
        nft = IMockERC721(deployCode("MockERC721", abi.encode("MOCK", "MOCK", "https://", "MOCK", "1.0")));
        vault = new RemyVaultSol("MOCK", "MOCK", address(nft));
        unit = vault.quoteDeposit(1);

        token = IERC20(address(vault));
        Ownable(address(nft)).transfer_ownership(address(vault));

        actors.push(makeAddr("alice"));
        actors.push(makeAddr("bob"));
        actors.push(makeAddr("carol"));

        targetContract(address(this));
        bytes4[] memory selectors = new bytes4[](2);
        selectors[0] = this.handlerDeposit.selector;
        selectors[1] = this.handlerWithdraw.selector;
        targetSelector(StdInvariant.FuzzSelector({addr: address(this), selectors: selectors}));
    }

    function handlerDeposit(uint8 actorSeed, uint8 rawCount) public {
        address actor = actors[actorSeed % actors.length];
        uint256 depositCount = bound(uint256(rawCount), 1, MAX_BATCH);

        uint256[] memory tokenIds = new uint256[](depositCount);
        for (uint256 i; i < depositCount; ++i) {
            uint256 tokenId = nextTokenId++;
            vm.prank(address(vault));
            nft.mint(actor, tokenId);
            tokenIds[i] = tokenId;
        }

        if (!hasApproval[actor]) {
            vm.prank(actor);
            nft.setApprovalForAll(address(vault), true);
            hasApproval[actor] = true;
        }

        vm.prank(actor);
        vault.deposit(tokenIds, actor);

        for (uint256 i; i < depositCount; ++i) {
            claimableIds[actor].push(tokenIds[i]);
        }

        mintedFor[actor] += depositCount * unit;
    }

    function handlerWithdraw(uint8 actorSeed, uint8 rawCount) public {
        address actor = actors[actorSeed % actors.length];
        uint256 available = claimableIds[actor].length;
        if (available == 0) {
            return;
        }

        uint256 withdrawCount = bound(uint256(rawCount), 1, available);
        uint256[] memory tokenIds = new uint256[](withdrawCount);

        for (uint256 i; i < withdrawCount; ++i) {
            uint256 idx = claimableIds[actor].length - 1;
            tokenIds[i] = claimableIds[actor][idx];
            claimableIds[actor].pop();
        }

        vm.prank(actor);
        vault.withdraw(tokenIds, actor);

        burnedFor[actor] += withdrawCount * unit;
    }

    function invariant_perAccountBalancesMatchDeposits() public view {
        for (uint256 i; i < actors.length; ++i) {
            address actor = actors[i];
            uint256 minted = mintedFor[actor];
            uint256 burned = burnedFor[actor];
            uint256 expectedBalance = minted - burned;

            assertEq(token.balanceOf(actor), expectedBalance, "ERC20 balance mismatches minted/burned accounting");
            assertEq(
                claimableIds[actor].length * unit,
                expectedBalance,
                "Claimable NFT count mismatches outstanding ERC20 balance"
            );
        }
    }

    function invariant_vaultInventoryMatchesOutstandingTokens() public view {
        uint256 outstandingNfts;
        for (uint256 i; i < actors.length; ++i) {
            outstandingNfts += claimableIds[actors[i]].length;
        }

        assertEq(nft.balanceOf(address(vault)), outstandingNfts, "Vault NFT inventory inconsistent");
        assertEq(token.totalSupply(), outstandingNfts * unit, "ERC20 supply mismatches outstanding NFTs");
    }
}
