// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import { Test } from "forge-std/Test.sol";
import { TransferAdapter } from "../src/w3cash/adapters/TransferAdapter.sol";
import { ApproveAdapter } from "../src/w3cash/adapters/ApproveAdapter.sol";
import { SwapAdapter } from "../src/w3cash/adapters/SwapAdapter.sol";
import { WrapAdapter } from "../src/w3cash/adapters/WrapAdapter.sol";
import { ERC20 } from "@openzeppelin/contracts/token/ERC20/ERC20.sol";

/// @dev Mock ERC20 for testing
contract MockToken is ERC20 {
    constructor() ERC20("Mock", "MOCK") {
        _mint(msg.sender, 1_000_000e18);
    }

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }
}

/// @dev Mock WETH for testing
contract MockWETH {
    string public name = "Wrapped Ether";
    string public symbol = "WETH";
    uint8 public decimals = 18;

    mapping(address => uint256) public balanceOf;
    mapping(address => mapping(address => uint256)) public allowance;

    function deposit() external payable {
        balanceOf[msg.sender] += msg.value;
    }

    function withdraw(uint256 amount) external {
        require(balanceOf[msg.sender] >= amount, "Insufficient balance");
        balanceOf[msg.sender] -= amount;
        (bool success, ) = msg.sender.call{value: amount}("");
        require(success, "ETH transfer failed");
    }

    function transfer(address to, uint256 value) external returns (bool) {
        balanceOf[msg.sender] -= value;
        balanceOf[to] += value;
        return true;
    }

    function transferFrom(address from, address to, uint256 value) external returns (bool) {
        if (msg.sender != from) {
            allowance[from][msg.sender] -= value;
        }
        balanceOf[from] -= value;
        balanceOf[to] += value;
        return true;
    }

    function approve(address spender, uint256 value) external returns (bool) {
        allowance[msg.sender][spender] = value;
        return true;
    }

    receive() external payable {
        balanceOf[msg.sender] += msg.value;
    }
}

/// @dev Mock Uniswap Router for testing
contract MockSwapRouter {
    struct ExactInputSingleParams {
        address tokenIn;
        address tokenOut;
        uint24 fee;
        address recipient;
        uint256 amountIn;
        uint256 amountOutMinimum;
        uint160 sqrtPriceLimitX96;
    }

    // Simple 1:1 swap for testing
    function exactInputSingle(ExactInputSingleParams calldata params) external returns (uint256) {
        // Pull tokenIn
        MockToken(params.tokenIn).transferFrom(msg.sender, address(this), params.amountIn);
        // Mint tokenOut to recipient (1:1 for simplicity)
        MockToken(params.tokenOut).mint(params.recipient, params.amountIn);
        return params.amountIn;
    }
}

