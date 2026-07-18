// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import { ECDSA } from "@openzeppelin/contracts/utils/cryptography/ECDSA.sol";
import { EIP712 } from "@openzeppelin/contracts/utils/cryptography/EIP712.sol";
import { IERC1271 } from "@openzeppelin/contracts/interfaces/IERC1271.sol";

/**
 * @title W3CashProcessorV2 — Design C authorization core (SKELETON, pre-audit)
 * @notice Immutable, non-custodial, permissionless intent processor with
 *         root-granted, spend-capped, revocable SESSION KEYS for delegated AI-agent
 *         signing. Implements ADR-0001 Design C + Addendum C (2026-07-18 hardening).
 *
 * @dev THIS IS A SPEC SKELETON for review + audit scoping, NOT a deployable build.
 *      Every security-critical DECISION from the ADR is encoded concretely with the
 *      correct ordering: two-signature delegation, hash-bound typed Policy, GATE/ACTION
 *      op-kind boundary, rolling-window SOURCE-keyed spend reserve (reserve-before-every-
 *      pull, CEI), transient flash frame with zero-on-every-exit, three revocation tiers,
 *      ERC-1271 root, native pause-refund, clamp-and-meter tip. Points that depend on
 *      not-yet-frozen integration detail (Permit2 exact call, adapter funding mechanics,
 *      flash-pool wiring, delta reconciliation) are marked `NOTE(freeze):` — they carry
 *      placeholder logic so the skeleton compiles and the accounting is exercised.
 *
 * Invariants preserved from the substrate (see DECISIONS.md ADR-0001):
 *   (1) PAUSE→resume: a failed gate returns before ANY state write; re-submitting the
 *       identical calldata reproduces the identical digest (atomic whole-intent no-op).
 *   (2) Recurring: maxRuns=0/N with cooldown>0 re-run each time the gate re-passes.
 *   (3) execute() is permissionless.  (4) EIP-712 domain = the execution chain.
 */
