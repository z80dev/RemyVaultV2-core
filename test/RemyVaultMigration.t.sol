// SPDX-License-Identifier: MIT

pragma solidity >=0.8.7 <0.9.0;

import {BaseTest} from "./BaseTest.t.sol";
import {AddressBook, CoreAddresses} from "./helpers/AddressBook.sol";
import {IRemyVaultV1} from "../src/interfaces/IRemyVaultV1.sol";
import {IMigrator} from "../src/interfaces/IMigrator.sol";
import {IRescueRouter} from "../src/interfaces/IRescueRouter.sol";
import {IRemyVault} from "../src/interfaces/IRemyVault.sol";
import {IERC20} from "../src/interfaces/IERC20.sol";
import {IERC721} from "../src/interfaces/IERC721.sol";
import {IERC721Enumerable} from "../src/interfaces/IERC721Enumerable.sol";
import {RemyVault} from "../src/RemyVault.sol";

interface IMigratorRouter {
    function convert_v1_tokens_to_v2(uint256 tokenAmount, address recipient) external returns (uint256);
    function transfer_vault_ownership(address newOwner) external;
}

contract RemyVaultMigrationTest is BaseTest, AddressBook {
    uint256 internal constant LEGACY_TOKENS_PER_NFT = 1000 * 1e18;
    uint256 internal newTokensPerNft;

    CoreAddresses internal core;

    IRescueRouter public rescueRouter;
    IRemyVaultV1 public vaultV1;
    IERC20 public remyV1Token;
    IERC721 public nft;
    IERC721Enumerable public enumerableNft;

    IRemyVault public remyVaultV2;
    IERC20 public remyV2Token;
    IRescueRouter public rescueRouterV2;
    IMigrator public migrator;
    IMigratorRouter public migratorRouter;

    address internal routerOwner;
    uint256 internal firstVaultTokenId;

    function setUp() public override {
        super.setUp();
        core = loadCoreAddresses();

        rescueRouter = IRescueRouter(core.rescueRouter);
        vaultV1 = IRemyVaultV1(rescueRouter.vault_address());
        (address nftAddr, address remyV1TokenAddr) = rescueRouter.legacy_vault_addresses();
        remyV1Token = IERC20(remyV1TokenAddr);
        nft = IERC721(nftAddr);
        enumerableNft = IERC721Enumerable(core.nft);

        routerOwner = rescueRouter.owner();

        // Deploy fresh V2 token + vault stack
        remyVaultV2 = IRemyVault(address(new RemyVault("REMY", "REMY", core.nft)));
        newTokensPerNft = remyVaultV2.quoteDeposit(1);
        remyV2Token = IERC20(address(remyVaultV2));

        // Deploy RescueRouterV2 governed by the current router owner
        vm.prank(routerOwner);
        rescueRouterV2 = IRescueRouter(deployCode("RescueRouterV2", abi.encode(address(rescueRouter))));

        // Deploy migrator bridging contract
        migrator = IMigrator(
            deployCode(
                "Migrator",
                abi.encode(
                    address(remyV1Token),
                    address(remyV2Token),
                    address(vaultV1),
                    address(remyVaultV2),
                    address(rescueRouterV2),
                    core.nft
                )
            )
        );

        migratorRouter =
            IMigratorRouter(deployCode("MigratorRouter", abi.encode(address(rescueRouter), address(remyVaultV2))));

        // Prefund migrator with one unit of v2 tokens for leftover handling
        deal(address(remyVaultV2), address(migrator), newTokensPerNft, true);

        // Ensure router + migrator are fee exempt and transfer vault control to RescueRouterV2
        address legacyVaultOwner = vaultV1.owner();
        vm.startPrank(legacyVaultOwner);
        vaultV1.set_fee_exempt(address(migrator), true);
        vaultV1.set_fee_exempt(address(rescueRouterV2), true);
        vaultV1.transfer_owner(address(rescueRouterV2));
        vm.stopPrank();

        // Record an NFT currently held by the legacy vault for validation later
        uint256 vaultBalance = nft.balanceOf(address(vaultV1));
        require(vaultBalance > 0, "legacy vault has no inventory");
        firstVaultTokenId = enumerableNft.tokenOfOwnerByIndex(address(vaultV1), 0);
    }

    function testMigratesRemyV1TokensOneToOne() public {
        address user = makeAddr("remyHolder");

        // Pull legacy tokens directly from the ERC4626 vault inventory for testing
        vm.startPrank(core.erc4626);
        remyV1Token.transfer(user, LEGACY_TOKENS_PER_NFT);
        vm.stopPrank();

        vm.startPrank(user);
        remyV1Token.approve(address(migrator), LEGACY_TOKENS_PER_NFT);
        migrator.migrate();
        vm.stopPrank();

        // User should have zero legacy tokens and newly minted v2 tokens 1:1
        assertEq(remyV1Token.balanceOf(user), 0, "v1 tokens should be burned");
        assertEq(remyV2Token.balanceOf(user), newTokensPerNft, "v2 tokens should mint 1:1");

        // The NFT redeemed from v1 vault should now live inside v2 vault
        assertEq(nft.ownerOf(firstVaultTokenId), address(remyVaultV2), "NFT should migrate to v2 vault");

        // Migrator invariant is preserved (prefunded amount never changes)
        (uint256 v1Balance, uint256 v2Balance) = migrator.get_token_balances();
        assertEq(v1Balance + v2Balance, newTokensPerNft, "migrator token totals should remain constant");
    }

    function testConvertLegacyTokensToV2ViaRouter() public {
        address user = makeAddr("legacyConverter");

        // Prepare V1 inventory and token allowance for the user
        vm.startPrank(core.erc4626);
        remyV1Token.transfer(user, LEGACY_TOKENS_PER_NFT);
        vm.stopPrank();

        uint256 convertId = enumerableNft.tokenOfOwnerByIndex(address(vaultV1), 0);

        vm.prank(routerOwner);
        rescueRouterV2.transfer_vault_ownership(address(migratorRouter));

        vm.startPrank(user);
        remyV1Token.approve(address(migratorRouter), LEGACY_TOKENS_PER_NFT);
        uint256 remainder = migratorRouter.convert_v1_tokens_to_v2(LEGACY_TOKENS_PER_NFT, user);
        assertEq(remainder, 0, "migration router should use full token amount");
        vm.stopPrank();

        assertEq(remyV1Token.balanceOf(user), 0, "V1 tokens should be burned during conversion");
        assertEq(remyV2Token.balanceOf(user), newTokensPerNft, "User should receive V2 tokens 1:1");
        assertEq(nft.ownerOf(convertId), address(remyVaultV2), "NFT should restake into V2 vault");
        assertEq(remyV2Token.balanceOf(address(migratorRouter)), 0, "Router should not retain V2 tokens");

        migratorRouter.transfer_vault_ownership(address(rescueRouterV2));
        assertEq(vaultV1.owner(), address(rescueRouterV2), "Vault ownership should revert to RescueRouterV2");
    }
}
