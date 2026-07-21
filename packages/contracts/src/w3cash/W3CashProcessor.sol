// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import { ECDSA } from "@openzeppelin/contracts/utils/cryptography/ECDSA.sol";
import { EIP712 } from "@openzeppelin/contracts/utils/cryptography/EIP712.sol";
import { IERC1271 } from "@openzeppelin/contracts/interfaces/IERC1271.sol";
import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { SafeERC20 } from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

/**
 * @title W3CashProcessor — Design C authorization core (PRE-AUDIT, in progress)
 * @notice Immutable, non-custodial, permissionless intent processor with
 *         root-granted, spend-capped, revocable SESSION KEYS for delegated AI-agent
 *         signing. Implements ADR-0001 Design C + Addenda C/D.
 *
 * @dev Build status against ADR-0001 Addendum D (19-item plan):
 *      DONE — two-signature delegation, hash-bound typed Policy, GATE/ACTION op-kind
 *      boundary + adapter-kind belt-and-suspenders, rolling-window SOURCE-keyed spend
 *      reserve (reserve-before-every-pull, CEI), the multi-mode funding descriptor,
 *      Permit2/STANDING root pull + actual-delta metering, the SOLE-MOVER push-then-
 *      measure adapter feed, THREADED frame draw + measured-output frame credit, three
 *      revocation tiers, ERC-1271 root, native pause-refund, the controlled-callback flash
 *      frame (item 7 — adapter-as-receiver [F2] + opsHash-bound sub-group + transient
 *      expected-adapter pin + single-use slot + zero-on-exit [F1]; THREADED-only sub-ops),
 *      frame-sourced native value (item 8 — caller-first-then-frame draw, unwrap→send-ETH;
 *      native is caller/frame-supplied, unmetered), the on-chain hardening cluster (item 9 —
 *      reject PERMIT2 on recurring, MIN_RESET floor, cancelIntent authorized via the grant,
 *      staticcall+exact-magic 1271), and the gas-capped best-effort keeper tip with a
 *      dedicated sub-budget + reserve-then-refund (item 10). The PostConditionAdapter
 *      (item 11) ships as a standalone VERB_ASSERT adapter (revert-on-unmet post-check).
 *      REMAINING (marked `NOTE(freeze):`) — ERC-7739 nested-712 for the 1271 root branch;
 *      a root-sourced flash premium/shortfall top-up (deferred — strategies self-fund the
 *      repay today); and the Permit2 WITNESS typestring + per-chain golden vectors (item 12).
 *
 * Invariants preserved from the substrate (see DECISIONS.md ADR-0001):
 *   (1) PAUSE→resume: a failed gate returns before ANY state write; re-submitting the
 *       identical calldata reproduces the identical digest (atomic whole-intent no-op).
 *   (2) Recurring: maxRuns=0/N with cooldown>0 re-run each time the gate re-passes.
 *   (3) execute() is permissionless.  (4) EIP-712 domain = the execution chain.
 */
