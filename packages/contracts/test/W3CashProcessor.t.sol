// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import { Test } from "forge-std/Test.sol";
import { W3CashProcessor, IGateAdapter, IActionAdapter, ISignatureTransfer } from "../src/w3cash/W3CashProcessor.sol";

// --- Mocks --------------------------------------------------------------

contract MockERC20 {
    mapping(address => uint256) public balanceOf;
    mapping(address => mapping(address => uint256)) public allowance;
    function mint(address to, uint256 a) external { balanceOf[to] += a; }
    function approve(address s, uint256 a) external returns (bool) { allowance[msg.sender][s] = a; return true; }
    function transfer(address to, uint256 a) external returns (bool) {
        balanceOf[msg.sender] -= a; balanceOf[to] += a; return true;
    }
    function transferFrom(address f, address to, uint256 a) external returns (bool) {
        uint256 al = allowance[f][msg.sender];
        if (al != type(uint256).max) allowance[f][msg.sender] = al - a;
        balanceOf[f] -= a; balanceOf[to] += a; return true;
    }
}

/// @dev Trusting Permit2 mock: ignores sig/witness, moves the permitted amount owner→to.
contract MockPermit2 {
    function permitWitnessTransferFrom(
        ISignatureTransfer.PermitTransferFrom calldata permit,
        ISignatureTransfer.SignatureTransferDetails calldata details,
        address owner,
        bytes32,
        string calldata,
        bytes calldata
    ) external {
        MockERC20(permit.permitted.token).transferFrom(owner, details.to, details.requestedAmount);
    }
}

contract MockGate is IGateAdapter {
    function check(address, bytes calldata data) external pure returns (bool) {
        return abi.decode(data, (bool));
    }
    function adapterKind() external pure returns (uint8) { return 1; }
}

/// @dev Sink action: receives the pushed input, does nothing with it (holds it).
contract MockAction is IActionAdapter {
    uint32 internal v;
    constructor(uint32 _v) { v = _v; }
    function adapterKind() external pure returns (uint8) { return 2; }
    function verb() external view returns (uint32) { return v; }
    function run(address, bytes calldata) external payable returns (bytes memory) { return ""; }
}

/// @dev Swap action: on run, sends `out` of `outToken` back to the processor (msg.sender) — the
/// output the processor measures + credits to the frame for a downstream THREADED op.
contract MockSwapAction is IActionAdapter {
    address public outToken;
    uint256 public out;
    constructor(address _outToken, uint256 _out) { outToken = _outToken; out = _out; }
    function adapterKind() external pure returns (uint8) { return 2; }
    function verb() external pure returns (uint32) { return 1 << 1; } // VERB_SWAP
    function run(address, bytes calldata) external payable returns (bytes memory) {
        MockERC20(outToken).transfer(msg.sender, out);
        return "";
    }
}

