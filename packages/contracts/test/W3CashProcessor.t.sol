// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import { Test } from "forge-std/Test.sol";
import { W3CashProcessor, IGateAdapter, IActionAdapter, ISignatureTransfer } from "../src/w3cash/W3CashProcessor.sol";
import { PostConditionAdapter } from "../src/w3cash/adapters/PostConditionAdapter.sol";
import { ECDSA as ECDSAlib } from "@openzeppelin/contracts/utils/cryptography/ECDSA.sol";

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

/// @dev Unwrap action: fed WETH (ERC20), sends native ETH back to the processor (outToken=NATIVE).
contract MockUnwrapAction is IActionAdapter {
    address public weth;
    constructor(address _weth) { weth = _weth; }
    function adapterKind() external pure returns (uint8) { return 2; }
    function verb() external pure returns (uint32) { return 1 << 3; } // VERB_WRAP
    function run(address, bytes calldata) external payable returns (bytes memory) {
        uint256 bal = MockERC20(weth).balanceOf(address(this));
        MockERC20(weth).transfer(address(0xdead), bal);   // "burn" the WETH
        (bool ok, ) = msg.sender.call{ value: bal }("");  // send equal native back to the processor
        require(ok, "unwrap send failed");
        return "";
    }
    receive() external payable {}
}

/// @dev Native-sink action: forwarded op.value; records what it received.
contract MockNativeSink is IActionAdapter {
    uint256 public received;
    function adapterKind() external pure returns (uint8) { return 2; }
    function verb() external pure returns (uint32) { return 1 << 0; } // VERB_TRANSFER
    function run(address, bytes calldata) external payable returns (bytes memory) {
        received += msg.value; return "";
    }
}

/// @dev Hostile token: transferFrom returns junk (10 bytes, not a clean 32-byte bool). A raw
/// abi.decode(ret,(bool)) would revert — the tolerant tip check (audit M2) must treat it as failure.
contract MockDirtyReturnToken {
    mapping(address => uint256) public balanceOf;
    mapping(address => mapping(address => uint256)) public allowance;
    function mint(address to, uint256 a) external { balanceOf[to] += a; }
    function approve(address s, uint256 a) external returns (bool) { allowance[msg.sender][s] = a; return true; }
    function transferFrom(address, address, uint256) external pure returns (bytes10) {
        return bytes10(0x00112233445566778899); // 10 bytes of junk
    }
}

interface IProcessorFlash {
    function onFlashLoan(address asset, uint256 amount, uint256 premium, bytes calldata cb) external returns (bytes4);
}

/// @dev Adapter-as-receiver flash mock: on initiateFlash (called by the processor) it forwards the
/// principal to the processor, runs the callback, and is repaid principal+premium (premium 0 here).
contract MockFlashAdapter {
    function verb() external pure returns (uint32) { return 1 << 6; } // VERB_FLASH
    function adapterKind() external pure returns (uint8) { return 2; }
    function initiateFlash(address asset, uint256 amount, bytes calldata, bytes calldata cb) external {
        MockERC20(asset).transfer(msg.sender, amount);              // principal → processor
        IProcessorFlash(msg.sender).onFlashLoan(asset, amount, 0, cb); // processor repays us inside
    }
}

/// @dev Item-12 proof mock: forwards principal then calls onFlashLoan TWICE — the single-use flash
/// slot must reject the second (FlashSlotConsumed).
contract MockDoubleFlashAdapter {
    function verb() external pure returns (uint32) { return 1 << 6; }
    function adapterKind() external pure returns (uint8) { return 2; }
    function initiateFlash(address asset, uint256 amount, bytes calldata, bytes calldata cb) external {
        MockERC20(asset).transfer(msg.sender, amount);
        IProcessorFlash(msg.sender).onFlashLoan(asset, amount, 0, cb);
        IProcessorFlash(msg.sender).onFlashLoan(asset, amount, 0, cb); // second => must revert
    }
}

/// @dev Minimal ERC-1271 smart-account root: validates a signature by recovering it (via OZ's
/// checker path, i.e. plain ECDSA over the passed EIP-712 digest) to its owner. Models a standard
/// EIP-712-aware smart account (e.g. Safe); an ERC-7739 account would additionally nest, which the
/// verifier supports by passing the opaque signature through.
contract MockSmartAccount {
    address public owner;
    constructor(address _owner) { owner = _owner; }
    function isValidSignature(bytes32 hash, bytes calldata sig) external view returns (bytes4) {
        (address rec, , ) = ECDSAlib.tryRecover(hash, sig);
        return rec == owner ? bytes4(0x1626ba7e) : bytes4(0xffffffff);
    }
}

/// @dev A 1271 account that returns the WRONG magic — must be rejected (BadRootSig).
contract MockBadAccount {
    function isValidSignature(bytes32, bytes calldata) external pure returns (bytes4) {
        return bytes4(0xdeadbeef);
    }
}

/// @dev Blind-audit F1 mock: a "flash adapter" that forwards NOTHING but claims a loan — the
/// measured-principal fix must credit 0 and revert RepayShortfall (no drain of resident balances).
contract MockPhantomFlashAdapter {
    function verb() external pure returns (uint32) { return 1 << 6; } // VERB_FLASH
    function adapterKind() external pure returns (uint8) { return 2; }
    function initiateFlash(address asset, uint256 amount, bytes calldata, bytes calldata cb) external {
        IProcessorFlash(msg.sender).onFlashLoan(asset, amount, 0, cb); // forwards nothing
    }
}

