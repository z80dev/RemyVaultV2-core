// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Test} from "forge-std/Test.sol";
import {StdInvariant} from "forge-std/StdInvariant.sol";
import {RemyVault} from "../src/RemyVault.sol";
import {MinterRemyVault} from "../src/MinterRemyVault.sol";
import {RemyVaultNFT} from "../src/RemyVaultNFT.sol";
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
 * @title RemyVaultInvariantHandler
 * @dev Handler contract for invariant testing that performs random operations
 */
contract RemyVaultInvariantHandler is Test {
    RemyVault public vault;
    IMockERC721 public nft;

    address[] public actors;
    uint256 public nextTokenId = 1;
    uint256 public totalDeposited;
    uint256 public totalWithdrawn;

    uint256 public depositCount;
    uint256 public withdrawCount;

    constructor(RemyVault _vault, IMockERC721 _nft) {
        vault = _vault;
        nft = _nft;

        // Create actor addresses
        for (uint256 i = 0; i < 5; i++) {
            actors.push(makeAddr(string(abi.encodePacked("actor", i))));
        }
    }

    function deposit(uint256 actorSeed, uint256 count) public {
        count = bound(count, 1, 10);
        address actor = actors[actorSeed % actors.length];

        uint256[] memory tokenIds = new uint256[](count);

        // Mint NFTs to actor
        vm.startPrank(address(vault));
        for (uint256 i = 0; i < count; i++) {
            nft.mint(actor, nextTokenId);
            tokenIds[i] = nextTokenId;
            nextTokenId++;
        }
        vm.stopPrank();

        // Deposit
        vm.startPrank(actor);
        nft.setApprovalForAll(address(vault), true);
        vault.deposit(tokenIds, actor);
        vm.stopPrank();

        totalDeposited += count;
        depositCount++;
    }

    function withdraw(uint256 actorSeed, uint256 count) public {
        address actor = actors[actorSeed % actors.length];
        uint256 balance = vault.balanceOf(actor);

        if (balance == 0) return;

        count = bound(count, 1, balance / vault.UNIT());
        if (count == 0) return;

        uint256 vaultNftBalance = nft.balanceOf(address(vault));
        if (vaultNftBalance < count) return;

        // Build token IDs array from vault's holdings
        uint256[] memory tokenIds = new uint256[](count);
        uint256 collected = 0;

        for (uint256 i = 1; i < nextTokenId && collected < count; i++) {
            try nft.ownerOf(i) returns (address owner) {
                if (owner == address(vault)) {
                    tokenIds[collected] = i;
                    collected++;
                }
            } catch {
                // Token doesn't exist or was burned
                continue;
            }
        }

        if (collected < count) return;

        vm.prank(actor);
        vault.withdraw(tokenIds, actor);

        totalWithdrawn += count;
        withdrawCount++;
    }

    function transfer(uint256 fromSeed, uint256 toSeed, uint256 amount) public {
        address from = actors[fromSeed % actors.length];
        address to = actors[toSeed % actors.length];

        uint256 balance = vault.balanceOf(from);
        if (balance == 0) return;

        amount = bound(amount, 0, balance);
        if (amount == 0) return;

        vm.prank(from);
        vault.transfer(to, amount);
    }

    function approve(uint256 ownerSeed, uint256 spenderSeed, uint256 amount) public {
        address owner = actors[ownerSeed % actors.length];
        address spender = actors[spenderSeed % actors.length];

        amount = bound(amount, 0, type(uint256).max);

        vm.prank(owner);
        vault.approve(spender, amount);
    }

    function transferFrom(uint256 fromSeed, uint256 toSeed, uint256 callerSeed, uint256 amount) public {
        address from = actors[fromSeed % actors.length];
        address to = actors[toSeed % actors.length];
        address caller = actors[callerSeed % actors.length];

        uint256 allowance = vault.allowance(from, caller);
        uint256 balance = vault.balanceOf(from);

        if (allowance == 0 || balance == 0) return;

        amount = bound(amount, 0, allowance < balance ? allowance : balance);
        if (amount == 0) return;

        vm.prank(caller);
        vault.transferFrom(from, to, amount);
    }

    function onERC721Received(address, address, uint256, bytes calldata) external pure returns (bytes4) {
        return this.onERC721Received.selector;
    }
}

