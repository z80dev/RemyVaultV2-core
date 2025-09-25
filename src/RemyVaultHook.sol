// // SPDX-License-Identifier: MIT
// /*
// pragma solidity ^0.8.0;
// 
// import {IRemyVault} from "./interfaces/IRemyVault.sol";
// import {IERC721} from "./interfaces/IERC721.sol";
// import {IERC20Minimal} from "@uniswap/v4-core/src/interfaces/external/IERC20Minimal.sol";
// import {BaseHook} from "@uniswap/v4-periphery/src/utils/BaseHook.sol";
// import {Hooks} from "@uniswap/v4-core/src/libraries/Hooks.sol";
// import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
// import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
// import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
// import {BalanceDelta, BalanceDeltaLibrary} from "@uniswap/v4-core/src/types/BalanceDelta.sol";
// import {CurrencyLibrary, Currency} from "@uniswap/v4-core/src/types/Currency.sol";
// import {PoolId, PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
// import {BeforeSwapDelta, toBeforeSwapDelta} from "@uniswap/v4-core/src/types/BeforeSwapDelta.sol";
// import {SafeCast} from "@uniswap/v4-core/src/libraries/SafeCast.sol";
// 
// contract RemyVaultHook is BaseHook {
//     using CurrencyLibrary for Currency;
//     using PoolIdLibrary for PoolKey;
//     using BalanceDeltaLibrary for BalanceDelta;
//     using SafeCast for uint256;
//     using SafeCast for int256;
// 
//     // ============ Constants ============
// 
//     uint256 public constant FEE_DENOMINATOR = 10000;
// 
//     /// @notice Allowed pools for this hook
//     mapping(PoolId => bool) public validPools;
// 
//     // ============ Constructor ============
// 
//     /**
//      * @notice Constructs the RemyVaultHook
//      * @param _poolManager Uniswap V4 Pool Manager
//      * @param _remyVault Address of the RemyVault contract
//      * @param _feeRecipient Address to receive fees
//      * @param _buyFee Fee percentage for buying NFTs
//      */
//     constructor(IPoolManager _poolManager, address remyVaultFactory)
//         BaseHook(_poolManager)
//     {
//     }
// 
//     // ============ Hook Permissions ============
// 
//     /**
//      * @notice Returns the hook's permissions
//      * @return The hooks that this contract will implement
//      */
//     function getHookPermissions() public pure override returns (Hooks.Permissions memory) {
//         return Hooks.Permissions({
//             beforeInitialize: true,
//             afterInitialize: false,
//             beforeAddLiquidity: false,
//             afterAddLiquidity: false,
//             beforeRemoveLiquidity: false,
//             afterRemoveLiquidity: false,
//             beforeSwap: true,
//             afterSwap: true,
//             beforeDonate: false,
//             afterDonate: false,
//             beforeSwapReturnDelta: true,
//             afterSwapReturnDelta: true,
//             afterAddLiquidityReturnDelta: false,
//             afterRemoveLiquidityReturnDelta: false
//         });
//     }
// 
//     // ============ Hook Implementations ============
// 
//     /**
//      * @notice Validates pool initialization parameters
//      * @dev The sender parameter is not used in this implementation
//      * @param key The pool key
//      * @return The function selector if validation passes
//      */
//     function _beforeInitialize(address, PoolKey calldata key, uint160) internal override returns (bytes4) {
//         // Validate that one of the tokens is our vault token
//         bool isValidPool =
//             (key.currency0 == Currency.wrap(address(vaultToken)) || key.currency1 == Currency.wrap(address(vaultToken)));
// 
//         if (!isValidPool) revert InvalidPool();
// 
//         // Register this as a valid pool
//         validPools[key.toId()] = true;
// 
//         return IHooks(address(0)).beforeInitialize.selector;
//     }
// 
//     /**
//      * @notice Hook called before a swap occurs
//      * @dev Handles NFT buying/selling logic
//      * @dev The sender parameter is not used in this implementation
//      * @param key The pool key
//      * @param params The swap parameters
//      * @return selector The function selector
//      * @return swapDelta Token delta to apply for the swap
//      * @return lpFeeOverride Fee override (not used in this hook)
//      */
//     function _beforeSwap(address, PoolKey calldata key, IPoolManager.SwapParams calldata params, bytes calldata)
//         internal
//         view
//         override
//         returns (bytes4 selector, BeforeSwapDelta swapDelta, uint24 lpFeeOverride)
//     {
//         return (IHooks(address(0)).beforeSwap.selector, toBeforeSwapDelta(int128(0), int128(0)), 0);
//     }
// 
//     /**
//      * @notice Hook called after a swap occurs
//      * @dev Executes NFT buying/selling logic
//      * @dev The sender parameter is not used in this implementation
//      * @param key The pool key
//      * @param params The swap parameters
//      * @param delta Balance delta from the swap
//      * @return selector The function selector
//      * @return deltaAdjustment Optional adjustment to the balance delta
//      */
//     function _afterSwap(
//         address sender,
//         PoolKey calldata key,
//         IPoolManager.SwapParams calldata params,
//         BalanceDelta delta,
//         bytes calldata hookData
//     ) internal override returns (bytes4 selector, int128 deltaAdjustment) {
//     }
// 
// 
//     /**
//      * @notice Helper function to get tokens received from a delta
//      * @param delta The balance delta from a swap
//      * @return tokensReceived The amount of tokens received
//      */
//     function _getTokensReceived(BalanceDelta delta) internal pure returns (int256 tokensReceived) {
//         int128 amount0 = delta.amount0();
//         int128 amount1 = delta.amount1();
// 
//         if (amount0 > 0) {
//             tokensReceived = int256(amount0);
//         } else if (amount1 > 0) {
//             tokensReceived = int256(amount1);
//         }
//     }
// 
//     // ============ External Functions ============
//     /**
//      * @notice Required to receive ETH
//      */
// receive() external payable {}
// }
// */