contract W3CashProcessorTest is Test {
    W3CashProcessor internal proc;
    MockPermit2 internal permit2;
    MockGate internal gate;
    MockAction internal action;
    MockERC20 internal erc;

    address internal root;
    uint256 internal rootPk;
    address internal sessionKey;
    uint256 internal sessPk;
    address internal TOKEN;

    function setUp() public {
        vm.warp(1_000_000);
        permit2 = new MockPermit2();
        proc = new W3CashProcessor(address(permit2));
        gate = new MockGate();
        action = new MockAction(proc.VERB_TRANSFER());
        erc = new MockERC20();
        TOKEN = address(erc);
        (root, rootPk) = makeAddrAndKey("root");
        (sessionKey, sessPk) = makeAddrAndKey("session");
        // Fund root + standing approvals (processor for STANDING, permit2 for PERMIT2).
        erc.mint(root, 1e24);
        vm.startPrank(root);
        erc.approve(address(proc), type(uint256).max);
        erc.approve(address(permit2), type(uint256).max);
        vm.stopPrank();
    }

    // --- Builders --------------------------------------------------------

    function _policy(uint128 cap, uint40 resetPeriod)
        internal view returns (W3CashProcessor.Policy memory p)
    {
        p.allowedCodehashes = new bytes32[](1);
        p.allowedCodehashes[0] = address(action).codehash;
        p.gateCodehashes = new bytes32[](1);
        p.gateCodehashes[0] = address(gate).codehash;
        p.verbMask = proc.VERB_TRANSFER();
        p.caps = new W3CashProcessor.TokenCap[](1);
        p.caps[0] = W3CashProcessor.TokenCap({ token: TOKEN, cap: cap, resetPeriod: resetPeriod });
    }

    function _grant(bytes32 policyHash) internal view returns (W3CashProcessor.SessionGrant memory g) {
        g = W3CashProcessor.SessionGrant({
            root: root, sessionKey: sessionKey,
            expiry: uint40(block.timestamp + 30 days),
            policyHash: policyHash, epoch: proc.epoch(root), salt: keccak256("grant-salt")
        });
    }

    function _gateOp(bool pass) internal view returns (W3CashProcessor.Op memory) {
        return W3CashProcessor.Op({
            kind: W3CashProcessor.OpKind.GATE, target: address(gate), value: 0,
            funding: W3CashProcessor.FundingMode.NONE, fundToken: address(0), fundAmount: 0,
            outToken: address(0), fundingParams: "", data: abi.encode(pass)
        });
    }

    function _actionOp(W3CashProcessor.FundingMode mode, uint128 fundAmount) internal view returns (W3CashProcessor.Op memory) {
        return W3CashProcessor.Op({
            kind: W3CashProcessor.OpKind.ACTION, target: address(action), value: 0,
            funding: mode, fundToken: mode == W3CashProcessor.FundingMode.NONE ? address(0) : TOKEN,
            fundAmount: fundAmount, outToken: address(0), fundingParams: "", data: ""
        });
    }

    function _ops(bool gatePasses, uint128 fundAmount, bool actionFirst)
        internal view returns (W3CashProcessor.Op[] memory ops)
    {
        W3CashProcessor.Op memory g = _gateOp(gatePasses);
        W3CashProcessor.Op memory a = _actionOp(W3CashProcessor.FundingMode.STANDING, fundAmount);
        ops = new W3CashProcessor.Op[](2);
        if (actionFirst) { ops[0] = a; ops[1] = g; } else { ops[0] = g; ops[1] = a; }
    }

    function _intent(bytes32 gDigest, bytes32 opsHash, uint32 maxRuns, uint40 cooldown)
        internal view returns (W3CashProcessor.Intent memory it)
    {
        it = W3CashProcessor.Intent({
            session: gDigest, opsHash: opsHash, deadline: uint64(block.timestamp + 1 days),
            maxRuns: maxRuns, cooldown: cooldown, epoch: proc.epoch(root), salt: keccak256("intent-salt"),
            tipToken: address(0), tipAmount: 0, keeperOfRecord: address(0)
        });
    }

    function _sign(uint256 pk, bytes32 digest) internal pure returns (bytes memory) {
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(pk, digest);
        return abi.encodePacked(r, s, v);
    }

    function _bundle(bool gatePasses, uint128 cap, uint40 resetPeriod, uint128 fundAmount, uint32 maxRuns, uint40 cooldown)
        internal view returns (
            W3CashProcessor.SessionGrant memory g, bytes memory rootSig, W3CashProcessor.Policy memory p,
            W3CashProcessor.Intent memory it, W3CashProcessor.Op[] memory ops, bytes memory sessSig
        )
    {
        p = _policy(cap, resetPeriod);
        g = _grant(keccak256(abi.encode(p)));
        rootSig = _sign(rootPk, proc.grantDigest(g));
        ops = _ops(gatePasses, fundAmount, false);
        it = _intent(proc.grantDigest(g), keccak256(abi.encode(ops)), maxRuns, cooldown);
        sessSig = _sign(sessPk, proc.intentDigest(it));
    }

    // --- Tests -----------------------------------------------------------

    function test_HappyPath_RunsAndDebitsCap() public {
        ( W3CashProcessor.SessionGrant memory g, bytes memory rootSig, W3CashProcessor.Policy memory p,
          W3CashProcessor.Intent memory it, W3CashProcessor.Op[] memory ops, bytes memory sessSig
        ) = _bundle(true, 1000, 0, 600, 1, 0);
        proc.execute(g, rootSig, p, it, ops, sessSig);
        (uint128 spent, ) = proc.spentByToken(proc.grantDigest(g), TOKEN);
        assertEq(spent, 600);
        assertEq(proc.executionsOf(proc.intentDigest(it)), 1);
    }

    /// SOLE-MOVER feed: the pull comes from ROOT (into the processor), then the processor pushes
    /// the input to the ADAPTER — the adapter never touches root's balance.
    function test_SoleMoverFeed_MovesRootToAdapter() public {
        ( W3CashProcessor.SessionGrant memory g, bytes memory rootSig, W3CashProcessor.Policy memory p,
          W3CashProcessor.Intent memory it, W3CashProcessor.Op[] memory ops, bytes memory sessSig
        ) = _bundle(true, 1000, 0, 600, 1, 0);
        uint256 rootBefore = erc.balanceOf(root);
        proc.execute(g, rootSig, p, it, ops, sessSig);
        assertEq(erc.balanceOf(root), rootBefore - 600);   // pulled from root
        assertEq(erc.balanceOf(address(action)), 600);      // pushed to the adapter
        assertEq(erc.balanceOf(address(proc)), 0);          // processor holds nothing after
    }

    function test_Permit2Funding_PullsViaPermit2() public {
        W3CashProcessor.Policy memory p = _policy(1000, 0);
        W3CashProcessor.SessionGrant memory g = _grant(keccak256(abi.encode(p)));
        // gate + a PERMIT2-funded action; fundingParams carries (nonce, deadline, sig).
        W3CashProcessor.Op[] memory ops = new W3CashProcessor.Op[](2);
        ops[0] = _gateOp(true);
        W3CashProcessor.Op memory a = _actionOp(W3CashProcessor.FundingMode.PERMIT2, 600);
        a.fundingParams = abi.encode(uint256(1), block.timestamp + 1 days, bytes("sig"));
        ops[1] = a;
        W3CashProcessor.Intent memory it = _intent(proc.grantDigest(g), keccak256(abi.encode(ops)), 1, 0);
        proc.execute(
            g, _sign(rootPk, proc.grantDigest(g)), p, it, ops, _sign(sessPk, proc.intentDigest(it))
        );
        (uint128 spent, ) = proc.spentByToken(proc.grantDigest(g), TOKEN);
        assertEq(spent, 600);
        assertEq(erc.balanceOf(address(action)), 600); // pulled via permit2, pushed to adapter
    }

    /// Threading: op0 (swap) outputs TOKEN2 to the processor → op1 draws it from the frame (cap-exempt).
    function test_Threading_SwapOutputFundsNextOp() public {
        MockERC20 erc2 = new MockERC20();
        MockSwapAction swap = new MockSwapAction(address(erc2), 500);
        erc2.mint(address(swap), 500); // the swap's output inventory
        MockAction sink = new MockAction(1 << 1); // VERB_SWAP so it passes the mask

        W3CashProcessor.Policy memory p;
        p.allowedCodehashes = new bytes32[](2);
        p.allowedCodehashes[0] = address(swap).codehash;
        p.allowedCodehashes[1] = address(sink).codehash;
        p.gateCodehashes = new bytes32[](1);
        p.gateCodehashes[0] = address(gate).codehash;
        p.verbMask = 1 << 1; // VERB_SWAP
        p.caps = new W3CashProcessor.TokenCap[](1);
        p.caps[0] = W3CashProcessor.TokenCap({ token: TOKEN, cap: 1000, resetPeriod: 0 });

        W3CashProcessor.SessionGrant memory g = _grant(keccak256(abi.encode(p)));

        W3CashProcessor.Op[] memory ops = new W3CashProcessor.Op[](2);
        // op0: STANDING 600 TOKEN in, outputs TOKEN2 to the processor
        ops[0] = W3CashProcessor.Op({
            kind: W3CashProcessor.OpKind.ACTION, target: address(swap), value: 0,
            funding: W3CashProcessor.FundingMode.STANDING, fundToken: TOKEN, fundAmount: 600,
            outToken: address(erc2), fundingParams: "", data: ""
        });
        // op1: THREADED 500 TOKEN2 (drawn from the frame), pushed to the sink — never hits the cap
        ops[1] = W3CashProcessor.Op({
            kind: W3CashProcessor.OpKind.ACTION, target: address(sink), value: 0,
            funding: W3CashProcessor.FundingMode.THREADED, fundToken: address(erc2), fundAmount: 500,
            outToken: address(0), fundingParams: "", data: ""
        });
        W3CashProcessor.Intent memory it = _intent(proc.grantDigest(g), keccak256(abi.encode(ops)), 1, 0);

        proc.execute(g, _sign(rootPk, proc.grantDigest(g)), p, it, ops, _sign(sessPk, proc.intentDigest(it)));

        (uint128 spentToken, ) = proc.spentByToken(proc.grantDigest(g), TOKEN);
        assertEq(spentToken, 600);               // only the root-sourced input counts
        (uint128 spentToken2, ) = proc.spentByToken(proc.grantDigest(g), address(erc2));
        assertEq(spentToken2, 0);                // threaded funds are cap-exempt
        assertEq(erc2.balanceOf(address(sink)), 500); // threaded output reached the sink
    }

    function test_PausePath_NoWrites() public {
        ( W3CashProcessor.SessionGrant memory g, bytes memory rootSig, W3CashProcessor.Policy memory p,
          W3CashProcessor.Intent memory it, W3CashProcessor.Op[] memory ops, bytes memory sessSig
        ) = _bundle(false, 1000, 0, 600, 1, 0);
        uint256 rootBefore = erc.balanceOf(root);
        proc.execute(g, rootSig, p, it, ops, sessSig);
        (uint128 spent, ) = proc.spentByToken(proc.grantDigest(g), TOKEN);
        assertEq(spent, 0);
        assertEq(erc.balanceOf(root), rootBefore); // no pull on the pause path
        assertEq(proc.executionsOf(proc.intentDigest(it)), 0);
    }

    function test_PolicyPreimageBind_Reverts() public {
        (, bytes memory rootSig, , W3CashProcessor.Intent memory it,
         W3CashProcessor.Op[] memory ops, bytes memory sessSig) = _bundle(true, 1000, 0, 600, 1, 0);
        W3CashProcessor.SessionGrant memory g = _grant(keccak256(abi.encode(_policy(1000, 0))));
        rootSig = _sign(rootPk, proc.grantDigest(g));
        it = _intent(proc.grantDigest(g), keccak256(abi.encode(ops)), 1, 0);
        sessSig = _sign(sessPk, proc.intentDigest(it));
        W3CashProcessor.Policy memory wideOpen = _policy(type(uint128).max, 0);
        vm.expectRevert(W3CashProcessor.PolicyMismatch.selector);
        proc.execute(g, rootSig, wideOpen, it, ops, sessSig);
    }

    function test_OpKindOrdering_ActionBeforeGate_Reverts() public {
        W3CashProcessor.Policy memory p = _policy(1000, 0);
        W3CashProcessor.SessionGrant memory g = _grant(keccak256(abi.encode(p)));
        W3CashProcessor.Op[] memory ops = _ops(true, 600, true);
        W3CashProcessor.Intent memory it = _intent(proc.grantDigest(g), keccak256(abi.encode(ops)), 1, 0);
        bytes memory rootSig = _sign(rootPk, proc.grantDigest(g)); // precompute before expectRevert
        bytes memory sessSig = _sign(sessPk, proc.intentDigest(it));
        vm.expectRevert(W3CashProcessor.OpsNotOrdered.selector);
        proc.execute(g, rootSig, p, it, ops, sessSig);
    }

    function test_EpochCancelAll_Reverts() public {
        ( W3CashProcessor.SessionGrant memory g, bytes memory rootSig, W3CashProcessor.Policy memory p,
          W3CashProcessor.Intent memory it, W3CashProcessor.Op[] memory ops, bytes memory sessSig
        ) = _bundle(true, 1000, 0, 600, 1, 0);
        vm.prank(root); proc.incrementEpoch();
        vm.expectRevert(W3CashProcessor.WrongEpoch.selector);
        proc.execute(g, rootSig, p, it, ops, sessSig);
    }

    function test_RevokeSession_Reverts() public {
        ( W3CashProcessor.SessionGrant memory g, bytes memory rootSig, W3CashProcessor.Policy memory p,
          W3CashProcessor.Intent memory it, W3CashProcessor.Op[] memory ops, bytes memory sessSig
        ) = _bundle(true, 1000, 0, 600, 1, 0);
        vm.prank(root); proc.revokeSession(g);
        vm.expectRevert(W3CashProcessor.SessionRevoked.selector);
        proc.execute(g, rootSig, p, it, ops, sessSig);
    }

    function test_AbsoluteCap_Exceeds() public {
        ( W3CashProcessor.SessionGrant memory g, bytes memory rootSig, W3CashProcessor.Policy memory p,
          W3CashProcessor.Intent memory it, W3CashProcessor.Op[] memory ops, bytes memory sessSig
        ) = _bundle(true, 1000, 0, 600, 0, 1);
        proc.execute(g, rootSig, p, it, ops, sessSig);
        vm.warp(block.timestamp + 2);
        vm.expectRevert(W3CashProcessor.CapExceeded.selector);
        proc.execute(g, rootSig, p, it, ops, sessSig);
    }

    function test_RollingWindow_ResetsAfterPeriod() public {
        ( W3CashProcessor.SessionGrant memory g, bytes memory rootSig, W3CashProcessor.Policy memory p,
          W3CashProcessor.Intent memory it, W3CashProcessor.Op[] memory ops, bytes memory sessSig
        ) = _bundle(true, 1000, 100, 600, 0, 1);
        proc.execute(g, rootSig, p, it, ops, sessSig);
        (uint128 s1, ) = proc.spentByToken(proc.grantDigest(g), TOKEN);
        assertEq(s1, 600);
        vm.warp(block.timestamp + 2);
        vm.expectRevert(W3CashProcessor.CapExceeded.selector);
        proc.execute(g, rootSig, p, it, ops, sessSig);
        vm.warp(block.timestamp + 200);
        proc.execute(g, rootSig, p, it, ops, sessSig);
        (uint128 s2, ) = proc.spentByToken(proc.grantDigest(g), TOKEN);
        assertEq(s2, 600);
        assertEq(proc.executionsOf(proc.intentDigest(it)), 2);
    }

    function test_Reentrancy_BlockedByFrame() public {
        ( W3CashProcessor.SessionGrant memory g, bytes memory rootSig, W3CashProcessor.Policy memory p,
          W3CashProcessor.Intent memory it, W3CashProcessor.Op[] memory ops, bytes memory sessSig
        ) = _bundle(true, 2000, 0, 600, 0, 1);
        proc.execute(g, rootSig, p, it, ops, sessSig);
        vm.warp(block.timestamp + 2);
        proc.execute(g, rootSig, p, it, ops, sessSig);
        assertEq(proc.executionsOf(proc.intentDigest(it)), 2);
    }
}
