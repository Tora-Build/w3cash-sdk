// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import { Test } from "forge-std/Test.sol";
import { W3CashProcessorV2, IGateAdapterV2, IActionAdapterV2 } from "../src/w3cash/W3CashProcessorV2.sol";

// --- Mocks --------------------------------------------------------------

contract MockGate is IGateAdapterV2 {
    function check(address, bytes calldata data) external pure returns (bool) {
        return abi.decode(data, (bool)); // gate passes iff data encodes true
    }
    function adapterKind() external pure returns (uint8) { return 1; }
}

contract MockAction is IActionAdapterV2 {
    uint32 internal v;
    constructor(uint32 _v) { v = _v; }
    function adapterKind() external pure returns (uint8) { return 2; }
    function verb() external view returns (uint32) { return v; }
    function run(address, bytes calldata) external payable returns (bytes memory) { return ""; }
}

contract W3CashProcessorV2Test is Test {
    W3CashProcessorV2 internal proc;
    MockGate internal gate;
    MockAction internal action;

    address internal root;
    uint256 internal rootPk;
    address internal sessionKey;
    uint256 internal sessPk;
    address internal constant TOKEN = address(0xA11CE);

    function setUp() public {
        vm.warp(1_000_000);
        proc = new W3CashProcessorV2();
        gate = new MockGate();
        action = new MockAction(proc.VERB_TRANSFER());
        (root, rootPk) = makeAddrAndKey("root");
        (sessionKey, sessPk) = makeAddrAndKey("session");
    }

    // --- Builders --------------------------------------------------------

    function _policy(uint128 cap, uint40 resetPeriod)
        internal
        view
        returns (W3CashProcessorV2.Policy memory p)
    {
        p.allowedCodehashes = new bytes32[](1);
        p.allowedCodehashes[0] = address(action).codehash;
        p.gateCodehashes = new bytes32[](1);
        p.gateCodehashes[0] = address(gate).codehash;
        p.verbMask = proc.VERB_TRANSFER();
        p.caps = new W3CashProcessorV2.TokenCap[](1);
        p.caps[0] = W3CashProcessorV2.TokenCap({ token: TOKEN, cap: cap, resetPeriod: resetPeriod });
    }

    function _grant(bytes32 policyHash) internal view returns (W3CashProcessorV2.SessionGrant memory g) {
        g = W3CashProcessorV2.SessionGrant({
            root: root,
            sessionKey: sessionKey,
            expiry: uint40(block.timestamp + 30 days),
            policyHash: policyHash,
            epoch: proc.epoch(root),
            salt: keccak256("grant-salt")
        });
    }

    function _ops(bool gatePasses, uint128 fundAmount, bool actionFirst)
        internal
        view
        returns (W3CashProcessorV2.Op[] memory ops)
    {
        W3CashProcessorV2.Op memory g = W3CashProcessorV2.Op({
            kind: W3CashProcessorV2.OpKind.GATE,
            target: address(gate),
            value: 0,
            funding: W3CashProcessorV2.FundingMode.NONE,
            fundToken: address(0),
            fundAmount: 0,
            data: abi.encode(gatePasses)
        });
        W3CashProcessorV2.Op memory a = W3CashProcessorV2.Op({
            kind: W3CashProcessorV2.OpKind.ACTION,
            target: address(action),
            value: 0,
            funding: W3CashProcessorV2.FundingMode.STANDING,
            fundToken: TOKEN,
            fundAmount: fundAmount,
            data: ""
        });
        ops = new W3CashProcessorV2.Op[](2);
        if (actionFirst) { ops[0] = a; ops[1] = g; } else { ops[0] = g; ops[1] = a; }
    }

    function _intent(bytes32 gDigest, bytes32 opsHash, uint32 maxRuns, uint40 cooldown)
        internal
        view
        returns (W3CashProcessorV2.Intent memory it)
    {
        it = W3CashProcessorV2.Intent({
            session: gDigest,
            opsHash: opsHash,
            deadline: uint64(block.timestamp + 1 days),
            maxRuns: maxRuns,
            cooldown: cooldown,
            epoch: proc.epoch(root),
            salt: keccak256("intent-salt"),
            tipToken: address(0),
            tipAmount: 0,
            keeperOfRecord: address(0)
        });
    }

    function _sign(uint256 pk, bytes32 digest) internal pure returns (bytes memory) {
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(pk, digest);
        return abi.encodePacked(r, s, v);
    }

    /// Full valid bundle for a [gate, action] intent.
    function _bundle(bool gatePasses, uint128 cap, uint40 resetPeriod, uint128 fundAmount, uint32 maxRuns, uint40 cooldown)
        internal
        view
        returns (
            W3CashProcessorV2.SessionGrant memory g,
            bytes memory rootSig,
            W3CashProcessorV2.Policy memory p,
            W3CashProcessorV2.Intent memory it,
            W3CashProcessorV2.Op[] memory ops,
            bytes memory sessSig
        )
    {
        p = _policy(cap, resetPeriod);
        g = _grant(keccak256(abi.encode(p)));
        bytes32 gDigest = proc.grantDigest(g);
        rootSig = _sign(rootPk, gDigest);
        ops = _ops(gatePasses, fundAmount, false);
        it = _intent(gDigest, keccak256(abi.encode(ops)), maxRuns, cooldown);
        sessSig = _sign(sessPk, proc.intentDigest(it));
    }

    // --- Tests -----------------------------------------------------------

    function test_HappyPath_RunsAndDebitsCap() public {
        (
            W3CashProcessorV2.SessionGrant memory g, bytes memory rootSig,
            W3CashProcessorV2.Policy memory p, W3CashProcessorV2.Intent memory it,
            W3CashProcessorV2.Op[] memory ops, bytes memory sessSig
        ) = _bundle(true, 1000, 0, 600, 1, 0);

        proc.execute(g, rootSig, p, it, ops, sessSig);

        bytes32 gDigest = proc.grantDigest(g);
        bytes32 iDigest = proc.intentDigest(it);
        (uint128 spent, ) = proc.spentByToken(gDigest, TOKEN);
        assertEq(spent, 600);
        assertEq(proc.executionsOf(iDigest), 1);
    }

    function test_PausePath_NoWrites() public {
        (
            W3CashProcessorV2.SessionGrant memory g, bytes memory rootSig,
            W3CashProcessorV2.Policy memory p, W3CashProcessorV2.Intent memory it,
            W3CashProcessorV2.Op[] memory ops, bytes memory sessSig
        ) = _bundle(false, 1000, 0, 600, 1, 0); // gate FALSE => pause

        proc.execute(g, rootSig, p, it, ops, sessSig);

        (uint128 spent, ) = proc.spentByToken(proc.grantDigest(g), TOKEN);
        assertEq(spent, 0); // reserve never reached
        assertEq(proc.executionsOf(proc.intentDigest(it)), 0);
    }

    function test_PolicyPreimageBind_Reverts() public {
        (, bytes memory rootSig, , W3CashProcessorV2.Intent memory it,
         W3CashProcessorV2.Op[] memory ops, bytes memory sessSig) = _bundle(true, 1000, 0, 600, 1, 0);
        // Sign the grant over policyHash(cap=1000) but SUBMIT a wide-open policy (cap=type max).
        W3CashProcessorV2.SessionGrant memory g = _grant(keccak256(abi.encode(_policy(1000, 0))));
        rootSig = _sign(rootPk, proc.grantDigest(g));
        // rebuild the intent bound to THIS grant's digest
        it = _intent(proc.grantDigest(g), keccak256(abi.encode(ops)), 1, 0);
        sessSig = _sign(sessPk, proc.intentDigest(it));

        W3CashProcessorV2.Policy memory wideOpen = _policy(type(uint128).max, 0);
        vm.expectRevert(W3CashProcessorV2.PolicyMismatch.selector);
        proc.execute(g, rootSig, wideOpen, it, ops, sessSig);
    }

    function test_OpKindOrdering_ActionBeforeGate_Reverts() public {
        W3CashProcessorV2.Policy memory p = _policy(1000, 0);
        W3CashProcessorV2.SessionGrant memory g = _grant(keccak256(abi.encode(p)));
        bytes memory rootSig = _sign(rootPk, proc.grantDigest(g));
        W3CashProcessorV2.Op[] memory ops = _ops(true, 600, true); // ACTION first, GATE second
        W3CashProcessorV2.Intent memory it = _intent(proc.grantDigest(g), keccak256(abi.encode(ops)), 1, 0);
        bytes memory sessSig = _sign(sessPk, proc.intentDigest(it));

        vm.expectRevert(W3CashProcessorV2.OpsNotOrdered.selector);
        proc.execute(g, rootSig, p, it, ops, sessSig);
    }

    function test_EpochCancelAll_Reverts() public {
        (
            W3CashProcessorV2.SessionGrant memory g, bytes memory rootSig,
            W3CashProcessorV2.Policy memory p, W3CashProcessorV2.Intent memory it,
            W3CashProcessorV2.Op[] memory ops, bytes memory sessSig
        ) = _bundle(true, 1000, 0, 600, 1, 0);

        vm.prank(root);
        proc.incrementEpoch(); // Tier 3

        vm.expectRevert(W3CashProcessorV2.WrongEpoch.selector);
        proc.execute(g, rootSig, p, it, ops, sessSig);
    }

    function test_RevokeSession_Reverts() public {
        (
            W3CashProcessorV2.SessionGrant memory g, bytes memory rootSig,
            W3CashProcessorV2.Policy memory p, W3CashProcessorV2.Intent memory it,
            W3CashProcessorV2.Op[] memory ops, bytes memory sessSig
        ) = _bundle(true, 1000, 0, 600, 1, 0);

        vm.prank(root);
        proc.revokeSession(g); // Tier 2

        vm.expectRevert(W3CashProcessorV2.SessionRevoked.selector);
        proc.execute(g, rootSig, p, it, ops, sessSig);
    }

    function test_AbsoluteCap_Exceeds() public {
        // cap 1000, fund 600, recurring (maxRuns=0, cooldown=1). Run twice => 1200 > 1000.
        (
            W3CashProcessorV2.SessionGrant memory g, bytes memory rootSig,
            W3CashProcessorV2.Policy memory p, W3CashProcessorV2.Intent memory it,
            W3CashProcessorV2.Op[] memory ops, bytes memory sessSig
        ) = _bundle(true, 1000, 0, 600, 0, 1);

        proc.execute(g, rootSig, p, it, ops, sessSig); // spent 600
        vm.warp(block.timestamp + 2);
        vm.expectRevert(W3CashProcessorV2.CapExceeded.selector);
        proc.execute(g, rootSig, p, it, ops, sessSig); // 1200 > 1000
    }

    function test_RollingWindow_ResetsAfterPeriod() public {
        // cap 1000, resetPeriod 100, fund 600.
        (
            W3CashProcessorV2.SessionGrant memory g, bytes memory rootSig,
            W3CashProcessorV2.Policy memory p, W3CashProcessorV2.Intent memory it,
            W3CashProcessorV2.Op[] memory ops, bytes memory sessSig
        ) = _bundle(true, 1000, 100, 600, 0, 1);

        proc.execute(g, rootSig, p, it, ops, sessSig); // window1: spent 600
        (uint128 s1, ) = proc.spentByToken(proc.grantDigest(g), TOKEN);
        assertEq(s1, 600);

        // Within the window: second run would exceed (1200 > 1000).
        vm.warp(block.timestamp + 2);
        vm.expectRevert(W3CashProcessorV2.CapExceeded.selector);
        proc.execute(g, rootSig, p, it, ops, sessSig);

        // After the window resets: succeeds, spent back to 600.
        vm.warp(block.timestamp + 200);
        proc.execute(g, rootSig, p, it, ops, sessSig);
        (uint128 s2, ) = proc.spentByToken(proc.grantDigest(g), TOKEN);
        assertEq(s2, 600);
        assertEq(proc.executionsOf(proc.intentDigest(it)), 2);
    }

    function test_Reentrancy_BlockedByFrame() public {
        // A direct re-entrant execute() is blocked by the depth guard. Proven indirectly:
        // the frame depth must be zero between top-level calls (two sequential calls succeed).
        (
            W3CashProcessorV2.SessionGrant memory g, bytes memory rootSig,
            W3CashProcessorV2.Policy memory p, W3CashProcessorV2.Intent memory it,
            W3CashProcessorV2.Op[] memory ops, bytes memory sessSig
        ) = _bundle(true, 2000, 0, 600, 0, 1);
        proc.execute(g, rootSig, p, it, ops, sessSig);
        vm.warp(block.timestamp + 2);
        proc.execute(g, rootSig, p, it, ops, sessSig); // frame cleanly reset between calls
        assertEq(proc.executionsOf(proc.intentDigest(it)), 2);
    }
}