contract W3CashProcessorV2 is EIP712 {
    using ECDSA for bytes32;

    // ---------------------------------------------------------------------
    // Errors
    // ---------------------------------------------------------------------
    error SessionExpired();
    error SessionRevoked();
    error WrongEpoch();
    error WrongSession();
    error BadRootSig();
    error BadSessionSig();
    error IntentExpired();
    error CooldownRequired();
    error Cooldown();
    error Exhausted();
    error Cancelled();
    error PolicyMismatch();      // policy preimage != g.policyHash
    error OpsMismatch();         // ops preimage != it.opsHash
    error PolicyDenied();        // target/verb/cap check failed
    error GateMustNotMoveFunds();
    error OpsNotOrdered();       // an ACTION precedes a GATE (monotonic boundary broken)
    error TokenNotCapped();
    error CapExceeded();
    error NotRoot();
    error Reentrancy();
    error ThreadedOutsideFrame();
    error InsufficientFrameBalance();
    error ValueNotConserved();
    error TooManyEntries();
    error NativeRefundFailed();

    // ---------------------------------------------------------------------
    // Constants
    // ---------------------------------------------------------------------
    bytes4  private constant ERC1271_MAGIC = 0x1626ba7e;
    uint8   private constant KIND_GATE   = 1;
    uint8   private constant KIND_ACTION = 2;
    uint256 private constant NONE = type(uint256).max;
    uint256 private constant MAX_TARGETS = 16; // fail-closed decoder length bound
    uint256 private constant MAX_CAPS    = 16;

    // Verb bitmask positions (an action adapter DECLARES its verb; never trusted from op bytes).
    uint32 public constant VERB_TRANSFER = 1 << 0;
    uint32 public constant VERB_SWAP     = 1 << 1;
    uint32 public constant VERB_AAVE     = 1 << 2;
    uint32 public constant VERB_WRAP     = 1 << 3;
    uint32 public constant VERB_BRIDGE   = 1 << 4;
    uint32 public constant VERB_TIP      = 1 << 5;

    // EIP-712 typehashes. epoch is an explicit field of BOTH structs (Addendum C #9) so a
    // Tier-3 incrementEpoch() invalidates grant AND intent digests directly.
    bytes32 private constant SESSION_GRANT_TYPEHASH = keccak256(
        "SessionGrant(address root,address sessionKey,uint40 expiry,bytes32 policyHash,uint256 epoch,bytes32 salt)"
    );
    bytes32 private constant INTENT_TYPEHASH = keccak256(
        "Intent(bytes32 session,bytes32 opsHash,uint64 deadline,uint32 maxRuns,uint40 cooldown,uint256 epoch,bytes32 salt,address tipToken,uint128 tipAmount,address keeperOfRecord)"
    );

    // ---------------------------------------------------------------------
    // Types
    // ---------------------------------------------------------------------
    enum OpKind { GATE, ACTION }
    enum FundingMode { NONE, PERMIT2, STANDING, THREADED } // NONE=gate; ROOT-sourced: PERMIT2/STANDING; THREADED=frame

    /// resetPeriod==0 => absolute lifetime cap. >0 => rolling window (Addendum C Resolution 2).
    /// token==address(0) => native-ETH cap.
    struct TokenCap { address token; uint128 cap; uint40 resetPeriod; }

    struct Policy {
        bytes32[] allowedCodehashes; // codehash-pin (Addendum C #3); EMPTY = DENY ALL (fail-closed)
        bytes32[] gateCodehashes;    // GATE adapter allowlist (read-only condition adapters)
        uint32    verbMask;          // permitted action verbs; 0 = deny all
        TokenCap[] caps;             // per-token budgets; token absent => DENIED
    }

    struct SessionGrant {
        address root;        // grantor; EOA or ERC-1271
        address sessionKey;  // hot signer authorized to sign intents
        uint40  expiry;      // Tier-1 passive revocation
        bytes32 policyHash;  // keccak256(abi.encode(Policy)) — bound inside execute
        uint256 epoch;       // must == epoch[root]
        bytes32 salt;        // >=128-bit CSPRNG, ASP-unique across live+revoked
    }

    struct Op {
        OpKind      kind;
        address     target;     // adapter (codehash-pinned)
        uint112     value;      // native forwarded (actions only)
        FundingMode funding;    // NONE for gates
        address     fundToken;  // token pulled/threaded (address(0)=native)
        uint128     fundAmount; // declared upper bound (actual delta metered — NOTE)
        bytes       data;       // adapter calldata
    }

    struct Intent {
        bytes32 session;         // == grant digest
        bytes32 opsHash;         // keccak256(abi.encode(ops)) — binds full op list (C1)
        uint64  deadline;
        uint32  maxRuns;         // 0 = unlimited
        uint40  cooldown;
        uint256 epoch;           // must == epoch[root]
        bytes32 salt;
        address tipToken;        // RIDER-1 tip (dedicated sub-budget)
        uint128 tipAmount;
        address keeperOfRecord;  // 0 => open bounty (msg.sender); else routed payee
    }

    // ---------------------------------------------------------------------
    // Storage (persistent)
    // ---------------------------------------------------------------------
    struct Session { uint40 revokedAt; }              // 0 = live
    struct CapCursor { uint128 spent; uint40 lastReset; }
    struct IntentState { uint32 executions; uint40 lastExecuted; bool cancelled; }

    mapping(bytes32 => Session) public sessions;                              // key = grant digest
    mapping(bytes32 => mapping(address => CapCursor)) public spentByToken;    // (grant, token) — persistent
    mapping(bytes32 => mapping(address => CapCursor)) public tipSpent;        // (grant, tipToken) — dedicated
    mapping(bytes32 => IntentState) public intentState;                      // key = intent digest
    mapping(address => uint256) public epoch;                                // root cancel-ALL

    // Transient (EIP-1153) slots — flash frame + per-token frame-received ledger.
    uint256 private constant _T_DEPTH = uint256(keccak256("w3cash.v2.depth"));
    uint256 private constant _T_FLASH = uint256(keccak256("w3cash.v2.flashConsumed"));
    uint256 private constant _T_TOUCH_LEN = uint256(keccak256("w3cash.v2.touchLen"));
    bytes32 private constant _T_TOUCH_BASE = keccak256("w3cash.v2.touchToken");
    bytes32 private constant _T_FRAME_BASE = keccak256("w3cash.v2.frameReceived");

    // ---------------------------------------------------------------------
    // Events
    // ---------------------------------------------------------------------
    event WorkflowPaused(bytes32 indexed intentDigest, uint256 gateIndex);
    event WorkflowExecuted(bytes32 indexed intentDigest, address indexed root, uint32 executions);
    event SessionRevokedEvt(bytes32 indexed grantDigest, address indexed root);
    event EpochIncremented(address indexed root, uint256 newEpoch);
    event IntentCancelled(bytes32 indexed intentDigest);
    event CapExhausted(bytes32 indexed intentDigest, address token);
    event TipPaid(bytes32 indexed intentDigest, address indexed to, address token, uint256 amount);
    event TipSkipped(bytes32 indexed intentDigest, bytes32 reason);

    constructor() EIP712("W3Cash", "2") {}

    receive() external payable {}

    // ---------------------------------------------------------------------
    // execute — the two-signature session form
    // ---------------------------------------------------------------------
    function execute(
        SessionGrant calldata g,
        bytes calldata rootSig,
        Policy calldata policy,     // preimage; hash-checked vs g.policyHash
        Intent calldata it,
        Op[] calldata ops,          // preimage; hash-checked vs it.opsHash
        bytes calldata sessionSig
    ) external payable {
        _enterFrame(); // depth 0 -> 1; blocks uncontrolled re-entry

        address root = g.root; // the funds owner (initiator forwarded to adapters)

        // 1. GRANT authority (root)
        if (block.timestamp > g.expiry) revert SessionExpired();
        if (g.epoch != epoch[root]) revert WrongEpoch();
        bytes32 gDigest = _grantDigest(g);
        _verifyRoot(root, gDigest, rootSig);
        if (sessions[gDigest].revokedAt != 0) revert SessionRevoked();

        // 2. POLICY preimage bind (Addendum C #1 sharp edge A) — hash-then-use.
        if (keccak256(abi.encode(policy)) != g.policyHash) revert PolicyMismatch();

        // 3. INTENT authority (session key)
        if (it.session != gDigest) revert WrongSession();
        if (block.timestamp > it.deadline) revert IntentExpired();
        if (it.epoch != epoch[root]) revert WrongEpoch();
        if (it.maxRuns != 1 && it.cooldown == 0) revert CooldownRequired();
        if (keccak256(abi.encode(ops)) != it.opsHash) revert OpsMismatch();
        bytes32 iDigest = _intentDigest(it);
        if (ECDSA.recover(iDigest, sessionSig) != g.sessionKey) revert BadSessionSig();

        IntentState storage s = intentState[iDigest];
        if (s.cancelled) revert Cancelled();
        if (it.maxRuns != 0 && s.executions >= it.maxRuns) revert Exhausted();
        if (block.timestamp < uint256(s.lastExecuted) + it.cooldown) revert Cooldown();

        // 4. POLICY + op-kind shape gate (Addendum C #1) — GATE ops must precede ACTION ops.
        uint256 boundary = _checkPolicyAndShape(policy, ops);

        // 5. GATES [0, boundary) — read-only; a failure PAUSES with ZERO writes (invariant 1).
        for (uint256 i = 0; i < boundary; ++i) {
            if (!IGateAdapterV2(ops[i].target).check(root, ops[i].data)) {
                _refundNative(msg.sender); // pause-path native refund (Addendum C #5)
                _exitFrame();              // zero transient
                emit WorkflowPaused(iDigest, i);
                return;                    // no SSTORE reached => resume-intact
            }
        }

        // 6. RESERVE per-intent counters BEFORE actions (CEI, substrate reserve-then-run).
        unchecked { s.executions += 1; }
        s.lastExecuted = uint40(block.timestamp);

        // 7. ACTIONS [boundary, len) — reserve-before-EVERY-pull, then run.
        uint256 forwarded;
        for (uint256 i = boundary; i < ops.length; ++i) {
            Op calldata op = ops[i];
            _reserveAndFund(gDigest, policy, op, iDigest); // rolling-window, source-keyed, CEI
            forwarded += op.value;
            // NOTE(freeze): the processor feeds the adapter under SOLE-MOVER (no adapter-side
            // transferFrom(root)); actions run processor-fed. Placeholder dispatch:
            IActionAdapterV2(op.target).run{ value: op.value }(root, op.data);
        }

        // 8. RIDER-1 tip — clamp-and-meter against the DEDICATED tip sub-budget (Addendum C #8).
        _payTipMetered(gDigest, policy, it, root, iDigest);

        // 9. msg.value conservation + sweep residual to the caller (never stranded).
        if (forwarded > msg.value) revert ValueNotConserved();
        if (msg.value > forwarded) _sweepNative(msg.sender, msg.value - forwarded);

        _exitFrame();
        emit WorkflowExecuted(iDigest, root, s.executions);
    }

    // ---------------------------------------------------------------------
    // Revocation tiers
    // ---------------------------------------------------------------------
    function revokeSession(SessionGrant calldata g) external { // Tier 2
        if (msg.sender != g.root) revert NotRoot();
        bytes32 gDigest = _grantDigest(g);
        sessions[gDigest].revokedAt = uint40(block.timestamp);
        emit SessionRevokedEvt(gDigest, g.root);
    }

    function incrementEpoch() external returns (uint256 e) { // Tier 3 (cancel-ALL)
        e = ++epoch[msg.sender];
        emit EpochIncremented(msg.sender, e);
    }

    function cancelIntent(Intent calldata it) external { // per-intent (sub-session granularity)
        // NOTE(freeze): authorize via the session's root; skeleton keys off the intent digest.
        bytes32 iDigest = _intentDigest(it);
        intentState[iDigest].cancelled = true;
        emit IntentCancelled(iDigest);
    }

    // RIDER-3 dependency getters.
    function executionsOf(bytes32 iDigest) external view returns (uint256) {
        return intentState[iDigest].executions;
    }
    function lastExecutedOf(bytes32 iDigest) external view returns (uint256) {
        return intentState[iDigest].lastExecuted;
    }

    // ---------------------------------------------------------------------
    // Digests
    // ---------------------------------------------------------------------
    function grantDigest(SessionGrant calldata g) external view returns (bytes32) { return _grantDigest(g); }
    function intentDigest(Intent calldata it) external view returns (bytes32) { return _intentDigest(it); }

    function _grantDigest(SessionGrant calldata g) internal view returns (bytes32) {
        return _hashTypedDataV4(
            keccak256(abi.encode(
                SESSION_GRANT_TYPEHASH, g.root, g.sessionKey, g.expiry, g.policyHash, g.epoch, g.salt
            ))
        );
    }

    function _intentDigest(Intent calldata it) internal view returns (bytes32) {
        return _hashTypedDataV4(
            keccak256(abi.encode(
                INTENT_TYPEHASH, it.session, it.opsHash, it.deadline, it.maxRuns,
                it.cooldown, it.epoch, it.salt, it.tipToken, it.tipAmount, it.keeperOfRecord
            ))
        );
    }

    // ---------------------------------------------------------------------
    // Root verification (ERC-1271 or ecrecover)
    // ---------------------------------------------------------------------
    function _verifyRoot(address root, bytes32 digest, bytes calldata sig) internal view {
        if (root.code.length > 0) {
            // staticcall only; exact magic-value equality (Addendum C #10).
            // NOTE(freeze): prefer ERC-7739 nested-712 for the root branch to defeat
            // cross-context replay of a naive-1271 account.
            (bool ok, bytes memory ret) = root.staticcall(
                abi.encodeWithSelector(IERC1271.isValidSignature.selector, digest, sig)
            );
            if (!ok || ret.length < 32 || abi.decode(ret, (bytes4)) != ERC1271_MAGIC) revert BadRootSig();
        } else {
            if (ECDSA.recover(digest, sig) != root) revert BadRootSig();
        }
    }

    // ---------------------------------------------------------------------
    // Policy + op-kind shape (Addendum C #1)
    // ---------------------------------------------------------------------
    function _checkPolicyAndShape(Policy calldata p, Op[] calldata ops)
        internal
        view
        returns (uint256 boundary)
    {
        // Fail-closed length + fail-closed empties.
        if (p.allowedCodehashes.length > MAX_TARGETS || p.gateCodehashes.length > MAX_TARGETS
            || p.caps.length > MAX_CAPS) revert TooManyEntries();
        if (p.allowedCodehashes.length == 0 || p.verbMask == 0) revert PolicyDenied(); // deny-all defaults
        _assertNoDupCaps(p);

        bool seenAction = false;
        boundary = ops.length;
        for (uint256 i = 0; i < ops.length; ++i) {
            Op calldata op = ops[i];
            if (op.kind == OpKind.GATE) {
                if (seenAction) revert OpsNotOrdered();          // GATE after ACTION => reject (never mid-seq)
                if (_movesFunds(op)) revert GateMustNotMoveFunds();
                if (!_codehashIn(p.gateCodehashes, op.target)) revert PolicyDenied();
                // NOTE(freeze): belt-and-suspenders adapterKind()==KIND_GATE staticcall.
            } else {
                if (!seenAction) { seenAction = true; boundary = i; } // first ACTION marks the boundary
                if (!_codehashIn(p.allowedCodehashes, op.target)) revert PolicyDenied();
                if (_adapterVerb(op.target) & p.verbMask == 0) revert PolicyDenied(); // verb from adapter
                // ROOT-sourced funded ops must name a capped token; THREADED ops draw the frame ledger.
                if (op.funding == FundingMode.PERMIT2 || op.funding == FundingMode.STANDING) {
                    if (_capIndex(p, op.fundToken) == NONE) revert TokenNotCapped();
                }
                if (op.value != 0 && _capIndex(p, address(0)) == NONE) revert TokenNotCapped(); // native cap (Addendum C #11)
            }
        }
    }

    function _movesFunds(Op calldata op) internal pure returns (bool) {
        return op.funding != FundingMode.NONE || op.value != 0 || op.fundAmount != 0;
    }

    function _adapterVerb(address adapter) internal view returns (uint32) {
        // Verb is read from the pinned adapter's declared type, never from op bytes.
        try IActionAdapterV2(adapter).verb() returns (uint32 v) { return v; }
        catch { return 0; } // unknown => fail-closed (0 & mask == 0)
    }

    // ---------------------------------------------------------------------
    // Spend reserve — rolling-window, SOURCE-keyed, reserve-before-every-pull (CEI)
    // ---------------------------------------------------------------------
    function _reserveAndFund(bytes32 gDigest, Policy calldata p, Op calldata op, bytes32 iDigest) internal {
        if (op.funding == FundingMode.THREADED) {
            // Balance-threaded: draws ONLY the transient per-frame ledger; NEVER counts vs the cap.
            uint256 avail = _frameGet(op.fundToken);
            if (_depth() < 1) revert ThreadedOutsideFrame();
            if (avail < op.fundAmount) revert InsufficientFrameBalance();
            _frameSet(op.fundToken, avail - op.fundAmount);
            // NOTE(freeze): thread funds to the adapter from processor-held frame balance.
            return;
        }
        if (op.funding == FundingMode.NONE) return; // e.g. pure-native op already value-capped in shape check

        // ROOT-sourced (PERMIT2 / STANDING): reserve against the cap RIGHT BEFORE the pull.
        _reserveCap(gDigest, p, op.fundToken, op.fundAmount, iDigest);
        // NOTE(freeze): perform the actual root pull here (Permit2 SignatureTransfer or standing
        // allowance) INTO the adapter/processor, then reconcile the reserve to the MEASURED root
        // outflow delta (Addendum C #6, FoT-safe): re-book spent to (balanceBefore-balanceAfter).
    }

    function _reserveCap(bytes32 gDigest, Policy calldata p, address token, uint256 amount, bytes32 iDigest) internal {
        uint256 idx = _capIndex(p, token);
        if (idx == NONE) revert TokenNotCapped();
        TokenCap calldata cap = p.caps[idx];
        CapCursor storage c = spentByToken[gDigest][token];
        // Rolling window: reset BEFORE reserving (Addendum C Resolution 2).
        if (cap.resetPeriod != 0 && block.timestamp >= uint256(c.lastReset) + cap.resetPeriod) {
            c.spent = 0;
            c.lastReset = uint40(block.timestamp);
        }
        uint256 next = uint256(c.spent) + amount;
        if (next > cap.cap) {
            // Exhaustion is observable via the DISTINCT `CapExceeded()` error selector, which
            // keepers see when simulating execute() before submitting (an event emitted here would
            // be rolled back by the revert). The `CapExhausted` event is reserved for a future
            // non-reverting degrade path; iDigest is threaded through for that.
            revert CapExceeded();
        }
        c.spent = uint128(next);
    }

    // ---------------------------------------------------------------------
    // RIDER-1 tip — clamp-and-meter, dedicated sub-budget, best-effort (Addendum C #8)
    // ---------------------------------------------------------------------
    function _payTipMetered(bytes32 gDigest, Policy calldata p, Intent calldata it, address root, bytes32 iDigest) internal {
        if (it.tipAmount == 0 || it.tipToken == address(0)) return;
        uint256 idx = _capIndex(p, it.tipToken);
        if (idx == NONE) { emit TipSkipped(iDigest, "TIP_UNCAPPED"); return; } // degrade to untipped, never revert
        TokenCap calldata cap = p.caps[idx];
        CapCursor storage c = tipSpent[gDigest][it.tipToken];
        if (cap.resetPeriod != 0 && block.timestamp >= uint256(c.lastReset) + cap.resetPeriod) {
            c.spent = 0; c.lastReset = uint40(block.timestamp);
        }
        uint256 room = cap.cap > c.spent ? cap.cap - c.spent : 0;
        uint256 pay = it.tipAmount < room ? it.tipAmount : room; // clamp
        if (pay == 0) { emit TipSkipped(iDigest, "NO_ROOM"); return; }
        c.spent = uint128(uint256(c.spent) + pay);
        address to = it.keeperOfRecord != address(0) ? it.keeperOfRecord : msg.sender;
        // NOTE(freeze): gas-capped low-level best-effort tipToken.transferFrom(root, to, pay) after
        // all state updates; on failure emit TipSkipped and continue (never brick the action).
        root; // silence unused in skeleton
        emit TipPaid(iDigest, to, it.tipToken, pay);
    }

    // ---------------------------------------------------------------------
    // Policy helpers
    // ---------------------------------------------------------------------
    function _capIndex(Policy calldata p, address token) internal pure returns (uint256) {
        for (uint256 i = 0; i < p.caps.length; ++i) if (p.caps[i].token == token) return i;
        return NONE;
    }

    function _assertNoDupCaps(Policy calldata p) internal pure {
        for (uint256 i = 0; i < p.caps.length; ++i)
            for (uint256 j = i + 1; j < p.caps.length; ++j)
                if (p.caps[i].token == p.caps[j].token) revert PolicyDenied();
    }

    function _codehashIn(bytes32[] calldata set, address target) internal view returns (bool) {
        if (target.code.length == 0) return false; // fail-closed: no code => not an adapter
        bytes32 h = target.codehash;
        for (uint256 i = 0; i < set.length; ++i) if (set[i] == h) return true;
        return false;
    }

    // ---------------------------------------------------------------------
    // Native value handling
    // ---------------------------------------------------------------------
    function _refundNative(address to) internal {
        if (msg.value > 0) _sweepNative(to, msg.value);
    }
    function _sweepNative(address to, uint256 amount) internal {
        (bool ok, ) = to.call{ value: amount }("");
        if (!ok) revert NativeRefundFailed();
    }

    // ---------------------------------------------------------------------
    // Transient flash frame (EIP-1153) — zero on EVERY exit (SIR.trading lesson)
    // ---------------------------------------------------------------------
    function _enterFrame() internal {
        if (_tload(_T_DEPTH) != 0) revert Reentrancy(); // uncontrolled re-entry blocked
        _tstore(_T_DEPTH, 1);
    }

    /// @dev Zero depth, flash flag, and every touched frameReceived slot (all three exit paths;
    /// a full-tx revert also auto-clears transient at tx-end as belt-and-suspenders).
    function _exitFrame() internal {
        uint256 n = _tload(_T_TOUCH_LEN);
        for (uint256 i = 0; i < n; ++i) {
            uint256 tokSlot = uint256(keccak256(abi.encode(_T_TOUCH_BASE, i)));
            address tok = address(uint160(_tload(tokSlot)));
            _tstore(uint256(keccak256(abi.encode(_T_FRAME_BASE, tok))), 0);
            _tstore(tokSlot, 0);
        }
        _tstore(_T_TOUCH_LEN, 0);
        _tstore(_T_FLASH, 0);
        _tstore(_T_DEPTH, 0);
    }

    function _depth() internal view returns (uint256) { return _tload(_T_DEPTH); }

    function _frameGet(address token) internal view returns (uint256) {
        return _tload(uint256(keccak256(abi.encode(_T_FRAME_BASE, token))));
    }

    /// @dev Credit the per-frame received ledger (called ONLY as funds actually arrive this frame:
    /// flash principal from the pool, swap/unwrap outputs). NOTE(freeze): wire to the funnel.
    function _frameCredit(address token, uint256 amount) internal {
        uint256 slot = uint256(keccak256(abi.encode(_T_FRAME_BASE, token)));
        uint256 cur = _tload(slot);
        if (cur == 0 && amount != 0) {
            uint256 n = _tload(_T_TOUCH_LEN);
            _tstore(uint256(keccak256(abi.encode(_T_TOUCH_BASE, n))), uint256(uint160(token)));
            _tstore(_T_TOUCH_LEN, n + 1);
        }
        _tstore(slot, cur + amount);
    }
    function _frameSet(address token, uint256 v) internal {
        _tstore(uint256(keccak256(abi.encode(_T_FRAME_BASE, token))), v);
    }

    function _tload(uint256 slot) private view returns (uint256 v) {
        assembly { v := tload(slot) }
    }
    function _tstore(uint256 slot, uint256 v) private {
        assembly { tstore(slot, v) }
    }
}

// ---------------------------------------------------------------------
// Adapter interfaces (Addendum B split; the fleet is rewritten for SOLE-MOVER)
// ---------------------------------------------------------------------

/// @notice Read-only condition adapter. `check` returns false => the intent PAUSES (no writes).
interface IGateAdapterV2 {
    function check(address initiator, bytes calldata data) external view returns (bool pass);
    function adapterKind() external view returns (uint8); // KIND_GATE
}

/// @notice Action adapter. Processor-fed (SOLE-MOVER: no adapter-side transferFrom(root)).
interface IActionAdapterV2 {
    function adapterKind() external view returns (uint8); // KIND_ACTION
    function verb() external view returns (uint32);       // declared verb bitmask
    function run(address initiator, bytes calldata data) external payable returns (bytes memory);
}
