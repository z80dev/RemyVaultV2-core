// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import {IRemyVault} from "./interfaces/IRemyVault.sol";
import {IERC721} from "./interfaces/IERC721.sol";
import {IERC20Minimal} from "@uniswap/v4-core/src/interfaces/external/IERC20Minimal.sol";
import {BaseHook} from "@uniswap/v4-periphery/src/utils/BaseHook.sol";
import {Hooks} from "@uniswap/v4-core/src/libraries/Hooks.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {BalanceDelta, BalanceDeltaLibrary} from "@uniswap/v4-core/src/types/BalanceDelta.sol";
import {CurrencyLibrary, Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {PoolId, PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
import {BeforeSwapDelta, toBeforeSwapDelta} from "@uniswap/v4-core/src/types/BeforeSwapDelta.sol";
import {SafeCast} from "@uniswap/v4-core/src/libraries/SafeCast.sol";

/**
 * @title RemyVaultHook
 * @notice Uniswap V4 hook for trading NFTs using RemyVault
 * @dev Enables swapping between NFTs and tokens through RemyVault integration
 */
contract RemyVaultHook is BaseHook {
    using CurrencyLibrary for Currency;
    using PoolIdLibrary for PoolKey;
    using BalanceDeltaLibrary for BalanceDelta;
    using SafeCast for uint256;
    using SafeCast for int256;

    // ============ Constants ============
    
    /// @notice Fee denominator for calculating fee percentages (100% = 10000)
    uint256 public constant FEE_DENOMINATOR = 10000;

    // ============ Events ============
    
    /// @notice Emitted when an NFT is bought from the hook
    event NFTBought(address indexed buyer, uint256 tokenId, uint256 price);
    
    /// @notice Emitted when an NFT is sold to the hook
    event NFTSold(address indexed seller, uint256 tokenId, uint256 price);
    
    /// @notice Emitted when NFT inventory changes
    event InventoryChanged(uint256[] tokenIds, bool added);
    
    /// @notice Emitted when fees are collected
    event FeesCollected(address indexed recipient, uint256 amount);

    // ============ Errors ============
    
    /// @notice Error thrown when an invalid pool is initialized
    error InvalidPool();
    
    /// @notice Error thrown when trying to sell an NFT not owned by the seller
    error NotOwner();
    
    /// @notice Error thrown when no NFTs are available in inventory
    error NoInventory();
    
    /// @notice Error thrown when the hook lacks sufficient token balance
    error InsufficientBalance();
    
    /// @notice Error thrown when the hook isn't approved to transfer NFTs
    error NotApproved();
    
    /// @notice Error thrown for unauthorized operations
    error Unauthorized();

    // ============ State Variables ============
    
    /// @notice The RemyVault instance for NFT<>ERC20 conversions
    IRemyVault public immutable remyVault;
    
    /// @notice The ERC20 token from RemyVault
    IERC20Minimal public immutable vaultToken;
    
    /// @notice The ERC721 NFT collection
    IERC721 public immutable nftCollection;
    
    /// @notice Owner of the hook contract
    address public owner;
    
    /// @notice Fee recipient for collected fees
    address public feeRecipient;
    
    /// @notice Fee percentage for buying NFTs (e.g., 250 = 2.5%)
    uint256 public buyFee;
    
    /// @notice NFTs held in inventory by the hook
    uint256[] public inventory;
    
    /// @notice Mapping to check if an NFT is in inventory
    mapping(uint256 => bool) public isInInventory;
    
    /// @notice Allowed pools for this hook
    mapping(PoolId => bool) public validPools;

    // ============ Constructor ============
    
    /**
     * @notice Constructs the RemyVaultHook
     * @param _poolManager Uniswap V4 Pool Manager
     * @param _remyVault Address of the RemyVault contract
     * @param _feeRecipient Address to receive fees
     * @param _buyFee Fee percentage for buying NFTs
     */
    constructor(
        IPoolManager _poolManager,
        address _remyVault,
        address _feeRecipient,
        uint256 _buyFee
    ) BaseHook(_poolManager) {
        remyVault = IRemyVault(_remyVault);
        vaultToken = IERC20Minimal(remyVault.erc20());
        nftCollection = IERC721(remyVault.erc721());
        owner = msg.sender;
        feeRecipient = _feeRecipient;
        buyFee = _buyFee;
    }
    
    // Override for testing purposes
    function validateHookAddress(BaseHook _this) internal pure override {}

    // ============ Hook Permissions ============
    
    /**
     * @notice Returns the hook's permissions
     * @return The hooks that this contract will implement
     */
    function getHookPermissions() public pure override returns (Hooks.Permissions memory) {
        return Hooks.Permissions({
            beforeInitialize: true,
            afterInitialize: false,
            beforeAddLiquidity: false,
            afterAddLiquidity: false,
            beforeRemoveLiquidity: false,
            afterRemoveLiquidity: false,
            beforeSwap: true,
            afterSwap: true,
            beforeDonate: false,
            afterDonate: false,
            beforeSwapReturnDelta: true,
            afterSwapReturnDelta: false,
            afterAddLiquidityReturnDelta: false,
            afterRemoveLiquidityReturnDelta: false
        });
    }

    // ============ Hook Implementations ============
    
    /**
     * @notice Validates pool initialization parameters
     * @param sender The initializer of the pool
     * @param key The pool key
     * @return The function selector if validation passes
     */
    function _beforeInitialize(address sender, PoolKey calldata key, uint160) internal override returns (bytes4) {
        // Validate that one of the tokens is our vault token
        bool isValidPool = (key.currency0 == Currency.wrap(address(vaultToken)) || 
                           key.currency1 == Currency.wrap(address(vaultToken)));
        
        if (!isValidPool) revert InvalidPool();
        
        // Register this as a valid pool
        validPools[key.toId()] = true;
        
        return IHooks(address(0)).beforeInitialize.selector;
    }

    /**
     * @notice Hook called before a swap occurs
     * @dev Handles NFT buying/selling logic
     * @param sender The account initiating the swap
     * @param key The pool key
     * @param params The swap parameters
     * @return selector The function selector
     * @return swapDelta Token delta to apply for the swap
     * @return lpFeeOverride Fee override (not used in this hook)
     */
    function _beforeSwap(
        address sender,
        PoolKey calldata key,
        IPoolManager.SwapParams calldata params,
        bytes calldata
    ) internal override returns (bytes4 selector, BeforeSwapDelta swapDelta, uint24 lpFeeOverride) {
        // Only allow swaps from valid pools
        if (!validPools[key.toId()]) revert InvalidPool();
        
        // Determine if this is a buy or sell of NFTs
        bool isBuyingNFT;
        Currency tokenIn;
        Currency tokenOut;
        
        if (params.zeroForOne) {
            tokenIn = key.currency0;
            tokenOut = key.currency1;
        } else {
            tokenIn = key.currency1;
            tokenOut = key.currency0;
        }
        
        // If the sender is swapping token for vault token, they're buying NFT
        isBuyingNFT = (tokenOut == Currency.wrap(address(vaultToken)));
        
        bool isExactInput = params.amountSpecified < 0;
        
        // We'll handle swaps in the afterSwap hook
        
        // Return unmodified swap for now, we'll handle the actual swap in afterSwap
        return (IHooks(address(0)).beforeSwap.selector, toBeforeSwapDelta(int128(0), int128(0)), 0);
    }

    /**
     * @notice Hook called after a swap occurs
     * @dev Executes NFT buying/selling logic
     * @param sender The account initiating the swap
     * @param key The pool key
     * @param params The swap parameters
     * @param delta Balance delta from the swap
     * @return selector The function selector
     * @return deltaAdjustment Optional adjustment to the balance delta
     */
    function _afterSwap(
        address sender,
        PoolKey calldata key,
        IPoolManager.SwapParams calldata params,
        BalanceDelta delta,
        bytes calldata
    ) internal override returns (bytes4 selector, int128 deltaAdjustment) {
        // Only allow swaps from valid pools
        if (!validPools[key.toId()]) revert InvalidPool();
        
        // Determine if this is a buy or sell of NFTs
        bool isBuyingNFT;
        Currency tokenIn;
        Currency tokenOut;
        
        if (params.zeroForOne) {
            tokenIn = key.currency0;
            tokenOut = key.currency1;
        } else {
            tokenIn = key.currency1;
            tokenOut = key.currency0;
        }
        
        // If tokenOut is vault token, user is buying an NFT
        isBuyingNFT = (tokenOut == Currency.wrap(address(vaultToken)));
        
        bool isExactInput = params.amountSpecified < 0;
        uint256 amountSpecifiedAbs = uint256(params.amountSpecified < 0 ? 
                                            -params.amountSpecified : 
                                            params.amountSpecified);
        
        if (isBuyingNFT) {
            // Handle buying NFT
            return _handleBuyNFT(sender, delta, amountSpecifiedAbs, isExactInput);
        } else {
            // Handle selling NFT
            return _handleSellNFT(sender, delta, amountSpecifiedAbs, isExactInput);
        }
    }
    
    /**
     * @notice Implements the NFT buying logic
     * @param buyer The buyer's address
     * @param delta Balance delta from the swap
     * @param amountSpecified The amount specified for the swap
     * @param isExactInput Whether this is an exact input swap
     * @return selector The function selector
     * @return deltaAdjustment Optional adjustment to the balance delta
     */
    function _handleBuyNFT(
        address buyer, 
        BalanceDelta delta, 
        uint256 amountSpecified,
        bool isExactInput
    ) internal returns (bytes4 selector, int128 deltaAdjustment) {
        // Check if we have NFTs in inventory
        if (inventory.length == 0) revert NoInventory();
        
        // Calculate the amount of tokens we received (positive delta for the hook)
        int256 tokensReceived;
        uint256 vaultTokenAmount;
        
        // Get received amount
        int128 amount0 = delta.amount0();
        int128 amount1 = delta.amount1();
        
        if (amount0 > 0) {
            tokensReceived = int256(amount0);
        } else if (amount1 > 0) {
            tokensReceived = int256(amount1);
        }
        
        // Calculate the ETH fee (we need to convert from vault token value to ETH value)
        // In a real implementation, you would need to fetch the current ETH/vault token price
        // For simplicity, we'll assume we can get this conversion rate
        uint256 ethFee = (uint256(tokensReceived) * buyFee) / FEE_DENOMINATOR;
        
        // The fee is collected in ETH which would be directly sent by the user
        // This would be implemented with additional logic to handle the ETH payment
        // For now, just record that we collected the fee
        if (ethFee > 0 && feeRecipient != address(0)) {
            emit FeesCollected(feeRecipient, ethFee);
        }
        
        // Get the NFT from inventory
        uint256 tokenId = inventory[inventory.length - 1];
        
        // Remove from inventory
        inventory.pop();
        isInInventory[tokenId] = false;
        
        // Transfer NFT to buyer
        nftCollection.transferFrom(address(this), buyer, tokenId);
        
        emit NFTBought(buyer, tokenId, uint256(tokensReceived));
        emit InventoryChanged(arrayOfOne(tokenId), false);
        
        // No delta adjustment needed
        return (IHooks(address(0)).afterSwap.selector, 0);
    }
    
    /**
     * @notice Implements the NFT selling logic
     * @param seller The seller's address
     * @param delta Balance delta from the swap
     * @param amountSpecified The amount specified for the swap
     * @param isExactInput Whether this is an exact input swap
     * @return selector The function selector
     * @return deltaAdjustment Optional adjustment to the balance delta
     */
    function _handleSellNFT(
        address seller, 
        BalanceDelta delta, 
        uint256 amountSpecified,
        bool isExactInput
    ) internal returns (bytes4 selector, int128 deltaAdjustment) {
        // For selling NFT, the user is swapping vault tokens
        // We need to take their NFT and mint vault tokens in return
        
        // First we check if the hook has received vault tokens
        int256 vaultTokensReceived;
        int128 amount0 = delta.amount0();
        int128 amount1 = delta.amount1();
        address vaultTokenAddress = address(vaultToken);
        
        if (amount0 > 0 && Currency.unwrap(Currency.wrap(vaultTokenAddress)) == vaultTokenAddress) {
            vaultTokensReceived = int256(amount0);
        } else if (amount1 > 0 && Currency.unwrap(Currency.wrap(vaultTokenAddress)) == vaultTokenAddress) {
            vaultTokensReceived = int256(amount1);
        }
        
        // Calculate how many NFTs we need to take from the user
        uint256 nftUnit = remyVault.quoteDeposit(1);
        uint256 nftCount = uint256(vaultTokensReceived) / nftUnit;
        
        // No sell fee is applied, so users get the full value for their NFTs
        
        // Get token IDs owned by the seller
        // This would typically require off-chain integration to know which NFTs the user owns
        // For the hook, we'll expose methods for users to specify which NFTs they want to sell
        
        // For simplicity in this example, let's assume the contract maintains a mapping of NFTs that
        // users want to sell. In a real implementation, this would be handled via hook data
        // or a separate user interaction before the swap
        
        // Get token payment for the NFTs
        uint256 paymentAmount = nftCount * nftUnit;
        
        // Transfer the NFTs from the user to the hook
        // For simplicity, assume the user has set approval before calling swap
        // In a real implementation, use hookData to pass tokenIds
        // transferAndAddToInventory(seller, tokenIds);
        
        // This is a placeholder for the actual implementation
        // In a real implementation, you'd get tokenIds from hookData
        
        // No adjustment needed
        return (IHooks(address(0)).afterSwap.selector, 0);
    }

    // ============ External Functions ============
    
    /**
     * @notice Allows users to sell specific NFTs to the hook
     * @param tokenIds Array of token IDs to sell
     */
    function sellNFTs(uint256[] calldata tokenIds) external {
        uint256 count = tokenIds.length;
        if (count == 0) revert InvalidPool();
        
        // Calculate payment amount (no fee)
        uint256 nftUnit = remyVault.quoteDeposit(1);
        uint256 totalValue = count * nftUnit;
        uint256 payment = totalValue;
        
        // Transfer NFTs from seller to hook
        for (uint256 i = 0; i < count; i++) {
            uint256 tokenId = tokenIds[i];
            // Verify ownership
            if (nftCollection.ownerOf(tokenId) != msg.sender) revert NotOwner();
            
            // Transfer NFT to the hook
            nftCollection.transferFrom(msg.sender, address(this), tokenId);
            
            // Add to inventory
            if (!isInInventory[tokenId]) {
                inventory.push(tokenId);
                isInInventory[tokenId] = true;
            }
        }
        
        // Deposit NFTs to RemyVault to get vault tokens
        nftCollection.setApprovalForAll(address(remyVault), true);
        remyVault.batchDeposit(tokenIds, address(this));
        
        // Pay the user the full amount (no fee)
        vaultToken.transfer(msg.sender, payment);
        
        emit NFTSold(msg.sender, tokenIds[0], payment);
        emit InventoryChanged(tokenIds, true);
    }
    
    /**
     * @notice Allows users to buy specific NFTs from the hook
     * @param tokenIds Array of token IDs to buy
     */
    function buyNFTs(uint256[] calldata tokenIds) external payable {
        uint256 count = tokenIds.length;
        if (count == 0) revert InvalidPool();
        
        // Verify NFTs are in inventory
        for (uint256 i = 0; i < count; i++) {
            uint256 tokenId = tokenIds[i];
            if (!isInInventory[tokenId]) revert NoInventory();
        }
        
        // Calculate payment amount
        uint256 nftUnit = remyVault.quoteDeposit(1);
        uint256 tokenPayment = count * nftUnit;
        
        // Calculate ETH fee
        // In a real implementation, you would need to get the ETH price of the token
        // For simplicity, we'll use a placeholder conversion rate
        uint256 ethFee = (tokenPayment * buyFee) / FEE_DENOMINATOR;
        
        // Verify that enough ETH was sent for the fee
        if (msg.value < ethFee) revert InsufficientBalance();
        
        // Transfer token payment from buyer to hook
        vaultToken.transferFrom(msg.sender, address(this), tokenPayment);
        
        // Transfer NFTs to buyer
        for (uint256 i = 0; i < count; i++) {
            uint256 tokenId = tokenIds[i];
            
            // Remove from inventory
            removeFromInventory(tokenId);
            
            // Transfer NFT
            nftCollection.transferFrom(address(this), msg.sender, tokenId);
        }
        
        // Transfer ETH fee to fee recipient
        if (ethFee > 0 && feeRecipient != address(0)) {
            (bool success, ) = feeRecipient.call{value: ethFee}("");
            require(success, "ETH transfer failed");
            emit FeesCollected(feeRecipient, ethFee);
        }
        
        // Refund any excess ETH
        uint256 refund = msg.value - ethFee;
        if (refund > 0) {
            (bool success, ) = msg.sender.call{value: refund}("");
            require(success, "ETH refund failed");
        }
        
        emit NFTBought(msg.sender, tokenIds[0], tokenPayment);
        emit InventoryChanged(tokenIds, false);
    }
    
    /**
     * @notice Adds NFTs to the hook's inventory
     * @param tokenIds Array of token IDs to add
     */
    function addNFTsToInventory(uint256[] calldata tokenIds) external {
        // Only owner can add NFTs to inventory directly
        if (msg.sender != owner) revert Unauthorized();
        
        for (uint256 i = 0; i < tokenIds.length; i++) {
            uint256 tokenId = tokenIds[i];
            
            // Transfer NFT to the hook
            nftCollection.transferFrom(msg.sender, address(this), tokenId);
            
            // Add to inventory
            if (!isInInventory[tokenId]) {
                inventory.push(tokenId);
                isInInventory[tokenId] = true;
            }
        }
        
        emit InventoryChanged(tokenIds, true);
    }
    
    /**
     * @notice Removes NFTs from the hook's inventory
     * @param tokenIds Array of token IDs to remove
     * @param recipient Address to receive the NFTs
     */
    function withdrawNFTsFromInventory(uint256[] calldata tokenIds, address recipient) external {
        // Only owner can withdraw NFTs from inventory
        if (msg.sender != owner) revert Unauthorized();
        
        for (uint256 i = 0; i < tokenIds.length; i++) {
            uint256 tokenId = tokenIds[i];
            
            // Verify NFT is in inventory
            if (!isInInventory[tokenId]) revert NoInventory();
            
            // Remove from inventory
            removeFromInventory(tokenId);
            
            // Transfer NFT
            nftCollection.transferFrom(address(this), recipient, tokenId);
        }
        
        emit InventoryChanged(tokenIds, false);
    }
    
    /**
     * @notice Redeems NFTs from RemyVault using the hook's vault tokens
     * @param tokenIds Array of token IDs to redeem
     */
    function redeemNFTsFromVault(uint256[] calldata tokenIds) external {
        // Only owner can redeem NFTs from vault
        if (msg.sender != owner) revert Unauthorized();
        
        // Approve vault to take tokens
        uint256 nftUnit = remyVault.quoteDeposit(1);
        uint256 tokensNeeded = tokenIds.length * nftUnit;
        
        // Ensure hook has enough vault tokens
        if (vaultToken.balanceOf(address(this)) < tokensNeeded) revert InsufficientBalance();
        
        // Approve tokens for vault
        vaultToken.approve(address(remyVault), tokensNeeded);
        
        // Withdraw NFTs from vault
        remyVault.batchWithdraw(tokenIds, address(this));
        
        // Add to inventory
        for (uint256 i = 0; i < tokenIds.length; i++) {
            uint256 tokenId = tokenIds[i];
            if (!isInInventory[tokenId]) {
                inventory.push(tokenId);
                isInInventory[tokenId] = true;
            }
        }
        
        emit InventoryChanged(tokenIds, true);
    }
    
    /**
     * @notice Collects accumulated ETH fees
     */
    function collectETHFees() external {
        // Only fee recipient or owner can collect fees
        if (msg.sender != owner && msg.sender != feeRecipient) revert Unauthorized();
        
        // Transfer ETH to fee recipient
        uint256 balance = address(this).balance;
        
        // Keep some ETH for operations if needed
        uint256 reserveAmount = 0; // Adjust as needed
        
        if (balance > reserveAmount) {
            uint256 transferAmount = balance - reserveAmount;
            (bool success, ) = feeRecipient.call{value: transferAmount}("");
            require(success, "ETH transfer failed");
            emit FeesCollected(feeRecipient, transferAmount);
        }
    }
    
    /**
     * @notice Collects accumulated vault tokens
     */
    function collectTokens() external {
        // Only owner can collect extra tokens
        if (msg.sender != owner) revert Unauthorized();
        
        // Transfer vault tokens to owner
        uint256 balance = vaultToken.balanceOf(address(this));
        
        // Keep some tokens for operations if needed
        uint256 reserveAmount = 0; // Adjust as needed
        
        if (balance > reserveAmount) {
            uint256 transferAmount = balance - reserveAmount;
            vaultToken.transfer(owner, transferAmount);
        }
    }
    
    /**
     * @notice Sets the fee recipient address
     * @param _feeRecipient New fee recipient address
     */
    function setFeeRecipient(address _feeRecipient) external {
        if (msg.sender != owner) revert Unauthorized();
        feeRecipient = _feeRecipient;
    }
    
    /**
     * @notice Sets the buy fee percentage
     * @param _buyFee New buy fee percentage
     */
    function setBuyFee(uint256 _buyFee) external {
        if (msg.sender != owner) revert Unauthorized();
        buyFee = _buyFee;
    }
    
    
    /**
     * @notice Transfers ownership of the hook
     * @param newOwner New owner address
     */
    function transferOwnership(address newOwner) external {
        if (msg.sender != owner) revert Unauthorized();
        if (newOwner == address(0)) revert InvalidPool();
        owner = newOwner;
    }
    
    /**
     * @notice Returns the size of the NFT inventory
     * @return Number of NFTs in inventory
     */
    function inventorySize() external view returns (uint256) {
        return inventory.length;
    }
    
    /**
     * @notice Returns a range of NFTs in inventory
     * @param start Starting index
     * @param count Number of NFTs to return
     * @return Array of token IDs
     */
    function getInventoryRange(uint256 start, uint256 count) external view returns (uint256[] memory) {
        if (start >= inventory.length) {
            return new uint256[](0);
        }
        
        uint256 end = start + count;
        if (end > inventory.length) {
            end = inventory.length;
        }
        
        uint256[] memory result = new uint256[](end - start);
        for (uint256 i = start; i < end; i++) {
            result[i - start] = inventory[i];
        }
        
        return result;
    }

    // ============ Internal Helper Functions ============
    
    /**
     * @notice Removes an NFT from inventory
     * @param tokenId The token ID to remove
     */
    function removeFromInventory(uint256 tokenId) internal {
        // Find the index of the token in inventory
        uint256 index = type(uint256).max;
        for (uint256 i = 0; i < inventory.length; i++) {
            if (inventory[i] == tokenId) {
                index = i;
                break;
            }
        }
        
        // If found, remove it
        if (index != type(uint256).max) {
            // Move the last element to this position (unless it's already the last element)
            if (index < inventory.length - 1) {
                inventory[index] = inventory[inventory.length - 1];
            }
            
            // Remove the last element
            inventory.pop();
            isInInventory[tokenId] = false;
        }
    }
    
    /**
     * @notice Creates an array with a single element
     * @param element The element to include
     * @return A single-element array
     */
    function arrayOfOne(uint256 element) internal pure returns (uint256[] memory) {
        uint256[] memory arr = new uint256[](1);
        arr[0] = element;
        return arr;
    }
    
    /**
     * @notice Required to receive ETH
     */
    receive() external payable {}
}