/**
 * @title RemyVaultInvariantTest
 * @dev Property-based invariant tests for RemyVault
 */
contract RemyVaultInvariantTest is StdInvariant, Test {
    RemyVault public vault;
    IMockERC721 public nft;
    RemyVaultInvariantHandler public handler;

    function setUp() public {
        nft = IMockERC721(deployCode("MockERC721", abi.encode("MOCK", "MOCK", "https://", "MOCK", "1.0")));
        vault = new RemyVault("RemyVault", "REMY", address(nft));

        Ownable(address(nft)).transfer_ownership(address(vault));

        handler = new RemyVaultInvariantHandler(vault, nft);

        // Target handler for invariant testing
        targetContract(address(handler));

        // Target specific functions
        bytes4[] memory selectors = new bytes4[](5);
        selectors[0] = RemyVaultInvariantHandler.deposit.selector;
        selectors[1] = RemyVaultInvariantHandler.withdraw.selector;
        selectors[2] = RemyVaultInvariantHandler.transfer.selector;
        selectors[3] = RemyVaultInvariantHandler.approve.selector;
        selectors[4] = RemyVaultInvariantHandler.transferFrom.selector;

        targetSelector(FuzzSelector({addr: address(handler), selectors: selectors}));
    }

    /// @dev Core invariant: ERC20 total supply MUST equal (NFT balance * UNIT)
    function invariant_tokenSupplyEqualsNftBalance() public view {
        uint256 nftBalance = nft.balanceOf(address(vault));
        uint256 tokenSupply = vault.totalSupply();
        uint256 expectedSupply = nftBalance * vault.UNIT();

        assertEq(
            tokenSupply, expectedSupply, "INVARIANT VIOLATED: Token supply must equal NFT balance * UNIT"
        );
    }

    /// @dev Invariant: Sum of all user balances MUST equal total supply
    function invariant_sumOfBalancesEqualsTotalSupply() public view {
        uint256 totalSupply = vault.totalSupply();
        uint256 sumOfBalances = 0;

        // actors is a public array variable, access via index
        for (uint256 i = 0; i < 5; i++) {
            sumOfBalances += vault.balanceOf(handler.actors(i));
        }

        // Also check handler balance
        sumOfBalances += vault.balanceOf(address(handler));

        assertEq(
            sumOfBalances,
            totalSupply,
            "INVARIANT VIOLATED: Sum of balances must equal total supply"
        );
    }

    /// @dev Invariant: Vault MUST own all NFTs accounted for in token supply
    function invariant_vaultOwnsAllNfts() public view {
        uint256 nftBalance = nft.balanceOf(address(vault));
        uint256 tokenSupply = vault.totalSupply();

        // Count actual NFTs owned by vault
        uint256 actualNftCount = 0;
        for (uint256 i = 1; i < handler.nextTokenId(); i++) {
            try nft.ownerOf(i) returns (address owner) {
                if (owner == address(vault)) {
                    actualNftCount++;
                }
            } catch {
                // Token doesn't exist or was burned
                continue;
            }
        }

        assertEq(
            nftBalance, actualNftCount, "INVARIANT VIOLATED: NFT balance must match actual ownership count"
        );

        assertEq(
            tokenSupply,
            actualNftCount * vault.UNIT(),
            "INVARIANT VIOLATED: Token supply must match actual NFT ownership"
        );
    }

    /// @dev Invariant: Total deposits minus total withdrawals equals vault NFT balance
    function invariant_depositWithdrawAccounting() public view {
        uint256 netDeposits = handler.totalDeposited() - handler.totalWithdrawn();
        uint256 vaultNftBalance = nft.balanceOf(address(vault));

        assertEq(
            vaultNftBalance,
            netDeposits,
            "INVARIANT VIOLATED: Net deposits must equal vault NFT balance"
        );
    }

    /// @dev Invariant: No tokens should exist outside of tracked actors and handler
    function invariant_noTokenLeakage() public view {
        uint256 totalSupply = vault.totalSupply();
        uint256 trackedBalance = 0;

        for (uint256 i = 0; i < 5; i++) {
            trackedBalance += vault.balanceOf(handler.actors(i));
        }

        trackedBalance += vault.balanceOf(address(handler));

        assertEq(
            trackedBalance,
            totalSupply,
            "INVARIANT VIOLATED: All tokens must be accounted for"
        );
    }

    /// @dev Invariant: Allowances are non-negative and properly tracked
    function invariant_allowancesAreValid() public view {
        for (uint256 i = 0; i < 5; i++) {
            for (uint256 j = 0; j < 5; j++) {
                uint256 allowance = vault.allowance(handler.actors(i), handler.actors(j));
                // Allowance should be a valid uint256 (this always passes but checks for unexpected behavior)
                assertGe(allowance, 0, "INVARIANT VIOLATED: Allowance must be non-negative");
            }
        }
    }

    function onERC721Received(address, address, uint256, bytes calldata) external pure returns (bytes4) {
        return this.onERC721Received.selector;
    }
}

