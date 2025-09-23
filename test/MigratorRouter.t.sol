// SPDX-License-Identifier: MIT

pragma solidity >=0.8.17;

import {Test} from "forge-std/Test.sol";

import {
    MockERC20DN404,
    MockERC721Simple,
    MockVaultV1,
    MockVaultV2,
    MockOldRouter
} from "./helpers/MockMigratorDependencies.sol";

interface IMigratorRouter {
    function convert_v1_tokens_to_v2(uint256 tokenAmount, address recipient) external returns (uint256);

    function quote_convert_v1_tokens_to_v2(uint256 numNfts) external view returns (uint256);

    function transfer_vault_ownership(address newOwner) external;

    function owner() external view returns (address);
}

contract MigratorRouterTest is Test {
    uint256 internal constant UNIT = 1e18;

    IMigratorRouter internal router;
    MockERC20DN404 internal tokenV1;
    MockERC20DN404 internal tokenV2;
    MockERC721Simple internal nft;
    MockVaultV1 internal vaultV1;
    MockVaultV2 internal vaultV2;

    address internal routerOwner;

    address internal constant USER_A = address(0xA11CE);
    address internal constant USER_B = address(0xB0B);

    function setUp() public {
        tokenV1 = new MockERC20DN404("REMY V1", "RV1");
        tokenV2 = new MockERC20DN404("REMY V2", "RV2");
        nft = new MockERC721Simple("MigratorNFT", "MNFT");

        vaultV1 = new MockVaultV1(tokenV1, nft);
        vaultV2 = new MockVaultV2(tokenV2, nft);

        tokenV1.setMinter(address(this), true);
        tokenV1.setMinter(address(vaultV1), true);
        tokenV2.setMinter(address(this), true);
        tokenV2.setMinter(address(vaultV2), true);

        MockOldRouter oldRouter = new MockOldRouter(address(vaultV1), address(0), address(0), address(0));
        address routerAddr = deployCode("MigratorRouter", abi.encode(address(oldRouter), address(vaultV2)));
        router = IMigratorRouter(routerAddr);
        routerOwner = router.owner();
    }

    function testRouterOwnerCanTransferVaultOwnership() public {
        vaultV1.transfer_owner(address(router));
        assertEq(vaultV1.owner(), address(router), "router should own vault");

        vm.prank(routerOwner);
        router.transfer_vault_ownership(USER_A);

        assertEq(vaultV1.owner(), USER_A, "vault ownership should transfer");
    }

    function testRouterNonOwnerCannotTransferVaultOwnership() public {
        vaultV1.transfer_owner(address(router));

        vm.startPrank(USER_A);
        vm.expectRevert();
        router.transfer_vault_ownership(USER_B);
        vm.stopPrank();

        assertEq(vaultV1.owner(), address(router), "vault should remain with router");
    }

    function testConvertV1TokensToV2ExactMint() public {
        uint256[] memory ids = _toArray(201);
        _seedVaultV1(ids);
        uint256[] memory expected = _snapshotVaultTokens(ids.length);

        uint256 required = router.quote_convert_v1_tokens_to_v2(ids.length);
        tokenV1.mint(USER_B, required);

        vm.prank(USER_B);
        tokenV1.approve(address(router), required);

        uint256 routerV2Before = tokenV2.balanceOf(address(router));

        vm.prank(USER_B);
        uint256 remainder = router.convert_v1_tokens_to_v2(required, USER_B);

        assertEq(remainder, 0, "conversion should have zero remainder");

        assertEq(tokenV1.balanceOf(USER_B), 0, "V1 tokens not burned");
        assertEq(tokenV2.balanceOf(USER_B), required, "V2 tokens not delivered");
        assertEq(tokenV2.balanceOf(address(router)), routerV2Before, "router balance should be unchanged");

        for (uint256 i = 0; i < expected.length; i++) {
            assertEq(nft.ownerOf(expected[i]), address(vaultV2), "NFT not restaked into Vault V2");
        }
    }

    function testQuoteConvertMatchesLegacyRedeemCost() public {
        uint256[] memory ids = _toArray(401, 402, 403);
        _seedVaultV1(ids);

        uint256 quote = router.quote_convert_v1_tokens_to_v2(ids.length);
        assertEq(quote, ids.length * UNIT, "quote should equal v1 redeem cost");
    }

    function testConvertV1TokensToV2UsesRouterBuffer() public {
        uint256[] memory ids = _toArray(301, 302);
        _seedVaultV1(ids);
        uint256[] memory expected = _snapshotVaultTokens(ids.length);

        // Simulate V2 minting deficiency (only 80% of expected amount)
        vaultV2.setMintMultiplier(0.8e18);

        uint256 required = router.quote_convert_v1_tokens_to_v2(ids.length);
        uint256 mintedFromDeposit = (ids.length * UNIT * 0.8e18) / 1e18;
        uint256 bufferNeeded = required - mintedFromDeposit;

        // Prefund router with the buffer it should spend during conversion
        tokenV2.mint(address(router), bufferNeeded);

        tokenV1.mint(USER_A, required);
        vm.prank(USER_A);
        tokenV1.approve(address(router), required);

        uint256 routerV2Before = tokenV2.balanceOf(address(router));

        vm.prank(USER_A);
        uint256 remainder = router.convert_v1_tokens_to_v2(required, USER_A);

        assertEq(remainder, 0, "buffer conversion should have zero remainder");

        uint256 routerV2After = tokenV2.balanceOf(address(router));

        assertEq(tokenV2.balanceOf(USER_A), required, "user should receive full V2 amount");
        assertEq(routerV2Before - routerV2After, bufferNeeded, "router should spend buffer");

        for (uint256 i = 0; i < expected.length; i++) {
            assertEq(nft.ownerOf(expected[i]), address(vaultV2), "NFT not deposited into Vault V2");
        }
    }

    function testConvertV1TokensToV2ReturnsRemainder() public {
        uint256[] memory ids = _toArray(777);
        _seedVaultV1(ids);
        uint256[] memory expected = _snapshotVaultTokens(ids.length);

        uint256 required = router.quote_convert_v1_tokens_to_v2(ids.length);
        uint256 extra = required / 2;
        uint256 amount = required + extra;

        tokenV1.mint(USER_A, amount);
        vm.prank(USER_A);
        tokenV1.approve(address(router), amount);

        vm.prank(USER_A);
        uint256 remainder = router.convert_v1_tokens_to_v2(amount, USER_A);

        assertEq(remainder, extra, "remainder should equal unused tokens");
        assertEq(tokenV1.balanceOf(USER_A), extra, "user should retain leftover tokens");
        assertEq(tokenV2.balanceOf(USER_A), required, "converted amount should pay out V2 tokens");

        for (uint256 i = 0; i < expected.length; i++) {
            assertEq(nft.ownerOf(expected[i]), address(vaultV2), "NFT not deposited into Vault V2");
        }
    }

    function _seedVaultV1(uint256[] memory tokenIds) internal {
        nft.setApprovalForAll(address(vaultV1), true);
        for (uint256 i = 0; i < tokenIds.length; i++) {
            nft.mint(address(this), tokenIds[i]);
        }
        vaultV1.set_active(true);
        vaultV1.mint_batch(tokenIds, address(this), false);
        vaultV1.set_active(false);
    }

    function _toArray(uint256 a) internal pure returns (uint256[] memory arr) {
        arr = new uint256[](1);
        arr[0] = a;
    }

    function _toArray(uint256 a, uint256 b) internal pure returns (uint256[] memory arr) {
        arr = new uint256[](2);
        arr[0] = a;
        arr[1] = b;
    }

    function _toArray(uint256 a, uint256 b, uint256 c) internal pure returns (uint256[] memory arr) {
        arr = new uint256[](3);
        arr[0] = a;
        arr[1] = b;
        arr[2] = c;
    }

    function _snapshotVaultTokens(uint256 count) internal view returns (uint256[] memory ids) {
        ids = new uint256[](count);
        for (uint256 i = 0; i < count; i++) {
            ids[i] = nft.tokenOfOwnerByIndex(address(vaultV1), i);
        }
    }
}
