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
import {IManagedToken} from "../src/interfaces/IManagedToken.sol";

contract RemyVaultMigrationTest is BaseTest, AddressBook {
    uint256 internal constant TOKENS_PER_NFT = 1000 * 1e18;

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

    address internal routerOwner;
    uint256 internal firstVaultTokenId;

    function setUp() public {
        core = loadCoreAddresses();

        rescueRouter = IRescueRouter(core.rescueRouter);
        vaultV1 = IRemyVaultV1(rescueRouter.vault_address());
        remyV1Token = IERC20(rescueRouter.erc20_address());
        nft = IERC721(core.nft);
        enumerableNft = IERC721Enumerable(core.nft);

        routerOwner = rescueRouter.owner();

        // Deploy fresh V2 token + vault stack
        remyV2Token = IERC20(deployCode("ManagedToken", abi.encode("REMY", "REMY", address(this))));
        remyVaultV2 = IRemyVault(deployCode("RemyVault", abi.encode(address(remyV2Token), core.nft)));
        IManagedToken(address(remyV2Token)).transfer_ownership(address(remyVaultV2));

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

        // Prefund migrator with one unit of v2 tokens for leftover handling
        vm.startPrank(address(remyVaultV2));
        IManagedToken(address(remyV2Token)).mint(address(migrator), TOKENS_PER_NFT);
        vm.stopPrank();

        // Ensure router + migrator are fee exempt and that RescueRouterV2 owns the vault
        vm.startPrank(routerOwner);
        rescueRouter.transfer_vault_ownership(routerOwner);
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
        remyV1Token.transfer(user, TOKENS_PER_NFT);
        vm.stopPrank();

        vm.startPrank(user);
        remyV1Token.approve(address(migrator), TOKENS_PER_NFT);
        migrator.migrate();
        vm.stopPrank();

        // User should have zero legacy tokens and newly minted v2 tokens 1:1
        assertEq(remyV1Token.balanceOf(user), 0, "v1 tokens should be burned");
        assertEq(remyV2Token.balanceOf(user), TOKENS_PER_NFT, "v2 tokens should mint 1:1");

        // The NFT redeemed from v1 vault should now live inside v2 vault
        assertEq(nft.ownerOf(firstVaultTokenId), address(remyVaultV2), "NFT should migrate to v2 vault");

        // Migrator invariant is preserved (prefunded amount never changes)
        (uint256 v1Balance, uint256 v2Balance) = migrator.get_token_balances();
        assertEq(v1Balance + v2Balance, TOKENS_PER_NFT, "migrator token totals should remain constant");
    }
}
