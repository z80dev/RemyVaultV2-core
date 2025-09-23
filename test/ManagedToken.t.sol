// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Test} from "forge-std/Test.sol";

interface IManagedToken {
    // ERC20 functions
    function name() external view returns (string memory);
    function symbol() external view returns (string memory);
    function decimals() external view returns (uint8);
    function totalSupply() external view returns (uint256);
    function balanceOf(address account) external view returns (uint256);
    function allowance(address owner, address spender) external view returns (uint256);
    function transfer(address to, uint256 value) external returns (bool);
    function transferFrom(address from, address to, uint256 value) external returns (bool);
    function approve(address spender, uint256 value) external returns (bool);

    // Ownable functions
    function owner() external view returns (address);
    function transfer_ownership(address new_owner) external;
    function renounce_ownership() external;

    // Manager functions
    function mint(address to, uint256 amount) external;
    function burn(address from, uint256 amount) external;

    // Events
    event Transfer(address indexed from, address indexed to, uint256 value);
    event Approval(address indexed owner, address indexed spender, uint256 value);
    event OwnershipTransferred(address indexed previousOwner, address indexed newOwner);
}

contract ManagedTokenTest is Test {
    IManagedToken public token;
    address public manager;
    address public alice;
    address public bob;
    address public charlie;

    function setUp() public {
        manager = address(this);
        alice = makeAddr("alice");
        bob = makeAddr("bob");
        charlie = makeAddr("charlie");

        // Deploy ManagedToken with test contract as manager
        token = IManagedToken(deployCode("ManagedToken", abi.encode("Test Token", "TEST", manager)));
    }

    // Constructor and initial state tests
    function testConstructor() public view {
        assertEq(token.name(), "Test Token");
        assertEq(token.symbol(), "TEST");
        assertEq(token.decimals(), 18);
        assertEq(token.totalSupply(), 0);
        assertEq(token.owner(), manager);
    }

    // Minting tests
    function testMint() public {
        uint256 mintAmount = 1000 * 1e18;

        vm.expectEmit(true, true, false, true);
        emit IManagedToken.Transfer(address(0), alice, mintAmount);

        token.mint(alice, mintAmount);

        assertEq(token.balanceOf(alice), mintAmount);
        assertEq(token.totalSupply(), mintAmount);
    }

    function testMintMultipleAddresses() public {
        uint256 amount1 = 1000 * 1e18;
        uint256 amount2 = 2000 * 1e18;

        token.mint(alice, amount1);
        token.mint(bob, amount2);

        assertEq(token.balanceOf(alice), amount1);
        assertEq(token.balanceOf(bob), amount2);
        assertEq(token.totalSupply(), amount1 + amount2);
    }

    function testMintToZeroAddress() public {
        vm.expectRevert("erc20: mint to the zero address");
        token.mint(address(0), 1000);
    }

    function testMintOnlyManager() public {
        vm.prank(alice);
        vm.expectRevert("ownable: caller is not the owner");
        token.mint(bob, 1000);
    }

    // Burning tests
    function testBurn() public {
        uint256 mintAmount = 1000 * 1e18;
        uint256 burnAmount = 400 * 1e18;

        token.mint(alice, mintAmount);

        vm.expectEmit(true, true, false, true);
        emit IManagedToken.Transfer(alice, address(0), burnAmount);

        token.burn(alice, burnAmount);

        assertEq(token.balanceOf(alice), mintAmount - burnAmount);
        assertEq(token.totalSupply(), mintAmount - burnAmount);
    }

    function testBurnFullBalance() public {
        uint256 amount = 1000 * 1e18;

        token.mint(alice, amount);
        token.burn(alice, amount);

        assertEq(token.balanceOf(alice), 0);
        assertEq(token.totalSupply(), 0);
    }

    function testBurnExceedsBalance() public {
        uint256 mintAmount = 1000 * 1e18;
        uint256 burnAmount = 1500 * 1e18;

        token.mint(alice, mintAmount);

        vm.expectRevert("erc20: burn amount exceeds balance");
        token.burn(alice, burnAmount);
    }

    function testBurnOnlyManager() public {
        token.mint(alice, 1000);

        vm.prank(alice);
        vm.expectRevert("ownable: caller is not the owner");
        token.burn(alice, 500);
    }

    // Transfer tests
    function testTransfer() public {
        uint256 amount = 1000 * 1e18;
        uint256 transferAmount = 300 * 1e18;

        token.mint(alice, amount);

        vm.prank(alice);
        vm.expectEmit(true, true, false, true);
        emit IManagedToken.Transfer(alice, bob, transferAmount);

        bool success = token.transfer(bob, transferAmount);
        assertTrue(success);

        assertEq(token.balanceOf(alice), amount - transferAmount);
        assertEq(token.balanceOf(bob), transferAmount);
        assertEq(token.totalSupply(), amount); // Total supply unchanged
    }

    function testTransferInsufficientBalance() public {
        token.mint(alice, 100);

        vm.prank(alice);
        vm.expectRevert("erc20: transfer amount exceeds balance");
        token.transfer(bob, 200);
    }

    function testTransferToZeroAddress() public {
        token.mint(alice, 100);

        vm.prank(alice);
        vm.expectRevert("erc20: transfer to the zero address");
        token.transfer(address(0), 50);
    }

    // Approval and transferFrom tests
    function testApprove() public {
        uint256 approvalAmount = 500 * 1e18;

        vm.prank(alice);
        vm.expectEmit(true, true, false, true);
        emit IManagedToken.Approval(alice, bob, approvalAmount);

        bool success = token.approve(bob, approvalAmount);
        assertTrue(success);

        assertEq(token.allowance(alice, bob), approvalAmount);
    }

    function testApproveToZeroAddress() public {
        vm.prank(alice);
        vm.expectRevert("erc20: approve to the zero address");
        token.approve(address(0), 100);
    }

    function testTransferFrom() public {
        uint256 amount = 1000 * 1e18;
        uint256 approvalAmount = 600 * 1e18;
        uint256 transferAmount = 400 * 1e18;

        token.mint(alice, amount);

        vm.prank(alice);
        token.approve(bob, approvalAmount);

        vm.prank(bob);
        vm.expectEmit(true, true, false, true);
        emit IManagedToken.Transfer(alice, charlie, transferAmount);

        bool success = token.transferFrom(alice, charlie, transferAmount);
        assertTrue(success);

        assertEq(token.balanceOf(alice), amount - transferAmount);
        assertEq(token.balanceOf(charlie), transferAmount);
        assertEq(token.allowance(alice, bob), approvalAmount - transferAmount);
    }

    function testTransferFromInsufficientAllowance() public {
        token.mint(alice, 1000);

        vm.prank(alice);
        token.approve(bob, 100);

        vm.prank(bob);
        vm.expectRevert("erc20: insufficient allowance");
        token.transferFrom(alice, charlie, 200);
    }

    function testTransferFromInsufficientBalance() public {
        token.mint(alice, 100);

        vm.prank(alice);
        token.approve(bob, 200);

        vm.prank(bob);
        vm.expectRevert("erc20: transfer amount exceeds balance");
        token.transferFrom(alice, charlie, 150);
    }

    function testTransferFromZeroAddress() public {
        vm.expectRevert("erc20: insufficient allowance");
        token.transferFrom(address(0), alice, 100);
    }

    function testTransferFromToZeroAddress() public {
        token.mint(alice, 100);

        vm.prank(alice);
        token.approve(bob, 100);

        vm.prank(bob);
        vm.expectRevert("erc20: transfer to the zero address");
        token.transferFrom(alice, address(0), 50);
    }

    // Manager change tests
    function testChangeManager() public {
        address newManager = makeAddr("newManager");

        vm.expectEmit(true, true, false, true);
        emit IManagedToken.OwnershipTransferred(manager, newManager);

        token.transfer_ownership(newManager);

        assertEq(token.owner(), newManager);
    }

    function testChangeManagerOnlyCurrentManager() public {
        address newManager = makeAddr("newManager");

        vm.prank(alice);
        vm.expectRevert("ownable: caller is not the owner");
        token.transfer_ownership(newManager);
    }

    function testChangeManagerToZeroAddress() public {
        vm.expectRevert("ownable: new owner is the zero address");
        token.transfer_ownership(address(0));
    }

    function testNewManagerCanMintAndBurn() public {
        address newManager = makeAddr("newManager");

        // Change manager
        token.transfer_ownership(newManager);

        // Old manager cannot mint
        vm.expectRevert("ownable: caller is not the owner");
        token.mint(alice, 1000);

        // New manager can mint
        vm.prank(newManager);
        token.mint(alice, 1000);
        assertEq(token.balanceOf(alice), 1000);

        // New manager can burn
        vm.prank(newManager);
        token.burn(alice, 500);
        assertEq(token.balanceOf(alice), 500);
    }

    // Complex scenarios
    function testComplexTokenFlow() public {
        // Manager mints to alice
        token.mint(alice, 10000);

        // Alice transfers to bob
        vm.prank(alice);
        token.transfer(bob, 3000);

        // Alice approves charlie
        vm.prank(alice);
        token.approve(charlie, 5000);

        // Charlie transfers from alice to himself
        vm.prank(charlie);
        token.transferFrom(alice, charlie, 2000);

        // Manager burns from bob
        token.burn(bob, 1000);

        // Final balances
        assertEq(token.balanceOf(alice), 5000); // 10000 - 3000 - 2000
        assertEq(token.balanceOf(bob), 2000); // 3000 - 1000
        assertEq(token.balanceOf(charlie), 2000);
        assertEq(token.totalSupply(), 9000); // 10000 - 1000
        assertEq(token.allowance(alice, charlie), 3000); // 5000 - 2000
    }

    // Fuzz tests
    function testFuzzMint(address to, uint256 amount) public {
        vm.assume(to != address(0));
        vm.assume(amount < type(uint256).max / 2); // Prevent overflow in later operations

        token.mint(to, amount);

        assertEq(token.balanceOf(to), amount);
        assertEq(token.totalSupply(), amount);
    }

    function testFuzzBurn(uint256 mintAmount, uint256 burnAmount) public {
        vm.assume(mintAmount > 0 && mintAmount < type(uint256).max / 2);
        vm.assume(burnAmount <= mintAmount);

        token.mint(alice, mintAmount);
        token.burn(alice, burnAmount);

        assertEq(token.balanceOf(alice), mintAmount - burnAmount);
        assertEq(token.totalSupply(), mintAmount - burnAmount);
    }

    function testFuzzTransfer(uint256 amount, uint256 transferAmount) public {
        vm.assume(amount > 0 && amount < type(uint256).max / 2);
        vm.assume(transferAmount <= amount);

        token.mint(alice, amount);

        vm.prank(alice);
        bool success = token.transfer(bob, transferAmount);
        assertTrue(success);

        assertEq(token.balanceOf(alice), amount - transferAmount);
        assertEq(token.balanceOf(bob), transferAmount);
    }

    function testFuzzApproveAndTransferFrom(uint256 balance, uint256 approvalAmount, uint256 transferAmount) public {
        vm.assume(balance > 0 && balance < type(uint256).max / 2);
        vm.assume(approvalAmount <= balance);
        vm.assume(transferAmount <= approvalAmount);

        token.mint(alice, balance);

        vm.prank(alice);
        token.approve(bob, approvalAmount);

        vm.prank(bob);
        bool success = token.transferFrom(alice, charlie, transferAmount);
        assertTrue(success);

        assertEq(token.balanceOf(alice), balance - transferAmount);
        assertEq(token.balanceOf(charlie), transferAmount);
        assertEq(token.allowance(alice, bob), approvalAmount - transferAmount);
    }
}