contract W3CashProcessor is EIP712 {
    using ECDSA for bytes32;
    using SafeERC20 for IERC20;

    /// @notice Canonical Permit2 (ISignatureTransfer) — the ONLY permit-pull path. Immutable.
    address public immutable permit2;
    /// @dev THREADED fundAmount sentinel: draw the whole frame balance (UniversalRouter CONTRACT_BALANCE).
    uint128 private constant CONTRACT_BALANCE = type(uint128).max;
    /// @dev Native-ETH sentinel for `Op.outToken` (Safe/1inch 0xEeee… convention). address(0) = "no
    /// output register". Native is caller (msg.value) / frame (unwrap output) supplied — never a root
    /// pull — so it is NOT metered against a root cap (item 8).
    address private constant NATIVE = 0xEeeeeEeeeEeEeeEeEeEeeEEEeeeeEeeeeeeeEEeE;
    /// @dev Minimum rolling-window period (item 9) — floors resetPeriod so it can't degrade to per-block.
    uint40 private constant MIN_RESET = 1 hours;

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
    error TooManyEntries();
    error NativeRefundFailed();
    error NotExpectedAdapter();  // flash callback caller != the transiently-pinned adapter
    error FlashSlotConsumed();   // a second flash sub-group was attempted in one frame
    error NestedFlash();         // a flash sub-op is itself a flash op (no nesting)
    error SubGroupMismatch();    // callback sub-group hash != the dispatch-bound hash
    error RepayShortfall();      // frame can't cover principal + premium at repay
    error InsufficientNative();  // op.value exceeds caller (msg.value) + frame native
    error ResetTooShort();       // TokenCap.resetPeriod below MIN_RESET (item 9)
    error PermitRecurring();     // PERMIT2 funding on a recurring intent (maxRuns != 1) (item 9)
    error NotAuthorized();       // cancelIntent caller is neither root nor sessionKey (item 9)

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
    uint32 public constant VERB_FLASH    = 1 << 6; // controlled flash sub-group initiator
    uint32 public constant VERB_ASSERT   = 1 << 7; // post-condition (delta/slippage) revert guard

    /// @dev Best-effort keeper-tip gas cap (RIDER-1 R1.2). Bounds a hostile tipToken's griefing.
    uint256 private constant TIP_GAS_CAP = 150_000;

    // EIP-712 typehashes. epoch is an explicit field of BOTH structs (Addendum C #9) so a
    // Tier-3 incrementEpoch() invalidates grant AND intent digests directly.
    bytes32 private constant SESSION_GRANT_TYPEHASH = keccak256(
        "SessionGrant(address root,address sessionKey,uint40 expiry,bytes32 policyHash,uint256 epoch,bytes32 salt)"
    );
    bytes32 private constant INTENT_TYPEHASH = keccak256(
        "Intent(bytes32 session,bytes32 opsHash,uint64 deadline,uint32 maxRuns,uint40 cooldown,uint256 epoch,bytes32 salt,address tipToken,uint128 tipAmount,address keeperOfRecord)"
    );
    /// @dev Permit2 witness type string — binds the SignatureTransfer to the intent digest.
    /// NOTE(freeze): frozen + covered by a per-chain golden vector before deploy (item 12).
    string private constant WITNESS_TYPESTRING =
        "bytes32 witness)TokenPermissions(address token,uint256 amount)";

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
        bytes32[] flashCodehashes;   // DEDICATED flash-adapter allowlist (Addendum D item 7)
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
        address     target;      // adapter (codehash-pinned)
        uint112     value;       // native forwarded (actions only)
        FundingMode funding;     // NONE for gates
        address     fundToken;   // token pulled/threaded (address(0)=native)
        uint128     fundAmount;  // input amount; == type(uint128).max + THREADED = draw-all (CONTRACT_BALANCE)
        address     outToken;    // single output register the adapter returns to the processor
        bytes       fundingParams; // PERMIT2: abi.encode(nonce,deadline,sig); else empty
        bytes       data;        // adapter calldata
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
    mapping(bytes32 => mapping(address => CapCursor)) public spentByToken;    // (grant, token) — actions AND tip share this
    mapping(bytes32 => IntentState) public intentState;                      // key = intent digest
    mapping(address => uint256) public epoch;                                // root cancel-ALL

    // Transient (EIP-1153) slots — flash frame + per-token frame-received ledger.
    uint256 private constant _T_DEPTH = uint256(keccak256("w3cash.v2.depth"));
    uint256 private constant _T_FLASH = uint256(keccak256("w3cash.v2.flashConsumed"));
    uint256 private constant _T_TOUCH_LEN = uint256(keccak256("w3cash.v2.touchLen"));
    bytes32 private constant _T_TOUCH_BASE = keccak256("w3cash.v2.touchToken");
    bytes32 private constant _T_FRAME_BASE = keccak256("w3cash.v2.frameReceived");
    uint256 private constant _T_FLASH_ADAPTER = uint256(keccak256("w3cash.v2.flashAdapter")); // pinned callback caller (F1)
    uint256 private constant _T_FLASH_CTX = uint256(keccak256("w3cash.v2.flashCtx"));         // keccak(root,subOps) bind (F1)

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

    constructor(address _permit2) EIP712("W3Cash", "2") {
        permit2 = _permit2;
    }

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
        uint256 boundary = _checkPolicyAndShape(policy, ops, it.maxRuns);

        // 5. GATES [0, boundary) — read-only; a failure PAUSES with ZERO writes (invariant 1).
        for (uint256 i = 0; i < boundary; ++i) {
            if (!IGateAdapter(ops[i].target).check(root, ops[i].data)) {
                _refundNative(msg.sender); // pause-path native refund (Addendum C #5)
                _exitFrame();              // zero transient
                emit WorkflowPaused(iDigest, i);
                return;                    // no SSTORE reached => resume-intact
            }
        }

        // 6. RESERVE per-intent counters BEFORE actions (CEI, substrate reserve-then-run).
        unchecked { s.executions += 1; }
        s.lastExecuted = uint40(block.timestamp);

        // 7. ACTIONS [boundary, len) — reserve-before-EVERY-pull, then SOLE-MOVER feed + run.
        // Native forwarded as op.value draws caller ETH (msg.value) FIRST, then frame native
        // (unwrap output) — never a root pull, so it is unmetered (item 8).
        uint256 callerNative = msg.value;
        for (uint256 i = boundary; i < ops.length; ++i) {
            Op calldata op = ops[i];
            if (op.value != 0) callerNative = _drawNative(op.value, callerNative);
            if (_adapterVerb(op.target) & VERB_FLASH != 0) {
                _runFlashOp(policy, op, root); // controlled-callback flash sub-group (item 7)
            } else {
                // Reserve (root-sourced) or draw (threaded) the input; returns the amount to push.
                uint256 fed = _reserveAndFund(gDigest, policy, op, root, iDigest);
                _feedAndRun(op, root, fed);
            }
        }

        // 8. RIDER-1 tip — clamp-and-meter against the DEDICATED tip sub-budget (Addendum C #8).
        _payTipMetered(gDigest, policy, it, root, iDigest);

        // 9. Sweep leftover native: unused caller ETH -> msg.sender; frame native (root's) -> root.
        if (callerNative > 0) _sweepNative(msg.sender, callerNative);
        uint256 frameNative = _frameGet(NATIVE);
        if (frameNative > 0) { _frameSet(NATIVE, 0); _sweepNative(root, frameNative); }

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

    /// @notice Per-intent selective cancel (sub-session granularity). Authorized by the session's
    /// root OR its session key; the grant binds the intent (it.session == gDigest) (item 9).
    function cancelIntent(SessionGrant calldata g, Intent calldata it) external {
        if (msg.sender != g.root && msg.sender != g.sessionKey) revert NotAuthorized();
        if (it.session != _grantDigest(g)) revert WrongSession();
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
            // staticcall only (view — a stateful/reentrant 1271 can't mutate here); require the
            // EXACT modern magic 0x1626ba7e, which also rejects the legacy 0x20c13b0b selector.
            // NOTE(freeze, item 9): wrap `digest` in ERC-7739 nested-712 before the 1271 call to
            // defeat cross-context replay of a naive raw-hash 1271 account, + a per-chain golden
            // vector proving a 7739-Safe accepts and a raw-hash mock (intentionally) does not.
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
    function _checkPolicyAndShape(Policy calldata p, Op[] calldata ops, uint32 maxRuns)
        internal
        view
        returns (uint256 boundary)
    {
        // Fail-closed length + fail-closed empties.
        if (p.allowedCodehashes.length > MAX_TARGETS || p.gateCodehashes.length > MAX_TARGETS
            || p.flashCodehashes.length > MAX_TARGETS || p.caps.length > MAX_CAPS) revert TooManyEntries();
        if (p.allowedCodehashes.length == 0 || p.verbMask == 0) revert PolicyDenied(); // deny-all defaults
        _assertCaps(p); // no-dup + MIN_RESET floor (item 9)

        bool seenAction = false;
        boundary = ops.length;
        for (uint256 i = 0; i < ops.length; ++i) {
            Op calldata op = ops[i];
            if (op.kind == OpKind.GATE) {
                if (seenAction) revert OpsNotOrdered();          // GATE after ACTION => reject (never mid-seq)
                if (_movesFunds(op)) revert GateMustNotMoveFunds();
                if (!_codehashIn(p.gateCodehashes, op.target)) revert PolicyDenied();
                if (_adapterKind(op.target) != KIND_GATE) revert PolicyDenied(); // belt-and-suspenders (fail-closed)
            } else {
                if (!seenAction) { seenAction = true; boundary = i; } // first ACTION marks the boundary
                uint32 v = _adapterVerb(op.target);                   // verb from the pinned adapter
                if (v & p.verbMask == 0) revert PolicyDenied();
                if (v & VERB_FLASH != 0) {
                    // Flash initiator: dedicated allowlist; principal comes from the pool, NOT root.
                    if (!_codehashIn(p.flashCodehashes, op.target)) revert PolicyDenied();
                    if (op.funding != FundingMode.NONE) revert PolicyDenied();
                    if (op.value != 0) revert PolicyDenied();             // no native on a flash op (audit L3)
                } else {
                    if (!_codehashIn(p.allowedCodehashes, op.target)) revert PolicyDenied();
                    if (_adapterKind(op.target) != KIND_ACTION) revert PolicyDenied();
                    // Root-sourced funded ops must name a capped ERC20 (native is caller/frame-supplied,
                    // never a root pull); a NONE-funded action must NOT name a fundToken (else it looks
                    // funded but is never reserved — an uncounted-pull footgun).
                    if (op.funding == FundingMode.PERMIT2 || op.funding == FundingMode.STANDING) {
                        if (op.fundToken == address(0) || op.fundToken == NATIVE) revert PolicyDenied(); // audit I2
                        if (op.funding == FundingMode.PERMIT2 && maxRuns != 1) revert PermitRecurring();  // one-shot only (item 9)
                        if (_capIndex(p, op.fundToken) == NONE) revert TokenNotCapped();
                    } else if (op.funding == FundingMode.NONE && op.fundToken != address(0)) {
                        revert PolicyDenied();
                    }
                }
                // Native op.value is caller/frame-supplied (never a root pull) => NOT cap-metered (item 8).
            }
        }
    }

    function _movesFunds(Op calldata op) internal pure returns (bool) {
        return op.funding != FundingMode.NONE || op.value != 0 || op.fundAmount != 0;
    }

    function _adapterVerb(address adapter) internal view returns (uint32) {
        // Verb is read from the pinned adapter's declared type, never from op bytes.
        try IActionAdapter(adapter).verb() returns (uint32 v) { return v; }
        catch { return 0; } // unknown => fail-closed (0 & mask == 0)
    }

    /// @dev Self-declared adapter kind (belt-and-suspenders over the codehash-pin). Both
    /// IGateAdapter and IActionAdapter share the adapterKind() selector. Fail-closed on absence.
    function _adapterKind(address adapter) internal view returns (uint8) {
        try IActionAdapter(adapter).adapterKind() returns (uint8 k) { return k; }
        catch { return 0; }
    }

    // ---------------------------------------------------------------------
    // Spend reserve — rolling-window, SOURCE-keyed, reserve-before-every-pull (CEI)
    // ---------------------------------------------------------------------
    /// @dev Provide the input for an ACTION op and return the amount now held by the processor and
    /// ready to push to the adapter. THREADED draws the per-frame ledger (never counts vs the cap);
    /// PERMIT2/STANDING reserve the cap BEFORE pulling root funds into the processor.
    function _reserveAndFund(bytes32 gDigest, Policy calldata p, Op calldata op, address root, bytes32 iDigest)
        internal
        returns (uint256 fed)
    {
        if (op.funding == FundingMode.THREADED) {
            // SOURCE-keyed exemption: frame funds were already metered at the producing root op.
            if (_depth() < 1) revert ThreadedOutsideFrame();
            uint256 avail = _frameGet(op.fundToken);
            uint256 draw = op.fundAmount == CONTRACT_BALANCE ? avail : op.fundAmount; // draw-all sentinel
            if (avail < draw) revert InsufficientFrameBalance();
            _frameSet(op.fundToken, avail - draw);
            return draw;
        }
        if (op.funding == FundingMode.NONE) return 0; // pure-native / no-input op

        // ROOT-sourced: reserve the cap (upper bound) RIGHT BEFORE the pull, then pull into self.
        _reserveCap(gDigest, p, op.fundToken, op.fundAmount, iDigest);
        fed = _pullRoot(op, root, iDigest); // measured received (FoT-safe): push exactly what arrived
    }

    /// @dev Pull `fundAmount` of `fundToken` from `root` INTO the processor and return the MEASURED
    /// received amount. STANDING = a standing approve-to-processor allowance; PERMIT2 = a witness-
    /// bound SignatureTransfer (processor is the sole spender). The adapter never pulls from root.
    function _pullRoot(Op calldata op, address root, bytes32 iDigest) internal returns (uint256 received) {
        IERC20 t = IERC20(op.fundToken);
        uint256 balBefore = t.balanceOf(address(this));
        if (op.funding == FundingMode.STANDING) {
            t.safeTransferFrom(root, address(this), op.fundAmount);
        } else {
            _permit2Pull(op, root, iDigest);
        }
        received = t.balanceOf(address(this)) - balBefore; // FoT-safe
    }

    /// @dev Witness-bound Permit2 SignatureTransfer, witness = the intent digest (binds the pull to
    /// THIS intent). fundingParams = abi.encode(nonce, deadline, signature).
    /// NOTE(freeze): the exact WITNESS_TYPESTRING is a per-chain release-gate golden vector (item 12).
    function _permit2Pull(Op calldata op, address root, bytes32 iDigest) internal {
        (uint256 nonce, uint256 deadline, bytes memory sig) =
            abi.decode(op.fundingParams, (uint256, uint256, bytes));
        ISignatureTransfer(permit2).permitWitnessTransferFrom(
            ISignatureTransfer.PermitTransferFrom({
                permitted: ISignatureTransfer.TokenPermissions({ token: op.fundToken, amount: op.fundAmount }),
                nonce: nonce,
                deadline: deadline
            }),
            ISignatureTransfer.SignatureTransferDetails({ to: address(this), requestedAmount: op.fundAmount }),
            root,
            iDigest, // witness
            WITNESS_TYPESTRING,
            sig
        );
    }

    /// @dev Push the fed input to the codehash-pinned adapter, run it, and credit the MEASURED output
    /// delta to the frame ledger for downstream THREADED ops. SOLE-MOVER: the adapter is a pure
    /// function of pushed tokens + value + data and cannot reach root funds.
    function _feedAndRun(Op memory op, address root, uint256 fed) internal {
        if (op.fundToken != address(0) && op.fundToken != NATIVE && fed > 0) {
            IERC20(op.fundToken).safeTransfer(op.target, fed);
        }
        // Output register: NATIVE => measure the native balance delta (unwrap output); an ERC20
        // outToken => measure its balanceOf delta; address(0) => no output register.
        uint256 outBefore;
        if (op.outToken == NATIVE) outBefore = address(this).balance;
        else if (op.outToken != address(0)) outBefore = IERC20(op.outToken).balanceOf(address(this));

        IActionAdapter(op.target).run{ value: op.value }(root, op.data);

        if (op.outToken == NATIVE) {
            // `received = balAfter + op.value - balBefore` (op.value left during the call).
            uint256 balAfter = address(this).balance + op.value;
            if (balAfter > outBefore) _frameCredit(NATIVE, balAfter - outBefore);
        } else if (op.outToken != address(0)) {
            uint256 outAfter = IERC20(op.outToken).balanceOf(address(this));
            if (outAfter > outBefore) _frameCredit(op.outToken, outAfter - outBefore);
        }
    }

    /// @dev Authorize op.value native: draw caller ETH first, then frame native (unwrap output).
    /// Returns the remaining caller balance. Reverts if neither source covers it.
    function _drawNative(uint256 v, uint256 callerNative) internal returns (uint256) {
        if (v <= callerNative) return callerNative - v;
        uint256 fromFrame = v - callerNative;
        uint256 avail = _frameGet(NATIVE);
        if (avail < fromFrame) revert InsufficientNative();
        _frameSet(NATIVE, avail - fromFrame);
        return 0;
    }

    /// @dev Draw a THREADED input from the frame ledger (never counts vs. the cap). Used inside the
    /// flash sub-group; the top-level path uses the THREADED branch of _reserveAndFund.
    function _drawThreaded(Op memory op) internal returns (uint256 fed) {
        uint256 avail = _frameGet(op.fundToken);
        fed = op.fundAmount == CONTRACT_BALANCE ? avail : op.fundAmount;
        if (avail < fed) revert InsufficientFrameBalance();
        _frameSet(op.fundToken, avail - fed);
    }

    // ---------------------------------------------------------------------
    // Controlled-callback flash frame (Addendum D item 7 — F1 + F2)
    // ---------------------------------------------------------------------

    /// @dev DISPATCH a flash op. The sub-group lives in op.data (so the signed opsHash binds it).
    /// We validate it, then pin the expected callback adapter + the sub-group hash transiently and
    /// call the ADAPTER (which owns all pool ABI — F2). Sub-ops are THREADED-only, so the re-entrant
    /// callback needs no policy/cap access.
    function _runFlashOp(Policy calldata policy, Op calldata op, address root) internal {
        (address asset, uint256 amount, bytes memory poolParams, bytes memory subOpsBytes) =
            abi.decode(op.data, (address, uint256, bytes, bytes));
        Op[] memory subOps = abi.decode(subOpsBytes, (Op[]));
        _checkSubGroup(policy, subOps);

        bytes memory cb = abi.encode(root, asset, amount, subOpsBytes);
        _tstore(_T_FLASH_ADAPTER, uint256(uint160(op.target))); // F1: pin the exact callback caller
        _tstore(_T_FLASH_CTX, uint256(keccak256(cb)));          // F1: bind the sub-group
        IFlashAdapter(op.target).initiateFlash(asset, amount, poolParams, cb);
        _tstore(_T_FLASH_ADAPTER, 0);
        _tstore(_T_FLASH_CTX, 0);
    }

    /// @dev Validate a flash sub-group at dispatch (policy in scope). Actions only, THREADED-only
    /// (frame-sourced), no nested flash, codehash-pinned + verb-allowed.
    function _checkSubGroup(Policy calldata p, Op[] memory subOps) internal view {
        uint256 n = subOps.length;
        if (n > MAX_TARGETS) revert TooManyEntries();
        for (uint256 i = 0; i < n; ++i) {
            Op memory s = subOps[i];
            if (s.kind != OpKind.ACTION) revert PolicyDenied();
            if (s.funding != FundingMode.THREADED) revert PolicyDenied();
            if (s.value != 0) revert PolicyDenied(); // no native forwarding inside a flash sub-group
            uint32 v = _adapterVerb(s.target);
            if (v & VERB_FLASH != 0) revert NestedFlash();
            if (v & p.verbMask == 0) revert PolicyDenied();
            if (!_codehashIn(p.allowedCodehashes, s.target)) revert PolicyDenied();
            if (_adapterKind(s.target) != KIND_ACTION) revert PolicyDenied();
        }
    }

    /// @notice The controlled flash callback — re-entered ONLY by the pinned flash adapter, ONCE,
    /// at depth 1. The adapter has already forwarded `amount` of `asset` to this processor.
    function onFlashLoan(address asset, uint256 amount, uint256 premium, bytes calldata cb)
        external
        returns (bytes4)
    {
        if (msg.sender != address(uint160(_tload(_T_FLASH_ADAPTER)))) revert NotExpectedAdapter(); // F1/F2
        if (_tload(_T_FLASH) != 0) revert FlashSlotConsumed();  // single sub-group per frame
        if (_tload(_T_DEPTH) != 1) revert Reentrancy();
        if (uint256(keccak256(cb)) != _tload(_T_FLASH_CTX)) revert SubGroupMismatch();
        _tstore(_T_FLASH, 1);   // consume the single-use slot
        _tstore(_T_DEPTH, 2);   // enter the sub-group frame

        (address root, address cbAsset, uint256 cbAmount, bytes memory subOpsBytes) =
            abi.decode(cb, (address, address, uint256, bytes));
        if (cbAsset != asset || cbAmount != amount) revert SubGroupMismatch();

        _frameCredit(asset, amount); // the borrowed principal now lives in the frame

        Op[] memory subOps = abi.decode(subOpsBytes, (Op[]));
        for (uint256 i = 0; i < subOps.length; ++i) {
            Op memory s = subOps[i];
            uint256 fed = _drawThreaded(s);       // reserve-before-pull is N/A: frame-sourced, cap-exempt
            _feedAndRun(s, root, fed);
        }

        // Repay principal + premium to the adapter, FULLY from the frame (self-funding strategy).
        uint256 repay = amount + premium;
        uint256 avail = _frameGet(asset);
        if (avail < repay) revert RepayShortfall();
        _frameSet(asset, avail - repay);
        IERC20(asset).safeTransfer(msg.sender, repay);

        _tstore(_T_DEPTH, 1); // exit the sub-group frame
        return this.onFlashLoan.selector;
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
        // Meter the tip against the SAME per-token cursor as actions so total outflow of tipToken
        // stays <= cap (audit M1 — no 2x doubling). The tip clamps to whatever room actions left.
        CapCursor storage c = spentByToken[gDigest][it.tipToken];
        if (cap.resetPeriod != 0 && block.timestamp >= uint256(c.lastReset) + cap.resetPeriod) {
            c.spent = 0; c.lastReset = uint40(block.timestamp);
        }
        uint256 room = cap.cap > c.spent ? cap.cap - c.spent : 0;
        uint256 pay = it.tipAmount < room ? it.tipAmount : room; // clamp
        if (pay == 0) { emit TipSkipped(iDigest, "NO_ROOM"); return; }
        c.spent = uint128(uint256(c.spent) + pay);                 // reserve (SHARED cap cursor — audit M1)
        address to = it.keeperOfRecord != address(0) ? it.keeperOfRecord : msg.sender;
        // Gas-capped, best-effort pull from root's standing tipToken allowance to the keeper. On any
        // failure (dry allowance, malicious/hostile token, OOG) REFUND the reserve and continue —
        // a failed tip degrades the intent to untipped, NEVER bricks the protective action.
        (bool ok, bytes memory ret) = it.tipToken.call{ gas: TIP_GAS_CAP }(
            abi.encodeWithSelector(IERC20.transferFrom.selector, root, to, pay)
        );
        // Tolerant success check: a non-standard return must NOT revert the whole protective intent
        // (audit M2). Decode as uint256 (never reverts on a bad bool) and require exactly 1; a short
        // return, a 32-byte non-`true` word, or an empty return-with-failure => not paid. Only a
        // 0-length return (success by convention) or a clean word==1 counts as paid.
        bool paid;
        if (ok) {
            if (ret.length == 0) paid = true;
            else if (ret.length == 32) paid = (abi.decode(ret, (uint256)) == 1);
        }
        if (!paid) {
            c.spent = uint128(uint256(c.spent) - pay);            // reserve-then-refund (item 10)
            emit TipSkipped(iDigest, "TRANSFER_FAILED");
            return;
        }
        emit TipPaid(iDigest, to, it.tipToken, pay);
    }

    // ---------------------------------------------------------------------
    // Policy helpers
    // ---------------------------------------------------------------------
    function _capIndex(Policy calldata p, address token) internal pure returns (uint256) {
        for (uint256 i = 0; i < p.caps.length; ++i) if (p.caps[i].token == token) return i;
        return NONE;
    }

    function _assertCaps(Policy calldata p) internal pure {
        for (uint256 i = 0; i < p.caps.length; ++i) {
            // MIN_RESET floor: a rolling window can't be set to per-block (item 9).
            uint40 rp = p.caps[i].resetPeriod;
            if (rp != 0 && rp < MIN_RESET) revert ResetTooShort();
            for (uint256 j = i + 1; j < p.caps.length; ++j)
                if (p.caps[i].token == p.caps[j].token) revert PolicyDenied();
        }
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
        _tstore(_T_FLASH_ADAPTER, 0);
        _tstore(_T_FLASH_CTX, 0);
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
interface IGateAdapter {
    function check(address initiator, bytes calldata data) external view returns (bool pass);
    function adapterKind() external view returns (uint8); // KIND_GATE
}

/// @notice Action adapter. Processor-fed (SOLE-MOVER: no adapter-side transferFrom(root)).
interface IActionAdapter {
    function adapterKind() external view returns (uint8); // KIND_ACTION
    function verb() external view returns (uint32);       // declared verb bitmask
    function run(address initiator, bytes calldata data) external payable returns (bytes memory);
}

/// @notice Uniswap Permit2 SignatureTransfer subset — the processor's only permit-pull path.
interface ISignatureTransfer {
    struct TokenPermissions { address token; uint256 amount; }
    struct PermitTransferFrom { TokenPermissions permitted; uint256 nonce; uint256 deadline; }
    struct SignatureTransferDetails { address to; uint256 requestedAmount; }

    function permitWitnessTransferFrom(
        PermitTransferFrom calldata permit,
        SignatureTransferDetails calldata transferDetails,
        address owner,
        bytes32 witness,
        string calldata witnessTypeString,
        bytes calldata signature
    ) external;
}

/// @notice Flash-loan adapter (adapter-as-receiver, F2). Owns ALL pool ABI. On the pool callback it
/// forwards the principal to the processor and calls processor.onFlashLoan(...), then repays the pool.
interface IFlashAdapter {
    function initiateFlash(address asset, uint256 amount, bytes calldata poolParams, bytes calldata callbackData) external;
}
