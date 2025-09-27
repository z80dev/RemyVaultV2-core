You're right—**specified ≠ input** and **unspecified ≠ output** in general. In Uniswap v4:

* For **exact‑input** (amountSpecified < 0): **specified = input**, **unspecified = output**.
* For **exact‑output** (amountSpecified > 0): **specified = output**, **unspecified = input**.

Also, **only** the specified side can be adjusted in `beforeSwap`, and **only** the unspecified side can be adjusted in `afterSwap`. So the hook must **dynamically** decide which callback to use based on:

1. the swap direction (`zeroForOne`), and
2. whether the **shared token** (the one also present in the parent) is the **specified** or **unspecified** side for *this* swap. ([OpenZeppelin][1])

Below is a fully updated version that:

* Supports **one‑level parent** and **exactly one shared token** between child and parent.
* **Charges the fee on the shared token** only.
* **Uses `beforeSwap` when the shared token is the specified side**, **uses `afterSwap` when it’s the unspecified side** (this now covers **exact‑output specified** swaps correctly).
* Includes a **Foundry test** with **exact‑input and exact‑output** cases for both paths.
* Includes a **CREATE2 address miner** that computes the **init code hash with constructor args** and finds a salt whose address encodes the required hook flags, per v4’s rules. ([Uniswap Docs][2])
* Notes on **donate()** semantics/JIT‑LP caveats. ([Uniswap Docs][3])

---

## `src/HierarchicalOneTokenFeeHook.sol`