contract ActionAdaptersTest is Test {
    TransferAdapter public transferAdapter;
    ApproveAdapter public approveAdapter;
    SwapAdapter public swapAdapter;
    WrapAdapter public wrapAdapter;

    MockToken public tokenA;
    MockToken public tokenB;
    MockWETH public weth;
    MockSwapRouter public router;

    address public processor = address(0x1);
    address public user = address(0x2);
    address public recipient = address(0x3);

    function setUp() public {
        tokenA = new MockToken();
        tokenB = new MockToken();
        weth = new MockWETH();
        router = new MockSwapRouter();

        transferAdapter = new TransferAdapter(processor);
        approveAdapter = new ApproveAdapter(processor);
        swapAdapter = new SwapAdapter(address(router), processor);
        wrapAdapter = new WrapAdapter(address(weth), processor);

        // Fund user
        tokenA.transfer(user, 1000e18);
        tokenB.transfer(user, 1000e18);
        vm.deal(user, 10 ether);
    }

    // --- TransferAdapter Tests ---

    function test_Transfer_Success() public {
        uint256 amount = 100e18;

        // User approves adapter
        vm.prank(user);
        tokenA.approve(address(transferAdapter), amount);

        // Processor executes transfer
        vm.prank(processor);
        transferAdapter.execute(
            user,
            abi.encode(address(tokenA), recipient, amount)
        );

        assertEq(tokenA.balanceOf(recipient), amount);
        assertEq(tokenA.balanceOf(user), 900e18);
    }

    function test_Transfer_RevertIfNotProcessor() public {
        vm.prank(user);
        vm.expectRevert(TransferAdapter.OnlyProcessor.selector);
        transferAdapter.execute(user, abi.encode(address(tokenA), recipient, 100e18));
    }

    function test_Transfer_AdapterId() public view {
        assertEq(transferAdapter.adapterId(), bytes4(keccak256("TransferAdapter")));
    }

    // --- ApproveAdapter Tests ---

    function test_Approve_Success() public {
        uint256 amount = 100e18;

        vm.prank(processor);
        approveAdapter.execute(
            user,
            abi.encode(address(tokenA), recipient, amount)
        );

        // Approval is from adapter, not user (this is expected behavior)
        assertEq(tokenA.allowance(address(approveAdapter), recipient), amount);
    }

    function test_Approve_RevertIfNotProcessor() public {
        vm.prank(user);
        vm.expectRevert(ApproveAdapter.OnlyProcessor.selector);
        approveAdapter.execute(user, abi.encode(address(tokenA), recipient, 100e18));
    }

    function test_Approve_AdapterId() public view {
        assertEq(approveAdapter.adapterId(), bytes4(keccak256("ApproveAdapter")));
    }

    // --- SwapAdapter Tests ---

    function test_Swap_Success() public {
        uint256 amountIn = 100e18;

        // User approves adapter
        vm.prank(user);
        tokenA.approve(address(swapAdapter), amountIn);

        // Processor executes swap
        vm.prank(processor);
        bytes memory result = swapAdapter.execute(
            user,
            abi.encode(address(tokenA), address(tokenB), amountIn, 0, uint24(3000))
        );

        uint256 amountOut = abi.decode(result, (uint256));
        assertEq(amountOut, amountIn); // Mock does 1:1
        assertEq(tokenB.balanceOf(user), 1000e18 + amountIn);
    }

    function test_Swap_RevertIfNotProcessor() public {
        vm.prank(user);
        vm.expectRevert(SwapAdapter.OnlyProcessor.selector);
        swapAdapter.execute(user, abi.encode(address(tokenA), address(tokenB), 100e18, 0, uint24(3000)));
    }

    function test_Swap_AdapterId() public view {
        assertEq(swapAdapter.adapterId(), bytes4(keccak256("SwapAdapter")));
    }

    // --- WrapAdapter Tests ---

    function test_Wrap_Deposit() public {
        uint256 amount = 1 ether;

        // Fund the adapter (in real use, ETH comes from processor or user)
        vm.deal(address(wrapAdapter), amount);

        // Processor executes wrap
        vm.prank(processor);
        wrapAdapter.execute(
            user,
            abi.encode(true, amount) // isWrap = true
        );

        assertEq(weth.balanceOf(user), amount);
    }

    function test_Wrap_Withdraw() public {
        uint256 amount = 1 ether;

        // First, user gets some WETH
        vm.prank(user);
        weth.deposit{value: amount}();
        assertEq(weth.balanceOf(user), amount);

        // User approves adapter
        vm.prank(user);
        weth.approve(address(wrapAdapter), amount);

        uint256 userEthBefore = user.balance;

        // Processor executes unwrap
        vm.prank(processor);
        wrapAdapter.execute(
            user,
            abi.encode(false, amount) // isWrap = false
        );

        assertEq(weth.balanceOf(user), 0);
        assertEq(user.balance, userEthBefore + amount);
    }

    function test_Wrap_RevertIfNotProcessor() public {
        vm.prank(user);
        vm.expectRevert(WrapAdapter.OnlyProcessor.selector);
        wrapAdapter.execute(user, abi.encode(true, 1 ether));
    }

    function test_Wrap_AdapterId() public view {
        assertEq(wrapAdapter.adapterId(), bytes4(keccak256("WrapAdapter")));
    }
}
