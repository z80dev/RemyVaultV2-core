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

    CoreAddresses internal cachedCore;
    bool internal coreLoaded;

    function loadCoreAddresses() internal returns (CoreAddresses memory addresses_) {
        if (!coreLoaded) {
            string memory json = vm.readFile(AddressKeys.BASE);
            _storeCoreVaultAddresses(json);
            _storeTokenAddresses(json);
            _storeRouterAddresses(json);
            coreLoaded = true;
        }
        addresses_ = cachedCore;
    }

    function _storeCoreVaultAddresses(string memory json) internal {
        cachedCore.vault = json.readAddress(".vault");
        cachedCore.vaultFactory = json.readAddress(".vault_factory");
        cachedCore.erc4626 = json.readAddress(".erc4626");
        cachedCore.distributor = json.readAddress(".distributor");
        cachedCore.fwder = json.readAddress(".fwder");
        cachedCore.nft = json.readAddress(".nft");
    }

    function _storeTokenAddresses(string memory json) internal {
        cachedCore.token = json.readAddress(".token");
        cachedCore.dn404Token = json.readAddress(".dn404_token");
        cachedCore.derivNft = json.readAddress(".deriv_nft");
        cachedCore.uniV3Factory = json.readAddress(".uni_v3_factory");
        cachedCore.uniV3Pool = json.readAddress(".uni_v3_pool");
        cachedCore.quoter = json.readAddress(".quoter");
    }

    function _storeRouterAddresses(string memory json) internal {
        cachedCore.rescueRouter = json.readAddress(".rescue_router");
        cachedCore.weth = json.readAddress(".weth");
        cachedCore.swapRouter = json.readAddress(".swap_router");
        cachedCore.nonfungiblePositionManager = json.readAddress(".nonfungible_position_manager");
        cachedCore.remyswapRouter = json.readAddress(".remyswap_router");
        cachedCore.user = json.readAddress(".user");
        cachedCore.newRemy = json.readAddress(".newremy");
    }
}
