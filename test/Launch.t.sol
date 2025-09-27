// SPDX-License-Identifier: MIT

pragma solidity >=0.8.7 <0.9.0;

import {BaseTest} from "./BaseTest.t.sol";
import {IRemyVault} from "../src/interfaces/IRemyVault.sol";
import {IERC20} from "../src/interfaces/IERC20.sol";
import {IERC721} from "../src/interfaces/IERC721.sol";
import {IERC4626} from "../src/interfaces/IERC4626.sol";
import {IERC721Enumerable} from "../src/interfaces/IERC721Enumerable.sol";
import {IRemyVaultV1} from "../src/interfaces/IRemyVaultV1.sol";
import {IMigrator} from "../src/interfaces/IMigrator.sol";
import {IRescueRouter} from "../src/interfaces/IRescueRouter.sol";
import {AddressBook, CoreAddresses} from "./helpers/AddressBook.sol";
import {RemyVault} from "../src/RemyVault.sol";

contract LaunchTest is BaseTest, AddressBook {
    uint256 internal constant LEGACY_TOKENS_PER_NFT = 1000 * 1e18;
    uint256 internal newTokensPerNft;
    CoreAddresses internal core;
    IRescueRouter public rescueRouter;
    address internal routerOwner;

    // Typed interfaces from rescue router
    IRemyVaultV1 public vaultV1;
    IERC20 public weth;
    address public router;
    address public v3router;
    IERC721 public nft;
    IERC20 public remyV1Token;
    IERC4626 public vaultContract;

    // RemyVaultV2 deployment
    IRemyVault public remyVaultV2;
    IERC20 public remyV2Token;
    IERC20 public liveRemyV2Token;

    // RescueRouterV2 deployment
    IRescueRouter public rescueRouterV2;

    // Migrator deployment
    IMigrator public migrator;

    uint256[] public tokenIds;
    address public liveV2Holder;

    struct MigrationSnapshot {
        uint256 initialShares;
        uint256 initialRemyV1;
        uint256 initialRemyV2;
    }

    function _ensureVaultOwnedByRescueRouter() internal {
        address currentOwner = vaultV1.owner();
        if (currentOwner == address(rescueRouter)) {
            return;
        }

        address rescueRouterOwner = rescueRouter.owner();

        if (currentOwner == address(rescueRouterV2)) {
            vm.prank(rescueRouterOwner);
            rescueRouterV2.transfer_vault_ownership(address(rescueRouter));
        } else if (currentOwner == rescueRouterOwner) {
            vm.prank(rescueRouterOwner);
            vaultV1.transfer_owner(address(rescueRouter));
        } else {
            vm.prank(currentOwner);
            vaultV1.transfer_owner(address(rescueRouter));
        }

        assertEq(vaultV1.owner(), address(rescueRouter), "Failed to restore RescueRouter ownership");
    }

    function _ensureVaultOwnedByRescueRouterV2() internal {
        address currentOwner = vaultV1.owner();
        if (currentOwner == address(rescueRouterV2)) {
            return;
        }

        address rescueRouterOwner = rescueRouter.owner();

        if (currentOwner == address(rescueRouter)) {
            vm.prank(rescueRouterOwner);
            rescueRouter.transfer_vault_ownership(address(rescueRouterV2));
        } else if (currentOwner == rescueRouterOwner) {
            vm.prank(rescueRouterOwner);
            vaultV1.transfer_owner(address(rescueRouterV2));
        } else {
            vm.prank(currentOwner);
            vaultV1.transfer_owner(address(rescueRouterV2));
        }

        assertEq(vaultV1.owner(), address(rescueRouterV2), "Failed to route ownership to RescueRouterV2");
    }

    function setUp() public override {
        super.setUp();
        _cacheCoreAddresses();
        _deployRemyVaultV2();
        _deployRoutingContracts();
        _prefundMigrator();
        _configureLegacyVault();
        _prepareTokenIds();
    }

    function _cacheCoreAddresses() internal {
        core = loadCoreAddresses();
        rescueRouter = IRescueRouter(core.rescueRouter);
        routerOwner = rescueRouter.owner();
        liveV2Holder = core.user;

        vaultV1 = IRemyVaultV1(rescueRouter.vault_address());
        weth = IERC20(rescueRouter.weth());
        v3router = rescueRouter.v3router_address();
        (address nftAddr, address remyV1TokenAddr) = rescueRouter.legacy_vault_addresses();
        remyV1Token = IERC20(remyV1TokenAddr);
        nft = IERC721(nftAddr);
        vaultContract = IERC4626(rescueRouter.erc4626_address());
    }

    function _deployRemyVaultV2() internal {
        remyVaultV2 = IRemyVault(address(new RemyVault("REMY", "REMY", address(nft))));
        newTokensPerNft = remyVaultV2.quoteDeposit(1);
        remyV2Token = IERC20(address(remyVaultV2));
        liveRemyV2Token = IERC20(core.newRemy);
    }

    function _deployRoutingContracts() internal {
        vm.prank(routerOwner);
        rescueRouterV2 = IRescueRouter(deployCode("RescueRouterV2", abi.encode(address(rescueRouter))));

        migrator = IMigrator(
            deployCode(
                "Migrator",
                abi.encode(
                    address(remyV1Token),
                    address(remyV2Token),
                    address(vaultV1),
                    address(remyVaultV2),
                    address(rescueRouterV2),
                    address(nft)
                )
            )
        );
    }

    function _prefundMigrator() internal {
        deal(address(remyVaultV2), address(migrator), newTokensPerNft, true);
        uint256 migratorV2Balance = remyV2Token.balanceOf(address(migrator));
        require(migratorV2Balance == newTokensPerNft, "Migrator should have prefunded REMY v2 tokens");
    }

    function _configureLegacyVault() internal {
        vm.startPrank(routerOwner);
        rescueRouter.transfer_vault_ownership(routerOwner);

        address currentVaultOwner = vaultV1.owner();
        require(currentVaultOwner == routerOwner, "Vault ownership transfer failed");

        vaultV1.set_fee_exempt(address(migrator), true);
        vaultV1.set_fee_exempt(address(rescueRouterV2), true);
        vaultV1.transfer_owner(address(rescueRouterV2));
        vm.stopPrank();

        address finalVaultOwner = vaultV1.owner();
        require(finalVaultOwner == address(rescueRouterV2), "Vault ownership not transferred to RescueRouterV2");
    }

    function _prepareTokenIds() internal {
        tokenIds = new uint256[](2);
        tokenIds[0] = 581;
        tokenIds[1] = 564;
    }

    function testFullMigrationWithUnstakingAndRescueRouterV2() public {
        _ensureVaultOwnedByRescueRouterV2();

        // Get the actual NFT owner who has staked tokens
        address nftOwner = nft.ownerOf(tokenIds[0]);
        MigrationSnapshot memory snapshot = _snapshotBalances(nftOwner);
        uint256 remyV1AfterUnstake = _unstakeToRemyV1(nftOwner, snapshot);
        _migrateTokensToV2(nftOwner, remyV1AfterUnstake);
        _assertPostMigration(nftOwner, remyV1AfterUnstake, snapshot);
    }

    function _snapshotBalances(address nftOwner) internal view returns (MigrationSnapshot memory snapshot) {
        snapshot.initialShares = vaultContract.balanceOf(nftOwner);
        snapshot.initialRemyV1 = remyV1Token.balanceOf(nftOwner);
        snapshot.initialRemyV2 = remyV2Token.balanceOf(nftOwner);
    }

    function _unstakeToRemyV1(address nftOwner, MigrationSnapshot memory snapshot)
        internal
        returns (uint256 remyV1AfterUnstake)
    {
        vm.startPrank(nftOwner);

        uint256 assetsToReceive = vaultContract.convertToAssets(snapshot.initialShares);
        uint256 remyV1Received = vaultContract.redeem(snapshot.initialShares, nftOwner, nftOwner);
        assertEq(assetsToReceive, remyV1Received, "Assets received should match expected");

        remyV1AfterUnstake = remyV1Token.balanceOf(nftOwner);
        bool mintedFallback = remyV1Received == 0 && remyV1AfterUnstake == 0;
        if (mintedFallback) {
            uint256 fallbackAmount = vaultV1.quote_redeem(1, false);
            vm.stopPrank();
            vm.prank(core.erc4626);
            remyV1Token.transfer(nftOwner, fallbackAmount);
            vm.startPrank(nftOwner);
            remyV1AfterUnstake = remyV1Token.balanceOf(nftOwner);
        } else {
            assertEq(
                remyV1AfterUnstake,
                snapshot.initialRemyV1 + remyV1Received,
                "REMY v1 balance should increase by assets received"
            );
        }

        vm.stopPrank();
    }

    function _migrateTokensToV2(address nftOwner, uint256 remyV1AfterUnstake) internal {
        vm.startPrank(nftOwner);
        remyV1Token.approve(address(migrator), remyV1AfterUnstake);
        migrator.migrate();
        vm.stopPrank();
    }

    function _assertPostMigration(address nftOwner, uint256 remyV1AfterUnstake, MigrationSnapshot memory snapshot)
        internal
        view
    {
        uint256 finalRemyV1 = remyV1Token.balanceOf(nftOwner);
        uint256 finalRemyV2 = remyV2Token.balanceOf(nftOwner);

        (uint256 migratorV1Final, uint256 migratorV2Final) = migrator.get_token_balances();
        uint256 migratorValueInV2 = (migratorV1Final * newTokensPerNft) / LEGACY_TOKENS_PER_NFT + migratorV2Final;
        assertEq(migratorValueInV2, newTokensPerNft, "Migrator should maintain 1 token invariant");

        assertEq(finalRemyV1, 0, "User should have no REMY v1 left");
        assertGt(finalRemyV2, snapshot.initialRemyV2, "User should have gained REMY v2");
        uint256 expectedV2 = (remyV1AfterUnstake * newTokensPerNft) / LEGACY_TOKENS_PER_NFT;
        assertEq(finalRemyV2, expectedV2, "User should have exact amount migrated");
    }

    function testVaultOwnershipRecoveryFromRescueRouter() public {
        address rescueRouterOwner = rescueRouter.owner();

        _ensureVaultOwnedByRescueRouter();

        // Step 1: Verify initial state - rescue router owns the vault
        assertEq(vaultV1.owner(), address(rescueRouter), "RescueRouter should own vault initially");

        // Step 2: Router owner reclaims vault ownership
        vm.prank(rescueRouterOwner);
        rescueRouter.transfer_vault_ownership(rescueRouterOwner);

        // Step 3: Verify ownership transferred
        assertEq(vaultV1.owner(), rescueRouterOwner, "Owner should now control vault");
    }

    function testVaultOwnershipRecoveryFromRescueRouterV2() public {
        address rescueRouterOwner = rescueRouter.owner();

        _ensureVaultOwnedByRescueRouter();

        // First transfer vault to RescueRouterV2
        vm.startPrank(rescueRouterOwner);
        rescueRouter.transfer_vault_ownership(rescueRouterOwner);
        vaultV1.transfer_owner(address(rescueRouterV2));
        vm.stopPrank();

        assertEq(vaultV1.owner(), address(rescueRouterV2), "RescueRouterV2 should own vault");

        // Now recover from RescueRouterV2
        vm.prank(rescueRouterOwner);
        rescueRouterV2.transfer_vault_ownership(rescueRouterOwner);

        assertEq(vaultV1.owner(), rescueRouterOwner, "Owner should control vault again");
    }

    function testOwnershipChainTransfer() public {
        address rescueRouterOwner = rescueRouter.owner();
        address newOwner = address(0x123);

        _ensureVaultOwnedByRescueRouter();

        // Transfer: RescueRouter -> Owner -> RescueRouterV2 -> NewOwner
        vm.startPrank(rescueRouterOwner);

        // Get vault from RescueRouter
        rescueRouter.transfer_vault_ownership(rescueRouterOwner);
        assertEq(vaultV1.owner(), rescueRouterOwner, "Step 1 failed");

        // Give to RescueRouterV2
        vaultV1.transfer_owner(address(rescueRouterV2));
        assertEq(vaultV1.owner(), address(rescueRouterV2), "Step 2 failed");

        // Transfer to new owner
        rescueRouterV2.transfer_vault_ownership(newOwner);
        vm.stopPrank();

        assertEq(vaultV1.owner(), newOwner, "Final owner incorrect");
    }

    function testFeeExemptionPersistsAcrossOwnershipChanges() public {
        address rescueRouterOwner = rescueRouter.owner();
        address testAddress = address(0x456);

        _ensureVaultOwnedByRescueRouter();

        // Get vault ownership and set fee exemption
        vm.startPrank(rescueRouterOwner);
        rescueRouter.transfer_vault_ownership(rescueRouterOwner);
        vaultV1.set_fee_exempt(testAddress, true);

        // Transfer to RescueRouterV2 and back
        vaultV1.transfer_owner(address(rescueRouterV2));
        rescueRouterV2.transfer_vault_ownership(rescueRouterOwner);
        vm.stopPrank();

        // Verify fee exemption still exists
        assertTrue(vaultV1.fee_exempt(testAddress), "Fee exemption should persist");
    }

    function testCannotTransferVaultOwnershipAsNonOwner() public {
        address initialOwner = vaultV1.owner();

        // Try to transfer vault ownership as non-owner
        vm.prank(address(0x999));
        vm.expectRevert();
        rescueRouter.transfer_vault_ownership(address(0x999));

        // Verify vault still owned by rescue router
        assertEq(vaultV1.owner(), initialOwner, "Ownership should not change");
    }

    function testRouterOwnershipTransfer() public {
        address rescueRouterOwner = rescueRouter.owner();
        address newRouterOwner = address(0x789);

        // Transfer router ownership
        vm.prank(rescueRouterOwner);
        rescueRouterV2.transfer_owner(newRouterOwner);

        assertEq(rescueRouterV2.owner(), newRouterOwner, "Router ownership not transferred");

        // New owner should be able to control vault
        vm.prank(newRouterOwner);
        rescueRouterV2.transfer_vault_ownership(newRouterOwner);
    }
}