```solidity
// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity ^0.8.24;

// --- Uniswap v4 core/periphery imports ---
import {BaseHook} from "v4-periphery/src/utils/BaseHook.sol";
import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "v4-core/src/types/PoolId.sol";
import {Currency, CurrencyLibrary} from "v4-core/src/types/Currency.sol";
import {BalanceDelta, BalanceDeltaLibrary} from "v4-core/src/types/BalanceDelta.sol";
import {BeforeSwapDelta, BeforeSwapDeltaLibrary} from "v4-core/src/types/BeforeSwapDelta.sol";
import {Hooks} from "v4-core/src/libraries/Hooks.sol";

// --- OZ utils ---
import {Ownable} from "openzeppelin-contracts/contracts/access/Ownable.sol";

/**
 * @title HierarchicalOneTokenFeeHook
 * @notice Hook-level fee on the single token shared between a CHILD pool and its PARENT.
 *         One-level deep: B→A, C→B (no transitive payouts).
 *
 * Semantics:
 *  - If the shared token is the SPECIFIED side for this swap => charge in beforeSwap
 *  - If the shared token is the UNSPECIFIED side           => charge in afterSwap
 *
 * Return-delta rules (v4):
 *  - beforeSwap can only adjust the SPECIFIED side (affects input for exact-in; affects output target for exact-out)
 *  - afterSwap can only adjust the UNSPECIFIED side (affects output for exact-in; affects input for exact-out)  // refs below
 */
contract HierarchicalOneTokenFeeHook is BaseHook, Ownable {
    using PoolIdLibrary for PoolKey;
    using CurrencyLibrary for Currency;
    using BalanceDeltaLibrary for BalanceDelta;

    constructor(IPoolManager _manager, address owner_) BaseHook(_manager) Ownable(owner_) {}

    // ------------------------------------------------------------------------
    // Configuration
    // ------------------------------------------------------------------------

    struct SplitConfig {
        bool   enabled;       // has config
        uint16 totalFeeBps;   // total hook fee on the shared token (e.g., 1000 = 10%)
        uint16 selfBps;       // portion of totalFeeBps routed to THIS (child) pool; parent gets remainder

        bool   hasParent;
        PoolKey parentKey;

        // Exactly-one-shared-token bookkeeping
        bool sharedIsChild0;   // in CHILD key, the shared token is currency0?
        bool sharedIsParent0;  // in PARENT key, the shared token is currency0?
    }

    mapping(PoolId => SplitConfig) public splits;

    /// @notice Set fee split for a CHILD pool (and optional PARENT).
    /// @dev Requires child & parent share EXACTLY ONE currency; records which side (currency0/1) in both keys.
    function setSplit(
        PoolKey calldata childKey,
        uint16 totalFeeBps,
        uint16 selfBps,
        bool hasParent,
        PoolKey calldata parentKey
    ) external onlyOwner {
        require(totalFeeBps <= 10_000, "fee>100%");
        require(selfBps <= totalFeeBps, "self>total");

        SplitConfig memory sc;
        sc.enabled     = true;
        sc.totalFeeBps = totalFeeBps;
        sc.selfBps     = selfBps;
        sc.hasParent   = hasParent;

        if (hasParent) {
            (bool c0p0, bool c0p1, bool c1p0, bool c1p1) = _matches(childKey, parentKey);
            uint256 matches = (c0p0?1:0) + (c0p1?1:0) + (c1p0?1:0) + (c1p1?1:0);
            require(matches == 1, "must share exactly one token");
            sc.parentKey = parentKey;
            if (c0p0) { sc.sharedIsChild0 = true;  sc.sharedIsParent0 = true;  }
            if (c0p1) { sc.sharedIsChild0 = true;  sc.sharedIsParent0 = false; }
            if (c1p0) { sc.sharedIsChild0 = false; sc.sharedIsParent0 = true;  }
            if (c1p1) { sc.sharedIsChild0 = false; sc.sharedIsParent0 = false; }
        }

        splits[childKey.toId()] = sc;
    }

    function _matches(PoolKey calldata a, PoolKey calldata b)
        private pure
        returns (bool a0_b0, bool a0_b1, bool a1_b0, bool a1_b1)
    {
        a0_b0 = (a.currency0 == b.currency0);
        a0_b1 = (a.currency0 == b.currency1);
        a1_b0 = (a.currency1 == b.currency0);
        a1_b1 = (a.currency1 == b.currency1);
    }

    // ------------------------------------------------------------------------
    // Hook flags (address must encode these via create2 mining)
    // ------------------------------------------------------------------------

    /// @dev We require both beforeSwap/afterSwap plus their return-deltas.
    function getHookPermissions() public pure override returns (Hooks.Permissions memory p) {
        p.beforeSwap = true;
        p.beforeSwapReturnDelta = true;
        p.afterSwap = true;
        p.afterSwapReturnDelta = true;
    }

    // ------------------------------------------------------------------------
    // Core logic
    // ------------------------------------------------------------------------

    /// @dev For a given (zeroForOne, exactIn), which token is SPECIFIED in the child?
    /// zeroForOne:
    ///   exactIn  => specified is token0
    ///   exactOut => specified is token1
    /// !zeroForOne:
    ///   exactIn  => specified is token1
    ///   exactOut => specified is token0
    function _specifiedIsC0(bool zeroForOne, bool exactIn) private pure returns (bool) {
        return zeroForOne ? exactIn : !exactIn;
    }

    function _abs(int256 x) private pure returns (uint256) {
        return uint256(x >= 0 ? x : -x);
    }

    /// @notice Charge on specified side (shared token == specified)
    function _beforeSwap(
        address, // sender
        PoolKey calldata key,
        IPoolManager.SwapParams calldata params,
        bytes calldata /*hookData*/
    ) internal override returns (bytes4, BeforeSwapDelta, uint24) {
        SplitConfig memory sc = splits[key.toId()];
        if (!sc.enabled || sc.totalFeeBps == 0) {
            return (this.beforeSwap.selector, BeforeSwapDeltaLibrary.ZERO_DELTA, 0);
        }

        bool exactIn = params.amountSpecified < 0;
        bool specifiedIsC0 = _specifiedIsC0(params.zeroForOne, exactIn);
        bool sharedIsSpecified = (sc.sharedIsChild0 == specifiedIsC0);

        if (!sharedIsSpecified) {
            return (this.beforeSwap.selector, BeforeSwapDeltaLibrary.ZERO_DELTA, 0);
        }

        // Fee is a fraction of the SPECIFIED amount (input on exact-in; output on exact-out)
        uint256 specifiedAbs = _abs(params.amountSpecified);
        uint256 feeTotal = (specifiedAbs * sc.totalFeeBps) / 10_000;
        if (feeTotal == 0) return (this.beforeSwap.selector, BeforeSwapDeltaLibrary.ZERO_DELTA, 0);

        // Split: child + parent
        uint256 childFee  = (specifiedAbs * sc.selfBps) / 10_000;
        uint256 parentFee = feeTotal - childFee;

        // Donate to CHILD pool in the shared token side
        if (childFee > 0) {
            poolManager.donate(
                key,
                sc.sharedIsChild0 ? childFee : 0,
                sc.sharedIsChild0 ? 0 : childFee,
                bytes("")
            );
        }
        // Donate to PARENT pool (if any)
        if (sc.hasParent && parentFee > 0) {
            poolManager.donate(
                sc.parentKey,
                sc.sharedIsParent0 ? parentFee : 0,
                sc.sharedIsParent0 ? 0 : parentFee,
                bytes("")
            );
        }

        // Return +fee on SPECIFIED to net the hook's donation (router pays it).
        // For exact-in: increases input; for exact-out: increases output target.
        BeforeSwapDelta d = BeforeSwapDeltaLibrary.toBeforeSwapDelta(
            int128(int256(feeTotal)), // specified delta (+)
            int128(0)                 // unspecified delta unchanged
        );
        return (this.beforeSwap.selector, d, 0);
    }

    /// @notice Charge on unspecified side (shared token == unspecified)
    function _afterSwap(
        address, // sender
        PoolKey calldata key,
        IPoolManager.SwapParams calldata params,
        BalanceDelta delta,
        bytes calldata /*hookData*/
    ) internal override returns (bytes4, int128) {
        SplitConfig memory sc = splits[key.toId()];
        if (!sc.enabled || sc.totalFeeBps == 0) {
            return (this.afterSwap.selector, int128(0));
        }

        bool exactIn = params.amountSpecified < 0;
        bool specifiedIsC0 = _specifiedIsC0(params.zeroForOne, exactIn);
        bool sharedIsSpecified = (sc.sharedIsChild0 == specifiedIsC0);
        if (sharedIsSpecified) {
            // We only act here when the shared token is the UNSPECIFIED side.
            return (this.afterSwap.selector, int128(0));
        }

        // UNSPECIFIED magnitude from swap result (child side). We only need |amount|.
        // If specifiedIsC0 -> unspecified is token1; else unspecified is token0.
        int128 unspecSigned = specifiedIsC0 ? delta.amount1() : delta.amount0();
        uint256 unspecAbs = uint256(unspecSigned >= 0 ? uint128(unspecSigned) : uint128(-unspecSigned));

        uint256 feeTotal = (unspecAbs * sc.totalFeeBps) / 10_000;
        if (feeTotal == 0) return (this.afterSwap.selector, int128(0));

        // Split: child + parent
        uint256 childFee  = (unspecAbs * sc.selfBps) / 10_000;
        uint256 parentFee = feeTotal - childFee;

        // Donate to CHILD
        if (childFee > 0) {
            poolManager.donate(
                key,
                sc.sharedIsChild0 ? childFee : 0,
                sc.sharedIsChild0 ? 0 : childFee,
                bytes("")
            );
        }
        // Donate to PARENT
        if (sc.hasParent && parentFee > 0) {
            poolManager.donate(
                sc.parentKey,
                sc.sharedIsParent0 ? parentFee : 0,
                sc.sharedIsParent0 ? 0 : parentFee,
                bytes("")
            );
        }

        // Return +fee on UNSPECIFIED to net the hook's donation (router pays it).
        // For exact-in: reduces output; for exact-out: increases input required.
        return (this.afterSwap.selector, int128(int256(feeTotal)));
    }
}
```

