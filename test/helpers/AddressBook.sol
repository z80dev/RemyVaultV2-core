// SPDX-License-Identifier: MIT
pragma solidity >=0.8.7 <0.9.0;

import "forge-std/Test.sol";
import "forge-std/StdJson.sol";

library AddressKeys {
    string internal constant BASE = "addresses/base.json";
}

struct CoreAddresses {
    address vault;
    address vaultFactory;
    address erc4626;
    address distributor;
    address fwder;
    address nft;
    address token;
    address dn404Token;
    address derivNft;
    address uniV3Factory;
    address uniV3Pool;
    address quoter;
    address rescueRouter;
    address weth;
    address swapRouter;
    address nonfungiblePositionManager;
    address remyswapRouter;
    address user;
    address newRemy;
}

abstract contract AddressBook is Test {
    using stdJson for string;

    function loadCoreAddresses() internal view returns (CoreAddresses memory addresses_) {
        string memory json = vm.readFile(AddressKeys.BASE);
        addresses_.vault = json.readAddress(".vault");
        addresses_.vaultFactory = json.readAddress(".vault_factory");
        addresses_.erc4626 = json.readAddress(".erc4626");
        addresses_.distributor = json.readAddress(".distributor");
        addresses_.fwder = json.readAddress(".fwder");
        addresses_.nft = json.readAddress(".nft");
        addresses_.token = json.readAddress(".token");
        addresses_.dn404Token = json.readAddress(".dn404_token");
        addresses_.derivNft = json.readAddress(".deriv_nft");
        addresses_.uniV3Factory = json.readAddress(".uni_v3_factory");
        addresses_.uniV3Pool = json.readAddress(".uni_v3_pool");
        addresses_.quoter = json.readAddress(".quoter");
        addresses_.rescueRouter = json.readAddress(".rescue_router");
        addresses_.weth = json.readAddress(".weth");
        addresses_.swapRouter = json.readAddress(".swap_router");
        addresses_.nonfungiblePositionManager = json.readAddress(".nonfungible_position_manager");
        addresses_.remyswapRouter = json.readAddress(".remyswap_router");
        addresses_.user = json.readAddress(".user");
        addresses_.newRemy = json.readAddress(".newremy");
    }
}