/// @dev Item-12 proof mock: a tip token whose transferFrom always reverts. The best-effort tip must
/// swallow it (never brick the protective action).
contract MockRevertingTipToken {
    mapping(address => uint256) public balanceOf;
    function mint(address to, uint256 a) external { balanceOf[to] += a; }
    function approve(address, uint256) external pure returns (bool) { return true; }
    function transferFrom(address, address, uint256) external pure returns (bool) { revert("hostile"); }
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
        p.flashCodehashes = new bytes32[](0);
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
        p.flashCodehashes = new bytes32[](0);
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
        uint40 win = 3600; // == MIN_RESET (1h)
        ( W3CashProcessor.SessionGrant memory g, bytes memory rootSig, W3CashProcessor.Policy memory p,
          W3CashProcessor.Intent memory it, W3CashProcessor.Op[] memory ops, bytes memory sessSig
        ) = _bundle(true, 1000, win, 600, 0, 60);
        proc.execute(g, rootSig, p, it, ops, sessSig);
        (uint128 s1, ) = proc.spentByToken(proc.grantDigest(g), TOKEN);
        assertEq(s1, 600);
        vm.warp(block.timestamp + 61);
        vm.expectRevert(W3CashProcessor.CapExceeded.selector); // within window: 1200 > 1000
        proc.execute(g, rootSig, p, it, ops, sessSig);
        vm.warp(block.timestamp + win + 1); // past the window: resets
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

    /// Item-7 golden vector: a flash of X=1000 with an asset cap of only 100 SUCCEEDS and debits the
    /// cap by 0 — the borrowed principal round-trips through the frame, never touching root or the cap.
    function test_FlashFrame_BorrowRoundTrips_CapUntouched() public {
        MockFlashAdapter flash = new MockFlashAdapter();
        MockSwapAction swap = new MockSwapAction(TOKEN, 1000); // round-trips the 1000 it is fed
        erc.mint(address(flash), 1000);                        // the pool's lendable inventory

        W3CashProcessor.Policy memory p;
        p.allowedCodehashes = new bytes32[](1);
        p.allowedCodehashes[0] = address(swap).codehash;
        p.gateCodehashes = new bytes32[](0);
        p.flashCodehashes = new bytes32[](1);
        p.flashCodehashes[0] = address(flash).codehash;
        p.verbMask = (1 << 6) | (1 << 1); // VERB_FLASH | VERB_SWAP
        p.caps = new W3CashProcessor.TokenCap[](1);
        p.caps[0] = W3CashProcessor.TokenCap({ token: TOKEN, cap: 100, resetPeriod: 0 }); // 100 << 1000

        W3CashProcessor.SessionGrant memory g = _grant(keccak256(abi.encode(p)));

        // sub-group: one THREADED op draws 1000 TOKEN and pushes it to the round-trip swap.
        W3CashProcessor.Op[] memory subOps = new W3CashProcessor.Op[](1);
        subOps[0] = W3CashProcessor.Op({
            kind: W3CashProcessor.OpKind.ACTION, target: address(swap), value: 0,
            funding: W3CashProcessor.FundingMode.THREADED, fundToken: TOKEN, fundAmount: 1000,
            outToken: TOKEN, fundingParams: "", data: ""
        });

        // flash op: verb VERB_FLASH, funding NONE; data = (asset, amount, poolParams, subOpsBytes).
        W3CashProcessor.Op[] memory ops = new W3CashProcessor.Op[](1);
        ops[0] = W3CashProcessor.Op({
            kind: W3CashProcessor.OpKind.ACTION, target: address(flash), value: 0,
            funding: W3CashProcessor.FundingMode.NONE, fundToken: address(0), fundAmount: 0,
            outToken: address(0), fundingParams: "",
            data: abi.encode(TOKEN, uint256(1000), bytes(""), abi.encode(subOps))
        });
        W3CashProcessor.Intent memory it = _intent(proc.grantDigest(g), keccak256(abi.encode(ops)), 1, 0);

        proc.execute(g, _sign(rootPk, proc.grantDigest(g)), p, it, ops, _sign(sessPk, proc.intentDigest(it)));

        (uint128 spent, ) = proc.spentByToken(proc.grantDigest(g), TOKEN);
        assertEq(spent, 0);                            // cap untouched — the flash never pulled root
        assertEq(erc.balanceOf(address(flash)), 1000); // pool made whole (repaid)
        assertEq(erc.balanceOf(address(proc)), 0);     // no residual held by the processor
        assertEq(proc.executionsOf(proc.intentDigest(it)), 1);
    }

    /// F1/F2: the flash callback is only reachable by the transiently-pinned adapter — an out-of-band
    /// caller (no flash in flight → pin is address(0)) is rejected.
    function test_FlashCallback_RejectsUnpinnedCaller() public {
        vm.expectRevert(W3CashProcessor.NotExpectedAdapter.selector);
        proc.onFlashLoan(TOKEN, 1000, 0, "");
    }

    // --- Item 8: native ETH ---------------------------------------------

    address internal constant NATIVE = 0xEeeeeEeeeEeEeeEeEeEeeEEEeeeeEeeeeeeeEEeE;

    /// Unwrap WETH → send ETH: op0 produces native into the frame, op1 forwards it as op.value.
    /// The old msg.value-conservation check would have bricked this (forwarded > msg.value==0).
    function test_Native_UnwrapThenSendEth() public {
        MockUnwrapAction unwrap = new MockUnwrapAction(TOKEN);
        MockNativeSink sink = new MockNativeSink();
        vm.deal(address(unwrap), 500); // native the unwrap returns

        W3CashProcessor.Policy memory p;
        p.allowedCodehashes = new bytes32[](2);
        p.allowedCodehashes[0] = address(unwrap).codehash;
        p.allowedCodehashes[1] = address(sink).codehash;
        p.gateCodehashes = new bytes32[](0);
        p.flashCodehashes = new bytes32[](0);
        p.verbMask = (1 << 3) | (1 << 0); // VERB_WRAP | VERB_TRANSFER
        p.caps = new W3CashProcessor.TokenCap[](1);
        p.caps[0] = W3CashProcessor.TokenCap({ token: TOKEN, cap: 1000, resetPeriod: 0 });

        W3CashProcessor.SessionGrant memory g = _grant(keccak256(abi.encode(p)));
        W3CashProcessor.Op[] memory ops = new W3CashProcessor.Op[](2);
        ops[0] = W3CashProcessor.Op({ // unwrap: WETH in (capped), native out
            kind: W3CashProcessor.OpKind.ACTION, target: address(unwrap), value: 0,
            funding: W3CashProcessor.FundingMode.STANDING, fundToken: TOKEN, fundAmount: 500,
            outToken: NATIVE, fundingParams: "", data: ""
        });
        ops[1] = W3CashProcessor.Op({ // send-ETH: forwards 500 native drawn from the frame
            kind: W3CashProcessor.OpKind.ACTION, target: address(sink), value: 500,
            funding: W3CashProcessor.FundingMode.NONE, fundToken: address(0), fundAmount: 0,
            outToken: address(0), fundingParams: "", data: ""
        });
        W3CashProcessor.Intent memory it = _intent(proc.grantDigest(g), keccak256(abi.encode(ops)), 1, 0);

        proc.execute(g, _sign(rootPk, proc.grantDigest(g)), p, it, ops, _sign(sessPk, proc.intentDigest(it)));

        assertEq(sink.received(), 500);            // native forwarded from the frame (msg.value was 0)
        (uint128 spent, ) = proc.spentByToken(proc.grantDigest(g), TOKEN);
        assertEq(spent, 500);                       // only the WETH input is cap-metered
        assertEq(address(proc).balance, 0);         // no native stranded
    }

    // --- Item 9: hardening cluster --------------------------------------

    function test_Item9_Permit2OnRecurring_Reverts() public {
        W3CashProcessor.Policy memory p = _policy(1000, 3600);
        W3CashProcessor.SessionGrant memory g = _grant(keccak256(abi.encode(p)));
        W3CashProcessor.Op[] memory ops = new W3CashProcessor.Op[](2);
        ops[0] = _gateOp(true);
        W3CashProcessor.Op memory a = _actionOp(W3CashProcessor.FundingMode.PERMIT2, 600);
        a.fundingParams = abi.encode(uint256(1), block.timestamp + 1 days, bytes("sig"));
        ops[1] = a;
        // recurring: maxRuns 0, cooldown 1 => PERMIT2 must be rejected (one-shot nonces only).
        W3CashProcessor.Intent memory it = _intent(proc.grantDigest(g), keccak256(abi.encode(ops)), 0, 1);
        bytes memory rootSig = _sign(rootPk, proc.grantDigest(g));
        bytes memory sessSig = _sign(sessPk, proc.intentDigest(it));
        vm.expectRevert(W3CashProcessor.PermitRecurring.selector);
        proc.execute(g, rootSig, p, it, ops, sessSig);
    }

    function test_Item9_MinResetFloor_Reverts() public {
        // resetPeriod 60s is below MIN_RESET (1h) => rejected.
        ( W3CashProcessor.SessionGrant memory g, bytes memory rootSig, W3CashProcessor.Policy memory p,
          W3CashProcessor.Intent memory it, W3CashProcessor.Op[] memory ops, bytes memory sessSig
        ) = _bundle(true, 1000, 60, 600, 0, 1);
        vm.expectRevert(W3CashProcessor.ResetTooShort.selector);
        proc.execute(g, rootSig, p, it, ops, sessSig);
    }

    function test_Item9_CancelIntent_RootCancels() public {
        ( W3CashProcessor.SessionGrant memory g, bytes memory rootSig, W3CashProcessor.Policy memory p,
          W3CashProcessor.Intent memory it, W3CashProcessor.Op[] memory ops, bytes memory sessSig
        ) = _bundle(true, 1000, 0, 600, 1, 0);
        vm.prank(root);
        proc.cancelIntent(g, it);
        vm.expectRevert(W3CashProcessor.Cancelled.selector);
        proc.execute(g, rootSig, p, it, ops, sessSig);
    }

    function test_Item9_CancelIntent_StrangerRejected() public {
        ( W3CashProcessor.SessionGrant memory g, , , W3CashProcessor.Intent memory it, , ) =
            _bundle(true, 1000, 0, 600, 1, 0);
        vm.prank(address(0xBAD));
        vm.expectRevert(W3CashProcessor.NotAuthorized.selector);
        proc.cancelIntent(g, it);
    }

    // --- Item 10: keeper tip --------------------------------------------

    /// Policy with a distinct tip-token cap alongside the action cap.
    function _policyWithTip(address tipToken, uint128 tipCap)
        internal view returns (W3CashProcessor.Policy memory p)
    {
        p.allowedCodehashes = new bytes32[](1);
        p.allowedCodehashes[0] = address(action).codehash;
        p.gateCodehashes = new bytes32[](1);
        p.gateCodehashes[0] = address(gate).codehash;
        p.flashCodehashes = new bytes32[](0);
        p.verbMask = proc.VERB_TRANSFER();
        p.caps = new W3CashProcessor.TokenCap[](2);
        p.caps[0] = W3CashProcessor.TokenCap({ token: TOKEN, cap: 1000, resetPeriod: 0 });
        p.caps[1] = W3CashProcessor.TokenCap({ token: tipToken, cap: tipCap, resetPeriod: 0 });
    }

    function _tipBundle(address tipToken, uint128 tipAmount, address keeper)
        internal view returns (
            W3CashProcessor.SessionGrant memory g, W3CashProcessor.Policy memory p,
            W3CashProcessor.Intent memory it, W3CashProcessor.Op[] memory ops
        )
    {
        p = _policyWithTip(tipToken, 100);
        g = _grant(keccak256(abi.encode(p)));
        ops = _ops(true, 600, false);
        it = W3CashProcessor.Intent({
            session: proc.grantDigest(g), opsHash: keccak256(abi.encode(ops)),
            deadline: uint64(block.timestamp + 1 days), maxRuns: 1, cooldown: 0,
            epoch: proc.epoch(root), salt: keccak256("tip-intent"),
            tipToken: tipToken, tipAmount: tipAmount, keeperOfRecord: keeper
        });
    }

    function test_Tip_PaysKeeper() public {
        MockERC20 tip = new MockERC20();
        tip.mint(root, 1e21);
        vm.prank(root); tip.approve(address(proc), type(uint256).max);
        address keeper = address(0xBEEF);
        ( W3CashProcessor.SessionGrant memory g, W3CashProcessor.Policy memory p,
          W3CashProcessor.Intent memory it, W3CashProcessor.Op[] memory ops ) =
            _tipBundle(address(tip), 50, keeper);
        proc.execute(g, _sign(rootPk, proc.grantDigest(g)), p, it, ops, _sign(sessPk, proc.intentDigest(it)));
        assertEq(tip.balanceOf(keeper), 50);
        (uint128 tipSpent, ) = proc.spentByToken(proc.grantDigest(g), address(tip));
        assertEq(tipSpent, 50);
    }

    function test_Tip_OpenBounty_PaysRelayer() public {
        MockERC20 tip = new MockERC20();
        tip.mint(root, 1e21);
        vm.prank(root); tip.approve(address(proc), type(uint256).max);
        ( W3CashProcessor.SessionGrant memory g, W3CashProcessor.Policy memory p,
          W3CashProcessor.Intent memory it, W3CashProcessor.Op[] memory ops ) =
            _tipBundle(address(tip), 50, address(0)); // open bounty => msg.sender
        proc.execute(g, _sign(rootPk, proc.grantDigest(g)), p, it, ops, _sign(sessPk, proc.intentDigest(it)));
        assertEq(tip.balanceOf(address(this)), 50); // this test contract is the relayer
    }

    /// A dry tip allowance must NOT brick the protective action: tip degrades, execution succeeds.
    function test_Tip_DryAllowance_DegradesNotBricks() public {
        MockERC20 tip = new MockERC20();
        tip.mint(root, 1e21); // funded but NO approval to the processor => transferFrom fails
        ( W3CashProcessor.SessionGrant memory g, W3CashProcessor.Policy memory p,
          W3CashProcessor.Intent memory it, W3CashProcessor.Op[] memory ops ) =
            _tipBundle(address(tip), 50, address(0xBEEF));
        proc.execute(g, _sign(rootPk, proc.grantDigest(g)), p, it, ops, _sign(sessPk, proc.intentDigest(it)));
        assertEq(tip.balanceOf(address(0xBEEF)), 0);        // tip not paid
        (uint128 tipSpent, ) = proc.spentByToken(proc.grantDigest(g), address(tip));
        assertEq(tipSpent, 0);                              // reserve refunded (item 10)
        assertEq(proc.executionsOf(proc.intentDigest(it)), 1); // action still ran
    }

    /// Audit M2: a tip token whose transferFrom returns non-standard (10-byte) junk must NOT brick
    /// the protective action — the tolerant decode treats it as a failed tip and continues.
    function test_Tip_DirtyReturn_DoesNotBrick() public {
        MockDirtyReturnToken tip = new MockDirtyReturnToken();
        tip.mint(root, 1e21);
        vm.prank(root); tip.approve(address(proc), type(uint256).max);
        ( W3CashProcessor.SessionGrant memory g, W3CashProcessor.Policy memory p,
          W3CashProcessor.Intent memory it, W3CashProcessor.Op[] memory ops ) =
            _tipBundle(address(tip), 50, address(0xBEEF));
        proc.execute(g, _sign(rootPk, proc.grantDigest(g)), p, it, ops, _sign(sessPk, proc.intentDigest(it)));
        (uint128 tipSpent, ) = proc.spentByToken(proc.grantDigest(g), address(tip));
        assertEq(tipSpent, 0);                                  // reserve refunded (dirty return => not paid)
        assertEq(proc.executionsOf(proc.intentDigest(it)), 1);  // protective action still ran
    }

    /// Audit M1: tip shares the action cap cursor — total outflow of a token stays <= cap.
    function test_Tip_SharesActionCap() public {
        // action spends 600 of TOKEN; a tip of 50 in TOKEN shares the same cap(1000) cursor.
        address keeper = address(0xBEEF);
        W3CashProcessor.Policy memory p = _policy(1000, 0);
        W3CashProcessor.SessionGrant memory g = _grant(keccak256(abi.encode(p)));
        W3CashProcessor.Op[] memory ops = _ops(true, 600, false);
        W3CashProcessor.Intent memory it = W3CashProcessor.Intent({
            session: proc.grantDigest(g), opsHash: keccak256(abi.encode(ops)),
            deadline: uint64(block.timestamp + 1 days), maxRuns: 1, cooldown: 0,
            epoch: proc.epoch(root), salt: keccak256("tip-shared"),
            tipToken: TOKEN, tipAmount: 50, keeperOfRecord: keeper
        });
        proc.execute(g, _sign(rootPk, proc.grantDigest(g)), p, it, ops, _sign(sessPk, proc.intentDigest(it)));
        (uint128 spent, ) = proc.spentByToken(proc.grantDigest(g), TOKEN);
        assertEq(spent, 650);              // 600 action + 50 tip, ONE shared cursor (not 2x)
        assertEq(erc.balanceOf(keeper), 50);
    }

    // --- Item 11: PostConditionAdapter (integration) --------------------

    /// A post-condition ACTION that fails reverts the WHOLE intent (no partial execution).
    function test_PostCondition_UnmetRevertsWholeIntent() public {
        PostConditionAdapter pc = new PostConditionAdapter();
        // Assert erc.balanceOf(root) >= a huge threshold that is FALSE => the intent must revert.
        bytes memory checkData = abi.encode(
            TOKEN,
            abi.encodeWithSignature("balanceOf(address)", root),
            uint8(3), // OP_GTE
            type(uint256).max
        );

        W3CashProcessor.Policy memory p;
        p.allowedCodehashes = new bytes32[](2);
        p.allowedCodehashes[0] = address(action).codehash;
        p.allowedCodehashes[1] = address(pc).codehash;
        p.gateCodehashes = new bytes32[](1);
        p.gateCodehashes[0] = address(gate).codehash;
        p.flashCodehashes = new bytes32[](0);
        p.verbMask = proc.VERB_TRANSFER() | proc.VERB_ASSERT();
        p.caps = new W3CashProcessor.TokenCap[](1);
        p.caps[0] = W3CashProcessor.TokenCap({ token: TOKEN, cap: 1000, resetPeriod: 0 });

        W3CashProcessor.SessionGrant memory g = _grant(keccak256(abi.encode(p)));
        W3CashProcessor.Op[] memory ops = new W3CashProcessor.Op[](3);
        ops[0] = _gateOp(true);
        ops[1] = _actionOp(W3CashProcessor.FundingMode.STANDING, 600);
        ops[2] = W3CashProcessor.Op({ // post-condition: asserts an impossible balance => revert
            kind: W3CashProcessor.OpKind.ACTION, target: address(pc), value: 0,
            funding: W3CashProcessor.FundingMode.NONE, fundToken: address(0), fundAmount: 0,
            outToken: address(0), fundingParams: "", data: checkData
        });
        W3CashProcessor.Intent memory it = _intent(proc.grantDigest(g), keccak256(abi.encode(ops)), 1, 0);
        bytes memory rootSig = _sign(rootPk, proc.grantDigest(g));
        bytes memory sessSig = _sign(sessPk, proc.intentDigest(it));

        uint256 rootBefore = erc.balanceOf(root);
        vm.expectRevert(); // PostConditionFailed bubbles up, unwinding the whole intent
        proc.execute(g, rootSig, p, it, ops, sessSig);
        assertEq(erc.balanceOf(root), rootBefore);              // the prior action's pull was unwound
        assertEq(proc.executionsOf(proc.intentDigest(it)), 0);  // nothing committed
    }

    // ======================================================================
    // Item 12 — release-gate security proofs + conformance vectors
    // ======================================================================

    /// Flash-frame proof 1: THREADED draws ONLY the per-frame ledger, never balanceOf. A balance
    /// donated straight to the processor is NOT drawable — closes cross-intent balance confusion.
    function test_Item12_Threading_CannotDrawDonatedBalance() public {
        MockERC20 donated = new MockERC20();
        donated.mint(address(proc), 1_000_000); // donate directly to the processor (not via a frame)
        MockAction sink = new MockAction(1 << 1); // VERB_SWAP

        W3CashProcessor.Policy memory p;
        p.allowedCodehashes = new bytes32[](1);
        p.allowedCodehashes[0] = address(sink).codehash;
        p.gateCodehashes = new bytes32[](0);
        p.flashCodehashes = new bytes32[](0);
        p.verbMask = 1 << 1;
        p.caps = new W3CashProcessor.TokenCap[](0);

        W3CashProcessor.SessionGrant memory g = _grant(keccak256(abi.encode(p)));
        W3CashProcessor.Op[] memory ops = new W3CashProcessor.Op[](1);
        ops[0] = W3CashProcessor.Op({ // THREADED draw of the donated token — frame ledger is empty
            kind: W3CashProcessor.OpKind.ACTION, target: address(sink), value: 0,
            funding: W3CashProcessor.FundingMode.THREADED, fundToken: address(donated), fundAmount: 1_000_000,
            outToken: address(0), fundingParams: "", data: ""
        });
        W3CashProcessor.Intent memory it = _intent(proc.grantDigest(g), keccak256(abi.encode(ops)), 1, 0);
        bytes memory rootSig = _sign(rootPk, proc.grantDigest(g));
        bytes memory sessSig = _sign(sessPk, proc.intentDigest(it));

        vm.expectRevert(W3CashProcessor.InsufficientFrameBalance.selector);
        proc.execute(g, rootSig, p, it, ops, sessSig);
    }

    /// Flash-frame proof: exactly ONE sub-group per frame — a second onFlashLoan reverts.
    function test_Item12_Flash_DoubleSubGroup_Blocked() public {
        MockDoubleFlashAdapter flash = new MockDoubleFlashAdapter();
        MockSwapAction swap = new MockSwapAction(TOKEN, 1000);
        erc.mint(address(flash), 2000);

        W3CashProcessor.Policy memory p;
        p.allowedCodehashes = new bytes32[](1);
        p.allowedCodehashes[0] = address(swap).codehash;
        p.gateCodehashes = new bytes32[](0);
        p.flashCodehashes = new bytes32[](1);
        p.flashCodehashes[0] = address(flash).codehash;
        p.verbMask = (1 << 6) | (1 << 1);
        p.caps = new W3CashProcessor.TokenCap[](1);
        p.caps[0] = W3CashProcessor.TokenCap({ token: TOKEN, cap: 100, resetPeriod: 0 });

        W3CashProcessor.SessionGrant memory g = _grant(keccak256(abi.encode(p)));
        W3CashProcessor.Op[] memory subOps = new W3CashProcessor.Op[](1);
        subOps[0] = W3CashProcessor.Op({
            kind: W3CashProcessor.OpKind.ACTION, target: address(swap), value: 0,
            funding: W3CashProcessor.FundingMode.THREADED, fundToken: TOKEN, fundAmount: 1000,
            outToken: TOKEN, fundingParams: "", data: ""
        });
        W3CashProcessor.Op[] memory ops = new W3CashProcessor.Op[](1);
        ops[0] = W3CashProcessor.Op({
            kind: W3CashProcessor.OpKind.ACTION, target: address(flash), value: 0,
            funding: W3CashProcessor.FundingMode.NONE, fundToken: address(0), fundAmount: 0,
            outToken: address(0), fundingParams: "",
            data: abi.encode(TOKEN, uint256(1000), bytes(""), abi.encode(subOps))
        });
        W3CashProcessor.Intent memory it = _intent(proc.grantDigest(g), keccak256(abi.encode(ops)), 1, 0);
        bytes memory rootSig = _sign(rootPk, proc.grantDigest(g));
        bytes memory sessSig = _sign(sessPk, proc.intentDigest(it));

        vm.expectRevert(W3CashProcessor.FlashSlotConsumed.selector);
        proc.execute(g, rootSig, p, it, ops, sessSig);
    }

    /// Flash-frame proof: a sub-op cannot draw more than the borrowed principal (frame-bounded).
    function test_Item12_Flash_SubOpCannotExceedPrincipal() public {
        MockFlashAdapter flash = new MockFlashAdapter();
        MockSwapAction swap = new MockSwapAction(TOKEN, 1); // output irrelevant; the draw reverts first
        erc.mint(address(flash), 1000);

        W3CashProcessor.Policy memory p;
        p.allowedCodehashes = new bytes32[](1);
        p.allowedCodehashes[0] = address(swap).codehash;
        p.gateCodehashes = new bytes32[](0);
        p.flashCodehashes = new bytes32[](1);
        p.flashCodehashes[0] = address(flash).codehash;
        p.verbMask = (1 << 6) | (1 << 1);
        p.caps = new W3CashProcessor.TokenCap[](1);
        p.caps[0] = W3CashProcessor.TokenCap({ token: TOKEN, cap: 100, resetPeriod: 0 });

        W3CashProcessor.SessionGrant memory g = _grant(keccak256(abi.encode(p)));
        W3CashProcessor.Op[] memory subOps = new W3CashProcessor.Op[](1);
        subOps[0] = W3CashProcessor.Op({ // draw 2000 from a 1000 principal => InsufficientFrameBalance
            kind: W3CashProcessor.OpKind.ACTION, target: address(swap), value: 0,
            funding: W3CashProcessor.FundingMode.THREADED, fundToken: TOKEN, fundAmount: 2000,
            outToken: TOKEN, fundingParams: "", data: ""
        });
        W3CashProcessor.Op[] memory ops = new W3CashProcessor.Op[](1);
        ops[0] = W3CashProcessor.Op({
            kind: W3CashProcessor.OpKind.ACTION, target: address(flash), value: 0,
            funding: W3CashProcessor.FundingMode.NONE, fundToken: address(0), fundAmount: 0,
            outToken: address(0), fundingParams: "",
            data: abi.encode(TOKEN, uint256(1000), bytes(""), abi.encode(subOps))
        });
        W3CashProcessor.Intent memory it = _intent(proc.grantDigest(g), keccak256(abi.encode(ops)), 1, 0);
        bytes memory rootSig = _sign(rootPk, proc.grantDigest(g));
        bytes memory sessSig = _sign(sessPk, proc.intentDigest(it));

        vm.expectRevert(W3CashProcessor.InsufficientFrameBalance.selector);
        proc.execute(g, rootSig, p, it, ops, sessSig);
    }

    /// A hostile tip token whose transferFrom reverts must NOT brick the protective action.
    function test_Item12_Tip_RevertingToken_DoesNotBrick() public {
        MockRevertingTipToken tip = new MockRevertingTipToken();
        tip.mint(root, 1e21);
        ( W3CashProcessor.SessionGrant memory g, W3CashProcessor.Policy memory p,
          W3CashProcessor.Intent memory it, W3CashProcessor.Op[] memory ops ) =
            _tipBundle(address(tip), 50, address(0xBEEF));
        proc.execute(g, _sign(rootPk, proc.grantDigest(g)), p, it, ops, _sign(sessPk, proc.intentDigest(it)));
        assertEq(proc.executionsOf(proc.intentDigest(it)), 1); // action ran; tip skipped
    }

    /// Conformance: EIP-712 domain binds to the EXECUTION chain — the SAME intent yields a DIFFERENT
    /// digest on a different chainId (C2 cross-chain separation). This is what the per-chain golden
    /// vectors assert.
    function test_Item12_Conf_DomainSeparationByChainId() public {
        ( , , , W3CashProcessor.Intent memory it, , ) = _bundle(true, 1000, 0, 600, 1, 0);
        bytes32 d1 = proc.intentDigest(it);
        vm.chainId(1952);
        bytes32 d2 = proc.intentDigest(it);
        assertTrue(d1 != d2, "digest must differ across chains");
    }

    /// Flash-frame proof 3 (transient zero-on-exit): after a flash intent completes, the frame
    /// ledger is zeroed — a LATER intent in the SAME tx cannot draw a phantom leftover balance
    /// (SIR.trading's $355k unzeroed-TSTORE class). Two top-level execute()s share one tx's
    /// transient storage; the second's THREADED draw must fail because the frame was cleaned.
    function test_Item12_Frame_ZeroedAfterFlash() public {
        // --- intent 1: a working flash round-trip (credits then drains the frame) ---
        MockFlashAdapter flash = new MockFlashAdapter();
        MockSwapAction swap = new MockSwapAction(TOKEN, 1000);
        erc.mint(address(flash), 1000);
        W3CashProcessor.Policy memory p1;
        p1.allowedCodehashes = new bytes32[](1); p1.allowedCodehashes[0] = address(swap).codehash;
        p1.gateCodehashes = new bytes32[](0);
        p1.flashCodehashes = new bytes32[](1); p1.flashCodehashes[0] = address(flash).codehash;
        p1.verbMask = (1 << 6) | (1 << 1);
        p1.caps = new W3CashProcessor.TokenCap[](1);
        p1.caps[0] = W3CashProcessor.TokenCap({ token: TOKEN, cap: 100, resetPeriod: 0 });
        W3CashProcessor.SessionGrant memory g1 = _grant(keccak256(abi.encode(p1)));
        W3CashProcessor.Op[] memory sub = new W3CashProcessor.Op[](1);
        sub[0] = W3CashProcessor.Op({ kind: W3CashProcessor.OpKind.ACTION, target: address(swap), value: 0,
            funding: W3CashProcessor.FundingMode.THREADED, fundToken: TOKEN, fundAmount: 1000, outToken: TOKEN, fundingParams: "", data: "" });
        W3CashProcessor.Op[] memory ops1 = new W3CashProcessor.Op[](1);
        ops1[0] = W3CashProcessor.Op({ kind: W3CashProcessor.OpKind.ACTION, target: address(flash), value: 0,
            funding: W3CashProcessor.FundingMode.NONE, fundToken: address(0), fundAmount: 0, outToken: address(0),
            fundingParams: "", data: abi.encode(TOKEN, uint256(1000), bytes(""), abi.encode(sub)) });
        W3CashProcessor.Intent memory it1 = _intent(proc.grantDigest(g1), keccak256(abi.encode(ops1)), 1, 0);
        proc.execute(g1, _sign(rootPk, proc.grantDigest(g1)), p1, it1, ops1, _sign(sessPk, proc.intentDigest(it1)));

        // --- intent 2 (SAME tx): a THREADED draw of TOKEN must revert — frame was zeroed ---
        MockAction sink = new MockAction(1 << 1);
        W3CashProcessor.Policy memory p2;
        p2.allowedCodehashes = new bytes32[](1); p2.allowedCodehashes[0] = address(sink).codehash;
        p2.gateCodehashes = new bytes32[](0); p2.flashCodehashes = new bytes32[](0);
        p2.verbMask = 1 << 1; p2.caps = new W3CashProcessor.TokenCap[](0);
        W3CashProcessor.SessionGrant memory g2 = _grant(keccak256(abi.encode(p2)));
        W3CashProcessor.Op[] memory ops2 = new W3CashProcessor.Op[](1);
        ops2[0] = W3CashProcessor.Op({ kind: W3CashProcessor.OpKind.ACTION, target: address(sink), value: 0,
            funding: W3CashProcessor.FundingMode.THREADED, fundToken: TOKEN, fundAmount: 500, outToken: address(0), fundingParams: "", data: "" });
        W3CashProcessor.Intent memory it2 = _intent(proc.grantDigest(g2), keccak256(abi.encode(ops2)), 1, 0);
        bytes memory rs2 = _sign(rootPk, proc.grantDigest(g2));
        bytes memory ss2 = _sign(sessPk, proc.intentDigest(it2));
        vm.expectRevert(W3CashProcessor.InsufficientFrameBalance.selector);
        proc.execute(g2, rs2, p2, it2, ops2, ss2);
    }

    /// Conformance: the Permit2 witness type string is canonical (item 12). A real Permit2
    /// SignatureTransfer must be built with this exact suffix; the witness is the intent digest.
    function test_Item12_Conf_Permit2WitnessTypestring() public view {
        assertEq(
            proc.permit2WitnessTypeString(),
            "bytes32 witness)TokenPermissions(address token,uint256 amount)"
        );
    }

    // --- ERC-7739 / ERC-1271 smart-account root -------------------------

    /// A smart-account (ERC-1271) root is accepted via SignatureChecker: the account validates the
    /// domain-bound grant digest against its owner. (An ERC-7739 account additionally nests; the
    /// verifier supports it by passing the opaque signature through unchanged.)
    function test_ERC1271_SmartAccountRoot_Accepts() public {
        (address owner, uint256 ownerPk) = makeAddrAndKey("sa-owner");
        MockSmartAccount sa = new MockSmartAccount(owner);
        // Fund the smart-account root + approve the processor for the STANDING pull.
        erc.mint(address(sa), 1e24);
        vm.prank(address(sa)); erc.approve(address(proc), type(uint256).max);

        W3CashProcessor.Policy memory p = _policy(1000, 0);
        W3CashProcessor.SessionGrant memory g = W3CashProcessor.SessionGrant({
            root: address(sa), sessionKey: sessionKey, expiry: uint40(block.timestamp + 30 days),
            policyHash: keccak256(abi.encode(p)), epoch: proc.epoch(address(sa)), salt: keccak256("sa-grant")
        });
        W3CashProcessor.Op[] memory ops = _ops(true, 600, false);
        W3CashProcessor.Intent memory it = W3CashProcessor.Intent({
            session: proc.grantDigest(g), opsHash: keccak256(abi.encode(ops)),
            deadline: uint64(block.timestamp + 1 days), maxRuns: 1, cooldown: 0,
            epoch: proc.epoch(address(sa)), salt: keccak256("sa-intent"),
            tipToken: address(0), tipAmount: 0, keeperOfRecord: address(0)
        });
        // Root "signature" = the account OWNER's ECDSA over the grant digest (what the account checks).
        bytes memory rootSig = _sign(ownerPk, proc.grantDigest(g));
        bytes memory sessSig = _sign(sessPk, proc.intentDigest(it));

        proc.execute(g, rootSig, p, it, ops, sessSig);
        assertEq(proc.executionsOf(proc.intentDigest(it)), 1);
        assertEq(erc.balanceOf(address(action)), 600); // funds pulled from the smart-account root
    }

    /// A 1271 account returning the wrong magic value is rejected (BadRootSig).
    function test_ERC1271_WrongMagic_Rejected() public {
        MockBadAccount bad = new MockBadAccount();
        W3CashProcessor.Policy memory p = _policy(1000, 0);
        W3CashProcessor.SessionGrant memory g = W3CashProcessor.SessionGrant({
            root: address(bad), sessionKey: sessionKey, expiry: uint40(block.timestamp + 30 days),
            policyHash: keccak256(abi.encode(p)), epoch: proc.epoch(address(bad)), salt: keccak256("bad")
        });
        W3CashProcessor.Op[] memory ops = _ops(true, 600, false);
        W3CashProcessor.Intent memory it = W3CashProcessor.Intent({
            session: proc.grantDigest(g), opsHash: keccak256(abi.encode(ops)),
            deadline: uint64(block.timestamp + 1 days), maxRuns: 1, cooldown: 0,
            epoch: proc.epoch(address(bad)), salt: keccak256("bad-i"),
            tipToken: address(0), tipAmount: 0, keeperOfRecord: address(0)
        });
        bytes memory sessSig = _sign(sessPk, proc.intentDigest(it));
        vm.expectRevert(W3CashProcessor.BadRootSig.selector);
        proc.execute(g, "0x", p, it, ops, sessSig);
    }

    // ======================================================================
    // Blind-audit fixes — regression tests
    // ======================================================================

    /// F1 (HIGH): a phantom flash callback (forwards nothing, claims `amount`) must NOT drain the
    /// processor's resident ERC20 — the measured-principal fix credits 0 → RepayShortfall.
    function test_AuditF1_PhantomFlash_CannotDrainResident() public {
        MockPhantomFlashAdapter flash = new MockPhantomFlashAdapter();
        erc.mint(address(proc), 5000); // resident balance the attacker wants to steal

        W3CashProcessor.Policy memory p;
        p.allowedCodehashes = new bytes32[](1); p.allowedCodehashes[0] = address(action).codehash;
        p.gateCodehashes = new bytes32[](0);
        p.flashCodehashes = new bytes32[](1); p.flashCodehashes[0] = address(flash).codehash;
        p.verbMask = 1 << 6; // VERB_FLASH
        p.caps = new W3CashProcessor.TokenCap[](0);
        W3CashProcessor.SessionGrant memory g = _grant(keccak256(abi.encode(p)));
        W3CashProcessor.Op[] memory ops = new W3CashProcessor.Op[](1);
        ops[0] = W3CashProcessor.Op({
            kind: W3CashProcessor.OpKind.ACTION, target: address(flash), value: 0,
            funding: W3CashProcessor.FundingMode.NONE, fundToken: address(0), fundAmount: 0,
            outToken: address(0), fundingParams: "",
            data: abi.encode(TOKEN, uint256(5000), bytes(""), abi.encode(new W3CashProcessor.Op[](0)))
        });
        W3CashProcessor.Intent memory it = _intent(proc.grantDigest(g), keccak256(abi.encode(ops)), 1, 0);
        bytes memory rootSig = _sign(rootPk, proc.grantDigest(g));
        bytes memory sessSig = _sign(sessPk, proc.intentDigest(it));

        vm.expectRevert(W3CashProcessor.RepayShortfall.selector);
        proc.execute(g, rootSig, p, it, ops, sessSig);
        assertEq(erc.balanceOf(address(proc)), 5000); // resident balance untouched
    }

    /// F2 (LOW): ERC20 frame residue a THREADED op under-draws is swept to root (not stranded, and
    /// no resident pool remains to be harvested).
    function test_AuditF2_Erc20FrameResidue_SweptToRoot() public {
        MockERC20 erc2 = new MockERC20();
        MockSwapAction swap = new MockSwapAction(address(erc2), 1000); // outputs 1000 erc2
        erc2.mint(address(swap), 1000);
        MockAction sink = new MockAction(1 << 1);

        W3CashProcessor.Policy memory p;
        p.allowedCodehashes = new bytes32[](2);
        p.allowedCodehashes[0] = address(swap).codehash; p.allowedCodehashes[1] = address(sink).codehash;
        p.gateCodehashes = new bytes32[](0); p.flashCodehashes = new bytes32[](0);
        p.verbMask = 1 << 1;
        p.caps = new W3CashProcessor.TokenCap[](1);
        p.caps[0] = W3CashProcessor.TokenCap({ token: TOKEN, cap: 1000, resetPeriod: 0 });
        W3CashProcessor.SessionGrant memory g = _grant(keccak256(abi.encode(p)));

        W3CashProcessor.Op[] memory ops = new W3CashProcessor.Op[](2);
        ops[0] = W3CashProcessor.Op({ kind: W3CashProcessor.OpKind.ACTION, target: address(swap), value: 0,
            funding: W3CashProcessor.FundingMode.STANDING, fundToken: TOKEN, fundAmount: 600, outToken: address(erc2), fundingParams: "", data: "" });
        ops[1] = W3CashProcessor.Op({ kind: W3CashProcessor.OpKind.ACTION, target: address(sink), value: 0,
            funding: W3CashProcessor.FundingMode.THREADED, fundToken: address(erc2), fundAmount: 600, outToken: address(0), fundingParams: "", data: "" }); // draws only 600 of 1000
        W3CashProcessor.Intent memory it = _intent(proc.grantDigest(g), keccak256(abi.encode(ops)), 1, 0);

        proc.execute(g, _sign(rootPk, proc.grantDigest(g)), p, it, ops, _sign(sessPk, proc.intentDigest(it)));
        assertEq(erc2.balanceOf(root), 400);            // 1000 output - 600 drawn = 400 swept to root
        assertEq(erc2.balanceOf(address(proc)), 0);     // nothing stranded
    }

    /// F5 (LOW): a THREADED op that names native as its fundToken is rejected at the shape check
    /// (would otherwise zero the native ledger without forwarding → stranded ETH).
    function test_AuditF5_ThreadedNativeFundToken_Rejected() public {
        MockAction sink = new MockAction(1 << 1);
        W3CashProcessor.Policy memory p;
        p.allowedCodehashes = new bytes32[](1); p.allowedCodehashes[0] = address(sink).codehash;
        p.gateCodehashes = new bytes32[](0); p.flashCodehashes = new bytes32[](0);
        p.verbMask = 1 << 1; p.caps = new W3CashProcessor.TokenCap[](0);
        W3CashProcessor.SessionGrant memory g = _grant(keccak256(abi.encode(p)));
        W3CashProcessor.Op[] memory ops = new W3CashProcessor.Op[](1);
        ops[0] = W3CashProcessor.Op({ kind: W3CashProcessor.OpKind.ACTION, target: address(sink), value: 0,
            funding: W3CashProcessor.FundingMode.THREADED, fundToken: NATIVE, fundAmount: 1, outToken: address(0), fundingParams: "", data: "" });
        W3CashProcessor.Intent memory it = _intent(proc.grantDigest(g), keccak256(abi.encode(ops)), 1, 0);
        bytes memory rootSig = _sign(rootPk, proc.grantDigest(g));
        bytes memory sessSig = _sign(sessPk, proc.intentDigest(it));
        vm.expectRevert(W3CashProcessor.PolicyDenied.selector);
        proc.execute(g, rootSig, p, it, ops, sessSig);
    }

    /// F8: a leaked session key can NO LONGER permanently cancel a protective intent (root-only).
    function test_AuditF8_SessionKeyCannotCancel() public {
        ( W3CashProcessor.SessionGrant memory g, , , W3CashProcessor.Intent memory it, , ) =
            _bundle(true, 1000, 0, 600, 1, 0);
        vm.prank(sessionKey);
        vm.expectRevert(W3CashProcessor.NotAuthorized.selector);
        proc.cancelIntent(g, it);
    }

    /// The ERC-7739 support surface is exposed (domain via ERC-5267 + contents types).
    function test_ERC7739_SupportSurface() public view {
        (, string memory name, string memory version, , , , ) = proc.eip712Domain();
        assertEq(name, "W3Cash");
        assertEq(version, "2");
        assertEq(bytes(proc.grantContentsType()).length > 0, true);
        assertEq(bytes(proc.intentContentsType()).length > 0, true);
    }
}