> **Why this covers exact‑output properly:**
> If shared token is **specified** (output on exact‑out), we add `+fee` in **beforeSwap** (specified side) and donate that fee to LPs; the pool outputs `targetOut + fee`, while the donation nets out the extra, so the user still receives their targetOut and the input side increases accordingly. If the shared token is **unspecified** (input on exact‑out), we charge via **afterSwap** (unspecified side), returning `+fee` so the router supplies extra input; LPs receive the donated fee. This respects v4’s “specified→before, unspecified→after” separation. ([OpenZeppelin][1])

---

## `test/MockPoolManager.sol`

```solidity
// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity ^0.8.24;

import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {Currency} from "v4-core/src/types/Currency.sol";
import {BalanceDelta, BalanceDeltaLibrary, toBalanceDelta} from "v4-core/src/types/BalanceDelta.sol";

contract MockPoolManager is IPoolManager {
    using BalanceDeltaLibrary for BalanceDelta;

    struct Donation { PoolKey key; uint256 amount0; uint256 amount1; bytes data; }
    Donation[] public donations;

    function donate(PoolKey memory key, uint256 amount0, uint256 amount1, bytes calldata hookData)
        external
        returns (BalanceDelta)
    {
        donations.push(Donation({key: key, amount0: amount0, amount1: amount1, data: hookData}));
        return toBalanceDelta(0, 0);
    }

    // ---- Unused IPoolManager methods (stubs) ----
    function initialize(PoolKey memory, uint160) external returns (int24) { revert("unused"); }
    function unlock(bytes calldata) external returns (bytes memory) { revert("unused"); }
    function swap(PoolKey memory, IPoolManager.SwapParams memory, bytes calldata) external returns (BalanceDelta) { revert("unused"); }
    function modifyLiquidity(PoolKey memory, IPoolManager.ModifyLiquidityParams memory, bytes calldata) external
        returns (BalanceDelta, BalanceDelta) { revert("unused"); }
    function take(Currency, address, uint256) external { revert("unused"); }
    function settle(Currency) external returns (uint256) { revert("unused"); }
    function mint(address, uint256) external { revert("unused"); }
    function burn(address, uint256) external { revert("unused"); }
    function transfer(address, Currency, address, uint256) external { revert("unused"); }
    function sync(PoolKey memory) external returns (BalanceDelta) { revert("unused"); }
    function protocolFeesAccrued(Currency) external view returns (uint256) { revert("unused"); }
    function setProtocolFee(PoolKey memory, uint24) external { revert("unused"); }
    function setProtocolFeeController(address) external { revert("unused"); }
    function collectProtocolFees(address, Currency) external returns (uint256) { revert("unused"); }
    function updateDynamicLPFee(PoolKey memory, uint24) external { revert("unused"); }
}
```