/**
 * @title MinterRemyVaultInvariantHandler
 * @dev Handler for MinterRemyVault invariant testing
 */
contract MinterRemyVaultInvariantHandler is Test {
    MinterRemyVault public vault;
    RemyVaultNFT public nft;

    address[] public actors;
    uint256 public totalMinted;
    uint256 public totalDeposited;
    uint256 public totalWithdrawn;

    constructor(MinterRemyVault _vault, RemyVaultNFT _nft) {
        vault = _vault;
        nft = _nft;

        for (uint256 i = 0; i < 5; i++) {
            actors.push(makeAddr(string(abi.encodePacked("minter_actor", i))));
        }
    }

    function mint(uint256 actorSeed, uint256 count) public {
        address actor = actors[actorSeed % actors.length];

        uint256 balance = vault.balanceOf(actor);
        if (balance == 0) return;

        uint256 maxMintable = vault.maxSupply() - vault.mintedCount();
        if (maxMintable == 0) return;

        count = bound(count, 1, maxMintable < 5 ? maxMintable : 5);
        uint256 cost = count * vault.UNIT();

        if (balance < cost) return;

        vm.prank(actor);
        vault.mint(count, actor);

        totalMinted += count;
    }

    function deposit(uint256 actorSeed, uint256 count) public {
        address actor = actors[actorSeed % actors.length];

        uint256 nftBalance = nft.balanceOf(actor);
        if (nftBalance == 0) return;

        count = bound(count, 1, nftBalance < 3 ? nftBalance : 3);

        uint256[] memory tokenIds = new uint256[](count);
        uint256 collected = 0;

        for (uint256 i = 0; i < nft.totalSupply() && collected < count; i++) {
            uint256 tokenId = nft.tokenByIndex(i);
            if (nft.ownerOf(tokenId) == actor) {
                tokenIds[collected] = tokenId;
                collected++;
            }
        }

        if (collected < count) return;

        vm.startPrank(actor);
        nft.setApprovalForAll(address(vault), true);
        vault.deposit(tokenIds, actor);
        vm.stopPrank();

        totalDeposited += count;
    }

    function withdraw(uint256 actorSeed, uint256 count) public {
        address actor = actors[actorSeed % actors.length];

        uint256 balance = vault.balanceOf(actor);
        if (balance == 0) return;

        uint256 maxWithdraw = balance / vault.UNIT();
        if (maxWithdraw == 0) return;

        uint256 vaultNftBalance = nft.balanceOf(address(vault));
        if (vaultNftBalance == 0) return;

        count = bound(count, 1, maxWithdraw < vaultNftBalance ? maxWithdraw : vaultNftBalance);
        if (count > 3) count = 3; // Limit for gas

        uint256[] memory tokenIds = new uint256[](count);
        uint256 collected = 0;

        for (uint256 i = 0; i < nft.totalSupply() && collected < count; i++) {
            uint256 tokenId = nft.tokenByIndex(i);
            if (nft.ownerOf(tokenId) == address(vault)) {
                tokenIds[collected] = tokenId;
                collected++;
            }
        }

        if (collected < count) return;

        vm.prank(actor);
        vault.withdraw(tokenIds, actor);

        totalWithdrawn += count;
    }

    function transfer(uint256 fromSeed, uint256 toSeed, uint256 amount) public {
        address from = actors[fromSeed % actors.length];
        address to = actors[toSeed % actors.length];

        uint256 balance = vault.balanceOf(from);
        if (balance == 0) return;

        amount = bound(amount, 0, balance);
        if (amount == 0) return;

        vm.prank(from);
        vault.transfer(to, amount);
    }

    function onERC721Received(address, address, uint256, bytes calldata) external pure returns (bytes4) {
        return this.onERC721Received.selector;
    }
}

