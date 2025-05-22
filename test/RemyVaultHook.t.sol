// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import "forge-std/Test.sol";
import "../src/RemyVaultHook.sol";
import {IRemyVault} from "../src/interfaces/IRemyVault.sol";
import {IERC721} from "../src/interfaces/IERC721.sol";
import {IERC20Minimal} from "@uniswap/v4-core/src/interfaces/external/IERC20Minimal.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {CurrencyLibrary, Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {PoolId, PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
import {BalanceDelta} from "@uniswap/v4-core/src/types/BalanceDelta.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {Hooks} from "@uniswap/v4-core/src/libraries/Hooks.sol";
import {BeforeSwapDelta, toBeforeSwapDelta} from "@uniswap/v4-core/src/types/BeforeSwapDelta.sol";
import {HookMiner} from "@uniswap/v4-periphery/src/utils/HookMiner.sol";

/**
 * @title MockPoolManager
 * @notice Mock contract for IPoolManager to test swap hooks
 */
// Partial implementation of IPoolManager for testing
contract MockPoolManager {
    function initialize(PoolKey calldata, uint160, bytes calldata) external pure returns (int24, int24, uint256) {
        return (0, 0, 0);
    }

    function initialize(PoolKey memory, uint160) external pure returns (int24) {
        return 0;
    }

    function swap(PoolKey memory, IPoolManager.SwapParams memory, bytes calldata) external pure returns (BalanceDelta) {
        return BalanceDelta.wrap(0);
    }

    function modifyLiquidity(PoolKey memory, IPoolManager.ModifyLiquidityParams memory, bytes calldata)
        external
        pure
        returns (BalanceDelta, BalanceDelta)
    {
        return (BalanceDelta.wrap(0), BalanceDelta.wrap(0));
    }

    function donate(PoolKey memory, uint256, uint256, bytes calldata) external pure returns (BalanceDelta) {
        return BalanceDelta.wrap(0);
    }

    function unlock(bytes calldata) external pure returns (bytes memory) {
        return "";
    }

    function take(Currency, address, uint256) external {}

    function settle() external payable returns (uint256) {
        return 0;
    }

    function settleFor(address) external payable returns (uint256) {
        return 0;
    }

    function sync(Currency) external {}
}

/**
 * @title RemyVaultHookTest
 * @notice Comprehensive test contract for RemyVaultHook
 */