---

## `test/HierarchicalOneTokenFeeHook.t.sol`

Covers **four** scenarios including **exact‑output specified**:

```solidity
// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity ^0.8.24;

import "forge-std/Test.sol";

import {HierarchicalOneTokenFeeHook} from "../src/HierarchicalOneTokenFeeHook.sol";
import {MockPoolManager} from "./MockPoolManager.sol";

import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {PoolIdLibrary} from "v4-core/src/types/PoolId.sol";
import {Currency} from "v4-core/src/types/Currency.sol";
import {BalanceDelta, toBalanceDelta} from "v4-core/src/types/BalanceDelta.sol";
import {BeforeSwapDelta, BeforeSwapDeltaLibrary} from "v4-core/src/types/BeforeSwapDelta.sol";
import {IHooks} from "v4-core/src/interfaces/IHooks.sol";

contract HierarchicalOneTokenFeeHookTest is Test {
    MockPoolManager manager;
    HierarchicalOneTokenFeeHook hook;

    // Toy token addresses (no ERC20 needed for these unit tests)
    address X = address(0xAAA1); // shared token across pools
    address A = address(0xAAA2);
    address B = address(0xAAA3);
    address C = address(0xAAA4);

    PoolKey keyA; // (X, A)
    PoolKey keyB; // (X, B)  child->parent: B->A (shared = X)
    PoolKey keyC; // (X, C)  child->parent: C->B (shared = X)

    function setUp() public {
        manager = new MockPoolManager();
        hook    = new HierarchicalOneTokenFeeHook(IPoolManager(address(manager)), address(this));

        keyA = PoolKey({
            currency0: Currency.wrap(X),
            currency1: Currency.wrap(A),
            fee: 3000,
            tickSpacing: 60,
            hooks: IHooks(address(hook))
        });
        keyB = PoolKey({
            currency0: Currency.wrap(X),
            currency1: Currency.wrap(B),
            fee: 3000,
            tickSpacing: 60,
            hooks: IHooks(address(hook))
        });
        keyC = PoolKey({
            currency0: Currency.wrap(X),
            currency1: Currency.wrap(C),
            fee: 3000,
            tickSpacing: 60,
            hooks: IHooks(address(hook))
        });

        // 10% total; A self=10%; B self=7.5% + 2.5% to A; C self=7.5% + 2.5% to B
        hook.setSplit(keyA, 1000, 1000, false, keyA); // parent ignored
        hook.setSplit(keyB, 1000,  750, true,  keyA);
        hook.setSplit(keyC, 1000,  750, true,  keyB);
    }

    // -------- exact-input: shared == specified (X is input) -> beforeSwap --------
    function test_BeforeSwap_ExactIn_sharedSpecified_B_pays_self_75_parentA_25() public {
        // zeroForOne=true, exactIn => specified is currency0 (X) => shared is specified
        IPoolManager.SwapParams memory p = IPoolManager.SwapParams({
            zeroForOne: true,
            amountSpecified: -int256(1_000e18),
            sqrtPriceLimitX96: 0
        });

        vm.prank(address(manager));
        (bytes4 sel, BeforeSwapDelta ret, uint24 lpFee) = hook.beforeSwap(address(this), keyB, p, "");
        assertEq(sel, hook.beforeSwap.selector);
        assertEq(lpFee, 0);

        // feeTotal = 10% of specified(1000 X) = 100 X
        assertEq(int256(BeforeSwapDeltaLibrary.getSpecifiedDelta(ret)), int256(100e18));
        assertEq(int256(BeforeSwapDeltaLibrary.getUnspecifiedDelta(ret)), 0);

        (PoolKey memory d0, uint256 a0_0, uint256 a0_1, ) = manager.donations(0);
        (PoolKey memory d1, uint256 a1_0, uint256 a1_1, ) = manager.donations(1);

        // child B: 75 X (amount0)
        assertEq(address(uint160(Currency.unwrap(d0.currency0))), X);
        assertEq(a0_0,  75e18); assertEq(a0_1, 0);

        // parent A: 25 X
        assertEq(address(uint160(Currency.unwrap(d1.currency0))), X);
        assertEq(a1_0,  25e18); assertEq(a1_1, 0);
    }

    // -------- exact-input: shared == unspecified (X is output) -> afterSwap --------
    function test_AfterSwap_ExactIn_sharedUnspecified_C_pays_self_75_parentB_25() public {
        // zeroForOne=false, exactIn => specified is currency1 (C); unspecified is currency0 (X)
        IPoolManager.SwapParams memory p = IPoolManager.SwapParams({
            zeroForOne: false,
            amountSpecified: -int256(2_000e18),
            sqrtPriceLimitX96: 0
        });

        // pretend router gets +1000 X, -2000 C
        BalanceDelta routerDelta = toBalanceDelta(int128(1_000e18), -int128(2_000e18));

        vm.prank(address(manager));
        (bytes4 sel, int128 afterRet) = hook.afterSwap(address(this), keyC, p, routerDelta, "");
        assertEq(sel, hook.afterSwap.selector);
        // feeTotal = 10% of |unspecified|(1000 X) = 100 X
        assertEq(int256(afterRet), int256(100e18));

        (PoolKey memory d0, uint256 a0_0, uint256 a0_1, ) = manager.donations(0);
        (PoolKey memory d1, uint256 a1_0, uint256 a1_1, ) = manager.donations(1);
        // child C: 75 X
        assertEq(address(uint160(Currency.unwrap(d0.currency0))), X);
        assertEq(a0_0,  75e18); assertEq(a0_1, 0);
        // parent B: 25 X
        assertEq(address(uint160(Currency.unwrap(d1.currency0))), X);
        assertEq(a1_0,  25e18); assertEq(a1_1, 0);
    }

    // -------- exact-output: shared == specified (X is output) -> beforeSwap --------
    function test_BeforeSwap_ExactOut_sharedSpecified_B_pays_self_75_parentA_25() public {
        // zeroForOne=false (token1 -> token0), exactOut => specified is currency0 (X) => shared is specified
        IPoolManager.SwapParams memory p = IPoolManager.SwapParams({
            zeroForOne: false,
            amountSpecified: int256(500e18), // exact-output of 500 X
            sqrtPriceLimitX96: 0
        });

        vm.prank(address(manager));
        (bytes4 sel, BeforeSwapDelta ret, ) = hook.beforeSwap(address(this), keyB, p, "");
        assertEq(sel, hook.beforeSwap.selector);

        // feeTotal = 10% of specified(500 X) = 50 X -> +50 on specified
        assertEq(int256(BeforeSwapDeltaLibrary.getSpecifiedDelta(ret)), int256(50e18));
        assertEq(int256(BeforeSwapDeltaLibrary.getUnspecifiedDelta(ret)), 0);

        (PoolKey memory d0, uint256 a0_0, uint256 a0_1, ) = manager.donations(0);
        (PoolKey memory d1, uint256 a1_0, uint256 a1_1, ) = manager.donations(1);
        // child B: 37.5 X
        assertEq(address(uint160(Currency.unwrap(d0.currency0))), X);
        assertEq(a0_0,  37_500000000000000000); assertEq(a0_1, 0);
        // parent A: 12.5 X
        assertEq(address(uint160(Currency.unwrap(d1.currency0))), X);
        assertEq(a1_0,  12_500000000000000000); assertEq(a1_1, 0);
    }

    // -------- exact-output: shared == unspecified (X is input) -> afterSwap --------
    function test_AfterSwap_ExactOut_sharedUnspecified_C_pays_self_75_parentB_25() public {
        // zeroForOne=true (token0 -> token1), exactOut => specified is currency1 (C); unspecified is currency0 (X)
        IPoolManager.SwapParams memory p = IPoolManager.SwapParams({
            zeroForOne: true,
            amountSpecified: int256(1_500e18), // exact-output 1500 C
            sqrtPriceLimitX96: 0
        });

        // Suppose input required is 1,200 X (the UNSPECIFIED side in this config)
        BalanceDelta routerDelta = toBalanceDelta(-int128(1_200e18), int128(1_500e18));

        vm.prank(address(manager));
        (bytes4 sel, int128 afterRet) = hook.afterSwap(address(this), keyC, p, routerDelta, "");
        assertEq(sel, hook.afterSwap.selector);

        // feeTotal = 10% of |unspecified|(1200 X) = 120 X -> +120 on unspecified
        assertEq(int256(afterRet), int256(120e18));

        (PoolKey memory d0, uint256 a0_0, uint256 a0_1, ) = manager.donations(0);
        (PoolKey memory d1, uint256 a1_0, uint256 a1_1, ) = manager.donations(1);
        // child C: 90 X
        assertEq(address(uint160(Currency.unwrap(d0.currency0))), X);
        assertEq(a0_0,  90e18); assertEq(a0_1, 0);
        // parent B: 30 X
        assertEq(address(uint160(Currency.unwrap(d1.currency0))), X);
        assertEq(a1_0,  30e18); assertEq(a1_1, 0);
    }
}
```

