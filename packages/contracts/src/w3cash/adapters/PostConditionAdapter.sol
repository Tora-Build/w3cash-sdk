// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

/**
 * @title PostConditionAdapter
 * @notice A post-action assertion guard for W3Cash Design C intents (ADR-0001 Addendum D item 11).
 *
 * @dev The strict GATE-before-ACTION op ordering forecloses a *gate* after actions, so the
 * post-condition ships as an ACTION whose unmet behavior is a HARD REVERT (not a pause) — the
 * on-chain slippage / MEV safety net. Placed after an action op, it staticcalls a target view and
 * reverts the WHOLE intent if the reading fails the comparison, e.g. "after the swap, assert my
 * WETH balanceOf >= minOut" or "assert the pool price is still within band".
 *
 * SOLE-MOVER: this adapter moves NO funds and holds no state. It is fed nothing, forwards no value,
 * and returns no output. It declares KIND_ACTION + VERB_ASSERT so the processor's shape check and
 * verb mask admit it; the intent's Policy must pin its codehash and include VERB_ASSERT.
 *
 * `run.data` = abi.encode(address target, bytes callData, uint8 operator, uint256 expected).
 * The staticcall result's first 32-byte word is compared (uint256). Operators match QueryAdapter.
 */
contract PostConditionAdapter {
    uint8  public constant KIND_ACTION = 2;
    uint32 public constant VERB_ASSERT = 1 << 7;

    // Operators (identical to QueryAdapter).
    uint8 public constant OP_LT  = 0; // <
    uint8 public constant OP_GT  = 1; // >
    uint8 public constant OP_LTE = 2; // <=
    uint8 public constant OP_GTE = 3; // >=
    uint8 public constant OP_EQ  = 4; // ==
    uint8 public constant OP_NEQ = 5; // !=

    error PostConditionFailed(uint256 actual, uint8 operator, uint256 expected);
    error StaticcallFailed();
    error InvalidOperator();

    function adapterKind() external pure returns (uint8) { return KIND_ACTION; }
    function verb() external pure returns (uint32) { return VERB_ASSERT; }

    /// @notice Assert a post-condition; revert the intent if it fails. Moves no funds.
    function run(address, bytes calldata data) external payable returns (bytes memory) {
        (address target, bytes memory callData, uint8 operator, uint256 expected) =
            abi.decode(data, (address, bytes, uint8, uint256));
        (bool ok, bytes memory ret) = target.staticcall(callData);
        if (!ok || ret.length < 32) revert StaticcallFailed();
        uint256 actual = abi.decode(ret, (uint256));
        if (!_compare(actual, operator, expected)) {
            revert PostConditionFailed(actual, operator, expected);
        }
        return "";
    }

    function _compare(uint256 a, uint8 op, uint256 e) internal pure returns (bool) {
        if (op == OP_LT)  return a <  e;
        if (op == OP_GT)  return a >  e;
        if (op == OP_LTE) return a <= e;
        if (op == OP_GTE) return a >= e;
        if (op == OP_EQ)  return a == e;
        if (op == OP_NEQ) return a != e;
        revert InvalidOperator();
    }
}