contract RemyVaultHookTest is Test {
    using CurrencyLibrary for Currency;
    using PoolIdLibrary for PoolKey;

    // Test constants
    uint256 constant BUY_FEE = 250; // 2.5%
    uint256 constant NFT_UNIT = 1000 * 10 ** 18; // Amount of tokens per NFT

    // Mock contracts
    MockPoolManager mockPoolManager;
    address mockRemyVault;
    address mockVaultToken;
    address mockNFTCollection;
    address mockOtherToken;

    // Hook instance
    RemyVaultHook hook;

    // Test accounts
    address owner;
    address user;
    address feeRecipient;

    // Pool data for testing
    PoolKey poolKey;
    PoolId poolId;

    // Events to test
    event NFTBought(address indexed buyer, uint256 tokenId, uint256 price);
    event NFTSold(address indexed seller, uint256 tokenId, uint256 price);
    event InventoryChanged(uint256[] tokenIds, bool added);
    event FeesCollected(address indexed recipient, uint256 amount);

    /**
     * @notice Set up test environment before each test
     */
    function setUp() public {
        // Create test accounts
        owner = makeAddr("owner");
        user = makeAddr("user");
        feeRecipient = makeAddr("feeRecipient");

        // Deploy mock contracts
        mockPoolManager = new MockPoolManager();
        mockRemyVault = makeAddr("remyVault");
        mockVaultToken = makeAddr("vaultToken");
        mockNFTCollection = makeAddr("nftCollection");
        mockOtherToken = makeAddr("otherToken");

        // Mock RemyVault interface calls
        vm.mockCall(mockRemyVault, abi.encodeWithSelector(IRemyVault.erc20.selector), abi.encode(mockVaultToken));

        vm.mockCall(mockRemyVault, abi.encodeWithSelector(IRemyVault.erc721.selector), abi.encode(mockNFTCollection));

        vm.mockCall(mockRemyVault, abi.encodeWithSelector(IRemyVault.quoteDeposit.selector, 1), abi.encode(NFT_UNIT));

        // For simplicity, we'll deploy the hook without address validation
        vm.startPrank(owner);
        hook = new RemyVaultHook(IPoolManager(address(mockPoolManager)), mockRemyVault, feeRecipient, BUY_FEE);
        vm.stopPrank();

        // Setup pool key for testing
        Currency currency0 = Currency.wrap(mockVaultToken);
        Currency currency1 = Currency.wrap(mockOtherToken);

        poolKey = PoolKey({
            currency0: currency0,
            currency1: currency1,
            fee: 3000, // 0.3%
            tickSpacing: 60,
            hooks: IHooks(address(hook))
        });

        poolId = poolKey.toId();

        // Initialize the pool
        vm.prank(address(mockPoolManager));
        hook.beforeInitialize(address(0), poolKey, 0);
    }

    /**
     * @notice Test basic constructor and initialization
     */
    function testInitialization() public view {
        assertEq(address(hook.remyVault()), mockRemyVault);
        assertEq(address(hook.vaultToken()), mockVaultToken);
        assertEq(address(hook.nftCollection()), mockNFTCollection);
        assertEq(hook.owner(), owner);
        assertEq(hook.feeRecipient(), feeRecipient);
        assertEq(hook.buyFee(), BUY_FEE);

        // Verify pool was validated
        assertTrue(hook.validPools(poolId));
    }

    /**
     * @notice Test adding NFTs to inventory
     */
    function testAddNFTsToInventory() public {
        uint256[] memory tokenIds = new uint256[](2);
        tokenIds[0] = 1;
        tokenIds[1] = 2;

        // Mock NFT transfer
        vm.mockCall(
            mockNFTCollection,
            abi.encodeWithSelector(IERC721.transferFrom.selector, owner, address(hook), tokenIds[0]),
            abi.encode()
        );

        vm.mockCall(
            mockNFTCollection,
            abi.encodeWithSelector(IERC721.transferFrom.selector, owner, address(hook), tokenIds[1]),
            abi.encode()
        );

        // Expect event to be emitted
        vm.expectEmit(true, true, true, true);
        emit InventoryChanged(tokenIds, true);

        // Add NFTs to inventory
        vm.prank(owner);
        hook.addNFTsToInventory(tokenIds);

        // Check inventory
        assertEq(hook.inventorySize(), 2);
        assertTrue(hook.isInInventory(1));
        assertTrue(hook.isInInventory(2));
    }

    /**
     * @notice Test removing NFTs from inventory
     */
    function testWithdrawNFTsFromInventory() public {
        // First add NFTs to inventory
        uint256[] memory tokenIds = new uint256[](2);
        tokenIds[0] = 1;
        tokenIds[1] = 2;

        // Mock NFT transfers for adding
        vm.mockCall(
            mockNFTCollection,
            abi.encodeWithSelector(IERC721.transferFrom.selector, owner, address(hook), tokenIds[0]),
            abi.encode()
        );

        vm.mockCall(
            mockNFTCollection,
            abi.encodeWithSelector(IERC721.transferFrom.selector, owner, address(hook), tokenIds[1]),
            abi.encode()
        );

        vm.prank(owner);
        hook.addNFTsToInventory(tokenIds);

        // Now withdraw them
        // Mock NFT transfers for withdrawing
        vm.mockCall(
            mockNFTCollection,
            abi.encodeWithSelector(IERC721.transferFrom.selector, address(hook), owner, tokenIds[0]),
            abi.encode()
        );

        vm.mockCall(
            mockNFTCollection,
            abi.encodeWithSelector(IERC721.transferFrom.selector, address(hook), owner, tokenIds[1]),
            abi.encode()
        );

        // Expect event to be emitted
        vm.expectEmit(true, true, true, true);
        emit InventoryChanged(tokenIds, false);

        // Withdraw NFTs
        vm.prank(owner);
        hook.withdrawNFTsFromInventory(tokenIds, owner);

        // Check inventory
        assertEq(hook.inventorySize(), 0);
        assertFalse(hook.isInInventory(1));
        assertFalse(hook.isInInventory(2));
    }

    /**
     * @notice Test setting buy fee
     */
    function testSetBuyFee() public {
        uint256 newBuyFee = 300;

        vm.prank(owner);
        hook.setBuyFee(newBuyFee);

        assertEq(hook.buyFee(), newBuyFee);
    }

    /**
     * @notice Test transferring ownership
     */
    function testTransferOwnership() public {
        address newOwner = makeAddr("newOwner");

        vm.prank(owner);
        hook.transferOwnership(newOwner);

        assertEq(hook.owner(), newOwner);
    }

    /**
     * @notice Test unauthorized access
     */
    function testUnauthorizedAccess() public {
        vm.startPrank(user);

        // Try to set fee as non-owner
        vm.expectRevert(RemyVaultHook.Unauthorized.selector);
        hook.setBuyFee(300);

        // Try to transfer ownership as non-owner
        vm.expectRevert(RemyVaultHook.Unauthorized.selector);
        hook.transferOwnership(user);

        // Try to add NFTs to inventory as non-owner
        uint256[] memory tokenIds = new uint256[](1);
        tokenIds[0] = 1;
        vm.expectRevert(RemyVaultHook.Unauthorized.selector);
        hook.addNFTsToInventory(tokenIds);

        // Try to withdraw NFTs as non-owner
        vm.expectRevert(RemyVaultHook.Unauthorized.selector);
        hook.withdrawNFTsFromInventory(tokenIds, user);

        // Try to redeem NFTs from vault as non-owner
        vm.expectRevert(RemyVaultHook.Unauthorized.selector);
        hook.redeemNFTsFromVault(tokenIds);

        vm.stopPrank();
    }

    /**
     * @notice Test collecting ETH fees
     */
    function testCollectETHFees() public {
        // Set up ETH balance
        uint256 balance = 1 ether;
        vm.deal(address(hook), balance);

        // Expect event to be emitted
        vm.expectEmit(true, true, true, true);
        emit FeesCollected(feeRecipient, balance);

        // Collect fees
        vm.prank(feeRecipient);
        hook.collectETHFees();

        // Check balances
        assertEq(address(hook).balance, 0);
        assertEq(feeRecipient.balance, balance);
    }

    /**
     * @notice Test collecting tokens
     */
    function testCollectTokens() public {
        // Mock token balance
        uint256 balance = 1000;
        vm.mockCall(
            mockVaultToken, abi.encodeWithSelector(IERC20Minimal.balanceOf.selector, address(hook)), abi.encode(balance)
        );

        // Mock transfer
        vm.mockCall(
            mockVaultToken, abi.encodeWithSelector(IERC20Minimal.transfer.selector, owner, balance), abi.encode(true)
        );

        // Collect tokens
        vm.prank(owner);
        hook.collectTokens();
    }

    /**
     * @notice Test pool initialization validation
     */
    function testBeforeInitialize() public {
        // Valid pool with vault token as currency0
        Currency currency0 = Currency.wrap(mockVaultToken);
        Currency currency1 = Currency.wrap(mockOtherToken);

        PoolKey memory validKey = PoolKey({
            currency0: currency0,
            currency1: currency1,
            fee: 3000,
            tickSpacing: 60,
            hooks: IHooks(address(hook))
        });

        // Should succeed with valid pool
        vm.prank(address(mockPoolManager));
        bytes4 selector = hook.beforeInitialize(address(0), validKey, 0);
        assertEq(selector, IHooks(address(0)).beforeInitialize.selector);

        // Invalid pool without vault token
        Currency invalidCurrency0 = Currency.wrap(address(0xabc));
        Currency invalidCurrency1 = Currency.wrap(address(0xdef));

        PoolKey memory invalidKey = PoolKey({
            currency0: invalidCurrency0,
            currency1: invalidCurrency1,
            fee: 3000,
            tickSpacing: 60,
            hooks: IHooks(address(hook))
        });

        // Should revert with invalid pool
        vm.prank(address(mockPoolManager));
        vm.expectRevert(RemyVaultHook.InvalidPool.selector);
        hook.beforeInitialize(address(0), invalidKey, 0);
    }

    /**
     * @notice Test swap hooks for buying NFTs
     */
    function testBuyNFTViaSwapHooks() public {
        // Add NFT to inventory first
        uint256[] memory tokenIds = new uint256[](1);
        tokenIds[0] = 1;

        // Mock NFT transfer for adding to inventory
        vm.mockCall(
            mockNFTCollection,
            abi.encodeWithSelector(IERC721.transferFrom.selector, owner, address(hook), tokenIds[0]),
            abi.encode()
        );

        vm.prank(owner);
        hook.addNFTsToInventory(tokenIds);

        // Setup swap params to buy NFT (token → vault token)
        IPoolManager.SwapParams memory swapParams = IPoolManager.SwapParams({
            zeroForOne: false, // Buying vault token (currency1 → currency0)
            amountSpecified: -100 * 10 ** 18, // Exact input of 100 tokens
            sqrtPriceLimitX96: 0 // No price limit
        });

        // Create balance delta for the swap (positive amount0 means hook receives tokens)
        // This would normally come from the pool manager during the swap
        // Make sure the hook receives enough tokens to cover an NFT (which is NFT_UNIT)
        int128 amount0Delta = int128(int256(NFT_UNIT)); // Hook receives exactly enough tokens for an NFT
        int128 amount1Delta = -100 * 10 ** 18; // User receives 100 tokens
        BalanceDelta swapDelta =
            BalanceDelta.wrap(int256((uint256(uint128(amount0Delta)) << 128) | uint128(amount1Delta)));

        // Mock NFT transfer to user during swap
        vm.mockCall(
            mockNFTCollection,
            abi.encodeWithSelector(IERC721.transferFrom.selector, address(hook), user, 1),
            abi.encode()
        );

        // Expect NFT bought event
        vm.expectEmit(true, true, true, true);
        emit NFTBought(user, 1, NFT_UNIT);

        // Expect inventory changed event
        vm.expectEmit(true, true, true, true);
        emit InventoryChanged(tokenIds, false);

        // Encode hookData with 'true' to indicate NFT purchase is desired
        bytes memory hookData = abi.encode(true);

        // Call the hook directly as if pool manager called it
        vm.prank(address(mockPoolManager));
        (bytes4 selector,) = hook.afterSwap(user, poolKey, swapParams, swapDelta, hookData);

        // Check the return value
        assertEq(selector, IHooks(address(0)).afterSwap.selector);

        // Verify inventory was updated
        assertEq(hook.inventorySize(), 0);
        assertFalse(hook.isInInventory(1));
    }

    /**
     * @notice Test direct NFT buying
     */
    function testBuyNFTsDirect() public {
        // Add NFT to inventory first
        uint256[] memory tokenIds = new uint256[](1);
        tokenIds[0] = 1;

        // Mock NFT transfer for adding to inventory
        vm.mockCall(
            mockNFTCollection,
            abi.encodeWithSelector(IERC721.transferFrom.selector, owner, address(hook), tokenIds[0]),
            abi.encode()
        );

        vm.prank(owner);
        hook.addNFTsToInventory(tokenIds);

        // Calculate ETH fee
        uint256 tokenPrice = NFT_UNIT;
        uint256 ethFee = (tokenPrice * BUY_FEE) / hook.FEE_DENOMINATOR();

        // Mock token transfer from user to hook
        vm.mockCall(
            mockVaultToken,
            abi.encodeWithSelector(IERC20Minimal.transferFrom.selector, user, address(hook), tokenPrice),
            abi.encode(true)
        );

        // Mock NFT transfer to user
        vm.mockCall(
            mockNFTCollection,
            abi.encodeWithSelector(IERC721.transferFrom.selector, address(hook), user, 1),
            abi.encode()
        );

        // Mock successful ETH transfers in the hook
        vm.mockCall(feeRecipient, abi.encodeWithSignature("call()"), abi.encode(true));

        vm.mockCall(user, abi.encodeWithSignature("call()"), abi.encode(true));

        // Expect events in correct order matching the implementation
        vm.expectEmit(true, true, true, true);
        emit FeesCollected(feeRecipient, ethFee);

        vm.expectEmit(true, true, true, true);
        emit NFTBought(user, 1, tokenPrice);

        vm.expectEmit(true, true, true, true);
        emit InventoryChanged(tokenIds, false);

        // Give the user some ETH and call buyNFTs
        vm.deal(user, ethFee);
        vm.prank(user);
        hook.buyNFTs{value: ethFee}(tokenIds);

        // Verify inventory was updated
        assertEq(hook.inventorySize(), 0);
        assertFalse(hook.isInInventory(1));
    }

    /**
     * @notice Test direct NFT selling
     */
    function testSellNFTsDirect() public {
        uint256[] memory tokenIds = new uint256[](1);
        tokenIds[0] = 1;

        // Mock NFT ownership check
        vm.mockCall(mockNFTCollection, abi.encodeWithSelector(IERC721.ownerOf.selector, 1), abi.encode(user));

        // Mock NFT transfer from user to hook
        vm.mockCall(
            mockNFTCollection,
            abi.encodeWithSelector(IERC721.transferFrom.selector, user, address(hook), 1),
            abi.encode()
        );

        // Mock approval to RemyVault
        vm.mockCall(
            mockNFTCollection,
            abi.encodeWithSelector(IERC721.setApprovalForAll.selector, mockRemyVault, true),
            abi.encode()
        );

        // Mock RemyVault deposit
        vm.mockCall(
            mockRemyVault,
            abi.encodeWithSelector(IRemyVault.deposit.selector, tokenIds, address(hook)),
            abi.encode(NFT_UNIT)
        );

        // Mock token transfer to user
        vm.mockCall(
            mockVaultToken, abi.encodeWithSelector(IERC20Minimal.transfer.selector, user, NFT_UNIT), abi.encode(true)
        );

        // Expect events
        vm.expectEmit(true, true, true, true);
        emit NFTSold(user, 1, NFT_UNIT);

        vm.expectEmit(true, true, true, true);
        emit InventoryChanged(tokenIds, true);

        // Call sellNFTs
        vm.prank(user);
        hook.sellNFTs(tokenIds);

        // Verify inventory was updated
        assertEq(hook.inventorySize(), 1);
        assertTrue(hook.isInInventory(1));
    }

    /**
     * @notice Test NFT selling via swap
     */
    function testSellNFTViaSwapHooks() public {
        uint256[] memory tokenIds = new uint256[](1);
        tokenIds[0] = 1;

        // Mock NFT ownership check
        vm.mockCall(mockNFTCollection, abi.encodeWithSelector(IERC721.ownerOf.selector, 1), abi.encode(user));

        // Setup swap params for sell NFT (vault token → other token)
        IPoolManager.SwapParams memory swapParams = IPoolManager.SwapParams({
            zeroForOne: true, // Selling vault token (currency0 → currency1)
            amountSpecified: -int256(NFT_UNIT), // Exact input of NFT_UNIT tokens
            sqrtPriceLimitX96: 0 // No price limit
        });

        // Create balance delta for the swap
        // Amount0 is negative (hook gives vault tokens to user)
        // Amount1 is positive (hook receives other tokens)
        int128 amount0Delta = -int128(int256(NFT_UNIT));
        int128 amount1Delta = int128(int256(100 * 10 ** 18));
        BalanceDelta swapDelta =
            BalanceDelta.wrap(int256((uint256(uint128(amount0Delta)) << 128) | uint128(amount1Delta)));

        // Mock NFT transfer from user to hook during swap
        vm.mockCall(
            mockNFTCollection,
            abi.encodeWithSelector(IERC721.transferFrom.selector, user, address(hook), 1),
            abi.encode()
        );

        // Mock approval to RemyVault
        vm.mockCall(
            mockNFTCollection,
            abi.encodeWithSelector(IERC721.setApprovalForAll.selector, mockRemyVault, true),
            abi.encode()
        );

        // Mock RemyVault deposit
        vm.mockCall(
            mockRemyVault,
            abi.encodeWithSelector(IRemyVault.deposit.selector, tokenIds, address(hook)),
            abi.encode(NFT_UNIT)
        );

        // Expect events
        vm.expectEmit(true, true, true, true);
        emit NFTSold(user, 1, NFT_UNIT);

        vm.expectEmit(true, true, true, true);
        emit InventoryChanged(tokenIds, true);

        // Encode token IDs in hook data
        bytes memory hookData = abi.encode(tokenIds);

        // Call the hook directly as if pool manager called it
        vm.prank(address(mockPoolManager));
        (bytes4 selector,) = hook.afterSwap(user, poolKey, swapParams, swapDelta, hookData);

        // Check the return value
        assertEq(selector, IHooks(address(0)).afterSwap.selector);

        // Verify inventory was updated
        assertEq(hook.inventorySize(), 1);
        assertTrue(hook.isInInventory(1));
    }

    /**
     * @notice Test redeeming NFTs from vault
     */
    function testRedeemNFTsFromVault() public {
        uint256[] memory tokenIds = new uint256[](1);
        tokenIds[0] = 1;

        uint256 tokensNeeded = NFT_UNIT;

        // Mock token balance check
        vm.mockCall(
            mockVaultToken,
            abi.encodeWithSelector(IERC20Minimal.balanceOf.selector, address(hook)),
            abi.encode(tokensNeeded)
        );

        // Mock token approval
        vm.mockCall(
            mockVaultToken,
            abi.encodeWithSelector(IERC20Minimal.approve.selector, mockRemyVault, tokensNeeded),
            abi.encode(true)
        );

        // Mock RemyVault withdraw
        vm.mockCall(
            mockRemyVault,
            abi.encodeWithSelector(IRemyVault.withdraw.selector, tokenIds, address(hook)),
            abi.encode(tokensNeeded)
        );

        // Expect inventory changed event
        vm.expectEmit(true, true, true, true);
        emit InventoryChanged(tokenIds, true);

        // Call redeemNFTsFromVault
        vm.prank(owner);
        hook.redeemNFTsFromVault(tokenIds);

        // Verify inventory was updated
        assertEq(hook.inventorySize(), 1);
        assertTrue(hook.isInInventory(1));
    }

    /**
     * @notice Test inventory management functions
     */
    function testInventoryFunctions() public {
        // Add 5 NFTs to inventory
        uint256[] memory tokenIds = new uint256[](5);
        for (uint256 i = 0; i < 5; i++) {
            tokenIds[i] = i + 1;

            // Mock NFT transfer
            vm.mockCall(
                mockNFTCollection,
                abi.encodeWithSelector(IERC721.transferFrom.selector, owner, address(hook), i + 1),
                abi.encode()
            );
        }

        vm.prank(owner);
        hook.addNFTsToInventory(tokenIds);

        // Test inventorySize
        assertEq(hook.inventorySize(), 5);

        // Test getInventoryRange
        uint256[] memory range = hook.getInventoryRange(1, 2);
        assertEq(range.length, 2);
        assertEq(range[0], 2);
        assertEq(range[1], 3);

        // Test getInventoryRange with overflow
        range = hook.getInventoryRange(3, 10);
        assertEq(range.length, 2);
        assertEq(range[0], 4);
        assertEq(range[1], 5);

        // Test getInventoryRange with out of bounds
        range = hook.getInventoryRange(5, 1);
        assertEq(range.length, 0);
    }

    /**
     * @notice Test error cases and edge conditions
     */
    function testErrorCases() public {
        // Split test cases into separate functions to isolate failures
        testErrorNoInventory();
        testErrorNotOwner();
        testErrorInsufficientTokens();
        testErrorInsufficientFee();
    }

    function testErrorNoInventory() public {
        // Test buying when inventory is empty
        uint256[] memory tokenIds = new uint256[](1);
        tokenIds[0] = 1;

        // Verify the NFT is not in inventory
        assertFalse(hook.isInInventory(1));

        // Set up user for the transaction
        vm.startPrank(user);
        vm.deal(user, 1 ether);

        // Direct buy should fail with no inventory
        vm.expectRevert(RemyVaultHook.NoInventory.selector);
        hook.buyNFTs{value: 0.1 ether}(tokenIds);

        vm.stopPrank();
    }

    function testErrorNotOwner() public {
        uint256[] memory tokenIds = new uint256[](1);
        tokenIds[0] = 1;

        // Test selling NFT not owned by seller
        vm.mockCall(
            mockNFTCollection,
            abi.encodeWithSelector(IERC721.ownerOf.selector, 1),
            abi.encode(address(0xabc)) // Some other address
        );

        vm.expectRevert(RemyVaultHook.NotOwner.selector);
        vm.prank(user);
        hook.sellNFTs(tokenIds);
    }

    function testErrorInsufficientTokens() public {
        uint256[] memory tokenIds = new uint256[](1);
        tokenIds[0] = 1;

        // Test redeeming with insufficient balance
        vm.mockCall(
            mockVaultToken,
            abi.encodeWithSelector(IERC20Minimal.balanceOf.selector, address(hook)),
            abi.encode(0) // No balance
        );

        vm.expectRevert(RemyVaultHook.InsufficientBalance.selector);
        vm.prank(owner);
        hook.redeemNFTsFromVault(tokenIds);
    }

    function testErrorInsufficientFee() public {
        uint256[] memory tokenIds = new uint256[](1);
        tokenIds[0] = 1;

        // Test buy with insufficient ETH fee
        // First add NFT to inventory
        vm.mockCall(
            mockNFTCollection,
            abi.encodeWithSelector(IERC721.transferFrom.selector, owner, address(hook), 1),
            abi.encode()
        );

        vm.prank(owner);
        hook.addNFTsToInventory(tokenIds);

        // Calculate required fee
        uint256 tokenPrice = NFT_UNIT;
        uint256 ethFee = (tokenPrice * BUY_FEE) / hook.FEE_DENOMINATOR();

        // Mock token transfer from user to hook
        vm.mockCall(
            mockVaultToken,
            abi.encodeWithSelector(IERC20Minimal.transferFrom.selector, user, address(hook), tokenPrice),
            abi.encode(true)
        );

        // Set up user for the transaction
        vm.startPrank(user);
        vm.deal(user, ethFee - 1); // Give user less than the required fee

        // Send insufficient ETH
        vm.expectRevert(RemyVaultHook.InsufficientBalance.selector);
        hook.buyNFTs{value: ethFee - 1}(tokenIds);

        vm.stopPrank();
    }

    /**
     * @notice Test buy swap with no inventory
     */
    function testBuySwapWithNoInventory() public {
        // Setup swap params to buy NFT (token → vault token)
        IPoolManager.SwapParams memory swapParams =
            IPoolManager.SwapParams({zeroForOne: false, amountSpecified: -100 * 10 ** 18, sqrtPriceLimitX96: 0});

        // Create balance delta
        int128 amount0Delta = 90 * 10 ** 18;
        int128 amount1Delta = -100 * 10 ** 18;
        BalanceDelta swapDelta =
            BalanceDelta.wrap(int256((uint256(uint128(amount0Delta)) << 128) | uint128(amount1Delta)));

        // Encode hookData with 'true' to indicate NFT purchase is desired
        bytes memory hookData = abi.encode(true);

        // Should revert with NoInventory since inventory is empty
        vm.prank(address(mockPoolManager));
        vm.expectRevert(RemyVaultHook.NoInventory.selector);
        hook.afterSwap(user, poolKey, swapParams, swapDelta, hookData);
    }

    /**
     * @notice Test buying vault tokens without NFTs
     */
    function testBuyVaultTokensWithoutNFT() public {
        // Setup swap params to buy vault tokens (token → vault token)
        IPoolManager.SwapParams memory swapParams = IPoolManager.SwapParams({
            zeroForOne: false, // Buying vault token (currency1 → currency0)
            amountSpecified: -100 * 10 ** 18, // Exact input of 100 tokens
            sqrtPriceLimitX96: 0 // No price limit
        });

        // Create balance delta for the swap
        int128 amount0Delta = int128(int256(50 * 10 ** 18)); // Hook receives tokens
        int128 amount1Delta = -100 * 10 ** 18; // User sends tokens
        BalanceDelta swapDelta =
            BalanceDelta.wrap(int256((uint256(uint128(amount0Delta)) << 128) | uint128(amount1Delta)));

        // Call the hook directly as if pool manager called it - with empty hook data (no NFT purchase)
        vm.prank(address(mockPoolManager));
        (bytes4 selector,) = hook.afterSwap(user, poolKey, swapParams, swapDelta, bytes(""));

        // Check the return value
        assertEq(selector, IHooks(address(0)).afterSwap.selector);

        // Direct token purchase should work as well
        vm.deal(user, 1 ether);
        vm.prank(user);

        // Mock token transfer from user to hook
        vm.mockCall(
            mockVaultToken,
            abi.encodeWithSelector(IERC20Minimal.transferFrom.selector, user, address(hook), 1000 * 10 ** 18),
            abi.encode(true)
        );

        // No ETH fee should be charged (0 value)
        hook.buyVaultTokens(1000 * 10 ** 18, new uint256[](0));
    }

    function testHookPermissions() public view {
        Hooks.Permissions memory permissions = hook.getHookPermissions();

        // Verify required permissions are enabled
        assertTrue(permissions.beforeInitialize);
        assertTrue(permissions.beforeSwap);
        assertTrue(permissions.afterSwap);
        assertTrue(permissions.beforeSwapReturnDelta);

        // Verify unused permissions are disabled
        assertFalse(permissions.afterInitialize);
        assertFalse(permissions.beforeAddLiquidity);
        assertFalse(permissions.afterAddLiquidity);
        assertFalse(permissions.beforeRemoveLiquidity);
        assertFalse(permissions.afterRemoveLiquidity);
        assertFalse(permissions.beforeDonate);
        assertFalse(permissions.afterDonate);
        assertFalse(permissions.afterSwapReturnDelta);
        assertFalse(permissions.afterAddLiquidityReturnDelta);
        assertFalse(permissions.afterRemoveLiquidityReturnDelta);
    }
}