> These unit tests validate the **decision logic**, **before/after return‑delta placement**, and **donation routing**—including **exact‑output specified** swaps. For full integration (real pool math, fee growth, and **collect**), bolt this onto the Uniswap v4 template and assert fee growth/collection via PositionManager (donations are allocated to **in‑range LPs** at donation time). ([Uniswap Docs][3])

---

## `script/MineHookAddress.s.sol` — address flags miner (**init code with args**)

```solidity
// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity ^0.8.24;

// forge script script/MineHookAddress.s.sol:MineHookAddress \
//   --sig "run(address,address)" <POOL_MANAGER> <OWNER> \
//   --broadcast --private-key $PK --rpc-url <RPC>

import "forge-std/Script.sol";
import {Hooks} from "v4-core/src/libraries/Hooks.sol";
import {IHooks} from "v4-core/src/interfaces/IHooks.sol";
import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {HierarchicalOneTokenFeeHook} from "../src/HierarchicalOneTokenFeeHook.sol";

contract MineHookAddress is Script {
    function run(address poolManager, address owner) external {
        // Use the broadcaster as the CREATE2 deployer
        uint256 pk = vm.envUint("PRIVATE_KEY");
        vm.startBroadcast(pk);
        address deployer = vm.addr(pk);

        // Required permissions
        Hooks.Permissions memory p;
        p.beforeSwap = true;
        p.beforeSwapReturnDelta = true;
        p.afterSwap = true;
        p.afterSwapReturnDelta = true;

        // Compute init code (creation code + constructor args)
        bytes memory initCode = abi.encodePacked(
            type(HierarchicalOneTokenFeeHook).creationCode,
            abi.encode(IPoolManager(poolManager), owner)
        );
        bytes32 initCodeHash = keccak256(initCode);

        uint256 tries;
        while (true) {
            bytes32 salt = keccak256(abi.encodePacked(tries));
            address predicted = computeCreate2(deployer, salt, initCodeHash);
            if (Hooks.isValidHookAddress(IHooks(predicted), p)) {
                console2.log("Found salt:", vm.toString(salt));
                console2.log("Predicted addr:", predicted);
                break;
            }
            unchecked { ++tries; }
            if (tries % 100000 == 0) console2.log("tried", tries);
        }

        vm.stopBroadcast();
    }

    function computeCreate2(address _deployer, bytes32 _salt, bytes32 _initCodeHash) internal pure returns (address) {
        return address(uint160(uint256(keccak256(abi.encodePacked(bytes1(0xff), _deployer, _salt, _initCodeHash)))));
    }
}
```