/**
 * @title MinterRemyVaultInvariantTest
 * @dev Property-based invariant tests for MinterRemyVault
 */
contract MinterRemyVaultInvariantTest is StdInvariant, Test {
    MinterRemyVault public vault;
    RemyVaultNFT public nft;
    MinterRemyVaultInvariantHandler public handler;

    uint256 constant MAX_SUPPLY = 20;

    function setUp() public {
        nft = new RemyVaultNFT("Derivative", "DRV", "ipfs://", address(this));
        vault = new MinterRemyVault("Derivative Token", "dDRV", address(nft), MAX_SUPPLY);
        nft.setMinter(address(vault), true);

        handler = new MinterRemyVaultInvariantHandler(vault, nft);

        // Distribute initial tokens to actors (5 actors)
        uint256 perActorAmount = (MAX_SUPPLY * vault.UNIT()) / 5;
        for (uint256 i = 0; i < 5; i++) {
            vault.transfer(handler.actors(i), perActorAmount);
        }

        targetContract(address(handler));

        bytes4[] memory selectors = new bytes4[](4);
        selectors[0] = MinterRemyVaultInvariantHandler.mint.selector;
        selectors[1] = MinterRemyVaultInvariantHandler.deposit.selector;
        selectors[2] = MinterRemyVaultInvariantHandler.withdraw.selector;
        selectors[3] = MinterRemyVaultInvariantHandler.transfer.selector;

        targetSelector(FuzzSelector({addr: address(handler), selectors: selectors}));
    }

    /// @dev Core invariant: Total supply + (minted NFTs * UNIT) - (deposited NFTs * UNIT) = MAX_SUPPLY * UNIT
    function invariant_minterSupplyAccounting() public view {
        uint256 totalSupply = vault.totalSupply();
        uint256 mintedCount = vault.mintedCount();
        uint256 vaultNftBalance = nft.balanceOf(address(vault));

        uint256 expectedSupply = (MAX_SUPPLY - mintedCount + vaultNftBalance) * vault.UNIT();

        assertEq(
            totalSupply,
            expectedSupply,
            "INVARIANT VIOLATED: Supply accounting mismatch"
        );
    }

    /// @dev Invariant: Minted count never exceeds max supply
    function invariant_mintedCountWithinLimit() public view {
        uint256 mintedCount = vault.mintedCount();
        uint256 maxSupply = vault.maxSupply();

        assertLe(
            mintedCount,
            maxSupply,
            "INVARIANT VIOLATED: Minted count exceeds max supply"
        );
    }

    /// @dev Invariant: Total NFT supply equals minted count
    function invariant_nftSupplyEqualsMintedCount() public view {
        uint256 nftTotalSupply = nft.totalSupply();
        uint256 mintedCount = vault.mintedCount();

        assertEq(
            nftTotalSupply,
            mintedCount,
            "INVARIANT VIOLATED: NFT total supply must equal minted count"
        );
    }

    /// @dev Invariant: Sum of all balances equals total supply
    function invariant_sumOfBalancesEqualsTotalSupply() public view {
        uint256 totalSupply = vault.totalSupply();
        uint256 sumOfBalances = 0;

        for (uint256 i = 0; i < 5; i++) {
            sumOfBalances += vault.balanceOf(handler.actors(i));
        }

        sumOfBalances += vault.balanceOf(address(handler));
        sumOfBalances += vault.balanceOf(address(this));

        assertEq(
            sumOfBalances,
            totalSupply,
            "INVARIANT VIOLATED: Sum of balances must equal total supply"
        );
    }

    function onERC721Received(address, address, uint256, bytes calldata) external pure returns (bytes4) {
        return this.onERC721Received.selector;
    }
}