> **Why mine?** In v4, the **hook address encodes which callbacks to call**. The miner finds a `salt` so the deployed address satisfies your `getHookPermissions`. Use the deploy script below with that salt. ([Uniswap Docs][2])

---

## `script/DeployHookWithMinedSalt.s.sol` (optional convenience)

```solidity
// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity ^0.8.24;

// forge script script/DeployHookWithMinedSalt.s.sol:DeployHookWithMinedSalt \
//   --sig "run(address,address,bytes32)" <POOL_MANAGER> <OWNER> <SALT> \
//   --broadcast --private-key $PK --rpc-url <RPC>

import "forge-std/Script.sol";
import {HierarchicalOneTokenFeeHook} from "../src/HierarchicalOneTokenFeeHook.sol";
import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";

contract DeployHookWithMinedSalt is Script {
    function run(address poolManager, address owner, bytes32 salt) external {
        vm.startBroadcast();
        HierarchicalOneTokenFeeHook hook =
            new HierarchicalOneTokenFeeHook{salt: salt}(IPoolManager(poolManager), owner);
        console2.log("Deployed hook:", address(hook));
        vm.stopBroadcast();
    }
}
```

---

## `foundry.toml`

```toml
[profile.default]
src = "src"
out = "out"
libs = ["lib"]
solc_version = "0.8.24"
evm_version = "cancun"
optimizer = true
optimizer_runs = 20000

[fmt]
line_length = 110
tab_width = 4
bracket_spacing = true
```

## `remappings.txt`

```txt
v4-core/=lib/v4-core/
v4-periphery/=lib/v4-periphery/
openzeppelin-contracts/=lib/openzeppelin-contracts/
forge-std/=lib/forge-std/src/
```

## `README.md` (concise)

````md
# HierarchicalOneTokenFeeHook

Hook-level fee that routes a portion to the child pool's LPs and a portion to its single-level parent, **only** on the token they share.

**Dispatch:**
- If shared token is **specified** for this swap ⇒ charge in **beforeSwap** (return-delta on specified).
- If shared token is **unspecified** ⇒ charge in **afterSwap** (return-delta on unspecified).

This symmetry handles **exact-input** and **exact-output** swaps correctly.  
Donations go to **in-range LPs** at donation time; consider JIT-liquidity implications.

## Install
```bash
forge init
forge install Uniswap/v4-core Uniswap/v4-periphery OpenZeppelin/openzeppelin-contracts
````

## Test

```bash
forge test -vv
```

## Mine an address that encodes hook flags

```bash
export PRIVATE_KEY=0x...   # deployer
forge script script/MineHookAddress.s.sol:MineHookAddress \
  --sig "run(address,address)" <POOL_MANAGER> <OWNER> \
  --broadcast --rpc-url <RPC>
```

Use the printed salt to deploy:

```bash
forge script script/DeployHookWithMinedSalt.s.sol:DeployHookWithMinedSalt \
  --sig "run(address,address,bytes32)" <POOL_MANAGER> <OWNER> <SALT> \
  --broadcast --rpc-url <RPC>
```

```

---

### Design gotchas & guidance

- **Specified vs unspecified**: don’t conflate with input/output. The mapping flips on exact‑output. This hook uses `amountSpecified` sign and `zeroForOne` to determine which currency is the specified side, then routes the return‑delta to the correct hook (`beforeSwap` or `afterSwap`). :contentReference[oaicite:6]{index=6}
- **Return‑delta packing**: `BeforeSwapDelta` packs **specified** in the upper 128 bits, **unspecified** in the lower; `afterSwap` returns an `int128` (unspecified only). We never set both in the same call (that would revert in PoolManager). :contentReference[oaicite:7]{index=7}
- **Donations**: `IPoolManager.donate` allocates to **in‑range** LPs; it can be JIT’d. We donate **before** returning the positive delta so the hook’s negative balance from donation is netted out by the return‑delta in the same unlock. :contentReference[oaicite:8]{index=8}
- **Hook flags**: Address must encode the callback set. The miner computes the CREATE2 address using the **creation code + constructor args**, ensuring the same salt works when deploying. :contentReference[oaicite:9]{index=9}

If you want, I can also provide an **integration test** scaffold that spins up a real v4 `PoolManager`, initializes pools (A/B/C), adds liquidity, runs swaps via the router, and verifies **fee growth** and **collect** across A/B/C LPs with the exact splits.
::contentReference[oaicite:10]{index=10}
```

[1]: https://www.openzeppelin.com/news/6-questions-to-ask-before-writing-a-uniswap-v4-hook?utm_source=chatgpt.com "Six Questions To Ask Before Writing a Uniswap v4 Hook"
[2]: https://docs.uniswap.org/contracts/v4/guides/hooks/hook-deployment?utm_source=chatgpt.com "Hook Deployment"
[3]: https://docs.uniswap.org/contracts/v4/reference/core/interfaces/IPoolManager?utm_source=chatgpt.com "IPoolManager"
