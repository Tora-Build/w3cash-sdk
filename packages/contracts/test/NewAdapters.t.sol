// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import { Test } from "forge-std/Test.sol";
import { BorrowAdapter } from "../src/w3cash/adapters/BorrowAdapter.sol";
import { RepayAdapter } from "../src/w3cash/adapters/RepayAdapter.sol";
import { DelegateAdapter } from "../src/w3cash/adapters/DelegateAdapter.sol";
import { VoteAdapter } from "../src/w3cash/adapters/VoteAdapter.sol";
import { ClaimAdapter } from "../src/w3cash/adapters/ClaimAdapter.sol";
import { BurnAdapter } from "../src/w3cash/adapters/BurnAdapter.sol";
import { MintAdapter } from "../src/w3cash/adapters/MintAdapter.sol";
import { LockAdapter } from "../src/w3cash/adapters/LockAdapter.sol";
import { UnwrapAdapter } from "../src/w3cash/adapters/UnwrapAdapter.sol";
import { BalanceAdapter } from "../src/w3cash/adapters/BalanceAdapter.sol";
import { AllowanceAdapter } from "../src/w3cash/adapters/AllowanceAdapter.sol";
import { PriceAdapter } from "../src/w3cash/adapters/PriceAdapter.sol";
import { HealthFactorAdapter } from "../src/w3cash/adapters/HealthFactorAdapter.sol";
import { DataTypes } from "../src/w3cash/utils/DataTypes.sol";
import { ERC20 } from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import { ERC20Burnable } from "@openzeppelin/contracts/token/ERC20/extensions/ERC20Burnable.sol";

/// @dev Mock ERC20 with burn
contract MockBurnableToken is ERC20Burnable {
    constructor() ERC20("Mock Burnable", "MBURN") {
        _mint(msg.sender, 1_000_000e18);
    }

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }
}

/// @dev Mock WETH
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

/// @dev Mock Aave Pool for borrow/repay
contract MockAavePool {
    mapping(address => uint256) public borrowed;

    function borrow(
        address asset,
        uint256 amount,
        uint256,
        uint16,
        address onBehalfOf
    ) external {
        // Simulate: transfer borrowed tokens to onBehalfOf
        MockBurnableToken(asset).mint(onBehalfOf, amount);
        borrowed[onBehalfOf] += amount;
    }

    function repay(
        address asset,
        uint256 amount,
        uint256,
        address onBehalfOf
    ) external returns (uint256) {
        uint256 debt = borrowed[onBehalfOf];
        uint256 toRepay = amount > debt ? debt : amount;
        borrowed[onBehalfOf] -= toRepay;
        // Burn the tokens
        MockBurnableToken(asset).burnFrom(msg.sender, toRepay);
        return toRepay;
    }

    function getUserAccountData(address user)
        external
        view
        returns (
            uint256 totalCollateralBase,
            uint256 totalDebtBase,
            uint256 availableBorrowsBase,
            uint256 currentLiquidationThreshold,
            uint256 ltv,
            uint256 healthFactor
        )
    {
        uint256 debt = borrowed[user];
        return (
            1000e8, // collateral
            debt > 0 ? 500e8 : 0, // debt
            500e8, // available borrows
            8000, // liquidation threshold
            7500, // ltv
            debt > 0 ? 15e17 : type(uint256).max // health factor 1.5 or max
        );
    }
}

/// @dev Mock Chainlink Price Feed
contract MockPriceFeed {
    int256 public price = 3000e8; // $3000

    function setPrice(int256 _price) external {
        price = _price;
    }

    function latestRoundData()
        external
        view
        returns (
            uint80 roundId,
            int256 answer,
            uint256 startedAt,
            uint256 updatedAt,
            uint80 answeredInRound
        )
    {
        return (1, price, block.timestamp, block.timestamp, 1);
    }

    function decimals() external pure returns (uint8) {
        return 8;
    }
}

contract NewAdaptersTest is Test {
    // Adapters
    BorrowAdapter public borrowAdapter;
    RepayAdapter public repayAdapter;
    BurnAdapter public burnAdapter;
    LockAdapter public lockAdapter;
    UnwrapAdapter public unwrapAdapter;
    BalanceAdapter public balanceAdapter;
    AllowanceAdapter public allowanceAdapter;
    PriceAdapter public priceAdapter;
    HealthFactorAdapter public healthFactorAdapter;

    // Mocks
    MockBurnableToken public token;
    MockWETH public weth;
    MockAavePool public aavePool;
    MockPriceFeed public priceFeed;

    address public processor = address(0x1);
    address public user = address(0x2);

    function setUp() public {
        // Deploy mocks
        token = new MockBurnableToken();
        weth = new MockWETH();
        aavePool = new MockAavePool();
        priceFeed = new MockPriceFeed();

        // Deploy adapters
        borrowAdapter = new BorrowAdapter(address(aavePool), processor);
        repayAdapter = new RepayAdapter(address(aavePool), processor);
        burnAdapter = new BurnAdapter(processor);
        lockAdapter = new LockAdapter(processor);
        unwrapAdapter = new UnwrapAdapter(address(weth), processor);
        balanceAdapter = new BalanceAdapter(processor);
        allowanceAdapter = new AllowanceAdapter(processor);
        priceAdapter = new PriceAdapter(processor);
        healthFactorAdapter = new HealthFactorAdapter(address(aavePool), processor);

        // Fund user
        token.transfer(user, 10_000e18);
        vm.deal(user, 10 ether);
    }

    // --- BorrowAdapter Tests ---

    function test_Borrow_Success() public {
        vm.prank(processor);
        bytes memory result = borrowAdapter.execute(
            user,
            abi.encode(address(token), 100e18, 2) // variable rate
        );

        uint256 borrowed = abi.decode(result, (uint256));
        assertEq(borrowed, 100e18);
        assertEq(aavePool.borrowed(user), 100e18);
    }

    function test_Borrow_RevertIfNotProcessor() public {
        vm.prank(user);
        vm.expectRevert(BorrowAdapter.BorrowAdapter__CallerNotProcessor.selector);
        borrowAdapter.execute(user, abi.encode(address(token), 100e18, 2));
    }

    function test_Borrow_RevertZeroAmount() public {
        vm.prank(processor);
        vm.expectRevert(BorrowAdapter.BorrowAdapter__ZeroAmount.selector);
        borrowAdapter.execute(user, abi.encode(address(token), 0, 2));
    }

    function test_Borrow_RevertInvalidRate() public {
        vm.prank(processor);
        vm.expectRevert(BorrowAdapter.BorrowAdapter__InvalidRateMode.selector);
        borrowAdapter.execute(user, abi.encode(address(token), 100e18, 3));
    }

    function test_Borrow_AdapterId() public view {
        assertEq(borrowAdapter.adapterId(), bytes4(keccak256("BorrowAdapter")));
    }

    // --- BurnAdapter Tests ---

    function test_Burn_TransferDead() public {
        uint256 amount = 100e18;
        address deadAddress = 0x000000000000000000000000000000000000dEaD;

        vm.prank(user);
        token.approve(address(burnAdapter), amount);

        uint256 deadBefore = token.balanceOf(deadAddress);

        vm.prank(processor);
        burnAdapter.execute(user, abi.encode(address(token), amount, uint8(2)));

        assertEq(token.balanceOf(deadAddress), deadBefore + amount);
    }

    function test_Burn_RevertIfNotProcessor() public {
        vm.prank(user);
        vm.expectRevert(BurnAdapter.BurnAdapter__CallerNotProcessor.selector);
        burnAdapter.execute(user, abi.encode(address(token), 100e18, uint8(2)));
    }

    function test_Burn_AdapterId() public view {
        assertEq(burnAdapter.adapterId(), bytes4(keccak256("BurnAdapter")));
    }

    // --- LockAdapter Tests ---

    function test_Lock_Success() public {
        uint256 amount = 100e18;
        uint256 unlockTime = block.timestamp + 1 days;

        vm.prank(user);
        token.approve(address(lockAdapter), amount);

        // Encode: bytes4 op + abi.encode(token, amount, unlockTime)
        bytes memory lockData = bytes.concat(
            lockAdapter.OP_LOCK(),
            abi.encode(address(token), amount, unlockTime)
        );

        vm.startPrank(processor);
        bytes memory result = lockAdapter.execute(user, lockData);
        vm.stopPrank();

        uint256 lockId = abi.decode(result, (uint256));
        assertEq(lockId, 0);
        assertEq(token.balanceOf(address(lockAdapter)), amount);

        (address lockedToken, uint256 lockedAmount, uint256 lockedUntil, bool withdrawn) = lockAdapter.locks(user, lockId);
        assertEq(lockedToken, address(token));
        assertEq(lockedAmount, amount);
        assertEq(lockedUntil, unlockTime);
        assertFalse(withdrawn);
    }

    function test_Lock_Unlock_Success() public {
        uint256 amount = 100e18;
        uint256 unlockTime = block.timestamp + 1 days;

        // Lock tokens
        vm.prank(user);
        token.approve(address(lockAdapter), amount);

        bytes memory lockData = bytes.concat(
            lockAdapter.OP_LOCK(),
            abi.encode(address(token), amount, unlockTime)
        );

        vm.startPrank(processor);
        bytes memory result = lockAdapter.execute(user, lockData);
        vm.stopPrank();
        
        uint256 lockId = abi.decode(result, (uint256));

        // Fast forward time
        vm.warp(unlockTime + 1);

        // Unlock
        uint256 balanceBefore = token.balanceOf(user);
        bytes memory unlockData = bytes.concat(
            lockAdapter.OP_UNLOCK(),
            abi.encode(lockId)
        );
        
        vm.startPrank(processor);
        lockAdapter.execute(user, unlockData);
        vm.stopPrank();

        assertEq(token.balanceOf(user), balanceBefore + amount);
    }

    function test_Lock_RevertIfNotUnlocked() public {
        uint256 amount = 100e18;
        uint256 unlockTime = block.timestamp + 1 days;

        vm.prank(user);
        token.approve(address(lockAdapter), amount);

        bytes memory lockData = bytes.concat(
            lockAdapter.OP_LOCK(),
            abi.encode(address(token), amount, unlockTime)
        );

        vm.startPrank(processor);
        bytes memory result = lockAdapter.execute(user, lockData);
        vm.stopPrank();
        
        uint256 lockId = abi.decode(result, (uint256));

        // Try to unlock before time
        bytes memory unlockData = bytes.concat(
            lockAdapter.OP_UNLOCK(),
            abi.encode(lockId)
        );
        
        vm.startPrank(processor);
        vm.expectRevert(LockAdapter.LockAdapter__NotUnlocked.selector);
        lockAdapter.execute(user, unlockData);
        vm.stopPrank();
    }

    function test_Lock_AdapterId() public view {
        assertEq(lockAdapter.adapterId(), bytes4(keccak256("LockAdapter")));
    }

    // --- UnwrapAdapter Tests ---

    function test_Unwrap_Success() public {
        uint256 amount = 1 ether;

        // User wraps ETH first
        vm.prank(user);
        weth.deposit{value: amount}();
        assertEq(weth.balanceOf(user), amount);

        // Approve adapter
        vm.prank(user);
        weth.approve(address(unwrapAdapter), amount);

        uint256 ethBefore = user.balance;

        // Unwrap
        vm.prank(processor);
        unwrapAdapter.execute(user, abi.encode(amount));

        assertEq(weth.balanceOf(user), 0);
        assertEq(user.balance, ethBefore + amount);
    }

    function test_Unwrap_RevertIfNotProcessor() public {
        vm.prank(user);
        vm.expectRevert(UnwrapAdapter.UnwrapAdapter__CallerNotProcessor.selector);
        unwrapAdapter.execute(user, abi.encode(1 ether));
    }

    function test_Unwrap_AdapterId() public view {
        assertEq(unwrapAdapter.adapterId(), bytes4(keccak256("UnwrapAdapter")));
    }

    // --- BalanceAdapter Tests ---

    function test_Balance_ConditionMet() public {
        // User has 10_000e18 tokens
        vm.prank(processor);
        bytes memory result = balanceAdapter.execute(
            user,
            abi.encode(address(token), user, uint8(3), 1000e18) // >= 1000e18
        );

        assertEq(result.length, 0); // Empty = condition met
    }

    function test_Balance_ConditionNotMet() public {
        vm.prank(processor);
        bytes memory result = balanceAdapter.execute(
            user,
            abi.encode(address(token), user, uint8(3), 100_000e18) // >= 100_000e18
        );

        bytes32 pauseExecution = abi.decode(result, (bytes32));
        assertEq(pauseExecution, DataTypes.PAUSE_EXECUTION);
    }

    function test_Balance_ETH() public {
        // User has 10 ETH (after setUp minus any spent in other tests)
        vm.prank(processor);
        bytes memory result = balanceAdapter.execute(
            user,
            abi.encode(address(0), user, uint8(3), 1 ether) // >= 1 ETH
        );

        assertEq(result.length, 0); // Condition met
    }

    function test_Balance_AdapterId() public view {
        assertEq(balanceAdapter.adapterId(), bytes4(keccak256("BalanceAdapter")));
    }

    // --- AllowanceAdapter Tests ---

    function test_Allowance_ConditionMet() public {
        address spender = address(0x123);

        vm.prank(user);
        token.approve(spender, 1000e18);

        vm.prank(processor);
        bytes memory result = allowanceAdapter.execute(
            user,
            abi.encode(address(token), user, spender, uint8(3), 500e18) // >= 500e18
        );

        assertEq(result.length, 0); // Condition met
    }

    function test_Allowance_ConditionNotMet() public {
        address spender = address(0x123);

        vm.prank(processor);
        bytes memory result = allowanceAdapter.execute(
            user,
            abi.encode(address(token), user, spender, uint8(3), 500e18) // >= 500e18
        );

        bytes32 pauseExecution = abi.decode(result, (bytes32));
        assertEq(pauseExecution, DataTypes.PAUSE_EXECUTION);
    }

    function test_Allowance_AdapterId() public view {
        assertEq(allowanceAdapter.adapterId(), bytes4(keccak256("AllowanceAdapter")));
    }

    // --- PriceAdapter Tests ---

    function test_Price_ConditionMet_GTE() public {
        // Price is $3000
        vm.prank(processor);
        bytes memory result = priceAdapter.execute(
            user,
            abi.encode(address(priceFeed), uint8(3), int256(2500e8), false) // >= $2500
        );

        assertEq(result.length, 0); // Condition met
    }

    function test_Price_ConditionNotMet_GTE() public {
        vm.prank(processor);
        bytes memory result = priceAdapter.execute(
            user,
            abi.encode(address(priceFeed), uint8(3), int256(3500e8), false) // >= $3500
        );

        bytes32 pauseExecution = abi.decode(result, (bytes32));
        assertEq(pauseExecution, DataTypes.PAUSE_EXECUTION);
    }

    function test_Price_ConditionMet_LTE() public {
        // Price is $3000
        vm.prank(processor);
        bytes memory result = priceAdapter.execute(
            user,
            abi.encode(address(priceFeed), uint8(2), int256(3500e8), false) // <= $3500
        );

        assertEq(result.length, 0); // Condition met
    }

    function test_Price_AdapterId() public view {
        assertEq(priceAdapter.adapterId(), bytes4(keccak256("PriceAdapter")));
    }

    // --- HealthFactorAdapter Tests ---

    function test_HealthFactor_NoBorrow() public {
        // User has no debt, health factor is max
        vm.prank(processor);
        bytes memory result = healthFactorAdapter.execute(
            user,
            abi.encode(user, uint8(1), 1e18) // > 1.0
        );

        assertEq(result.length, 0); // Condition met
    }

    function test_HealthFactor_WithBorrow() public {
        // First borrow something
        vm.prank(processor);
        borrowAdapter.execute(user, abi.encode(address(token), 100e18, 2));

        // Health factor is 1.5
        vm.prank(processor);
        bytes memory result = healthFactorAdapter.execute(
            user,
            abi.encode(user, uint8(1), 12e17) // > 1.2
        );

        assertEq(result.length, 0); // Condition met (1.5 > 1.2)
    }

    function test_HealthFactor_ConditionNotMet() public {
        // First borrow something
        vm.prank(processor);
        borrowAdapter.execute(user, abi.encode(address(token), 100e18, 2));

        // Health factor is 1.5
        vm.prank(processor);
        bytes memory result = healthFactorAdapter.execute(
            user,
            abi.encode(user, uint8(1), 2e18) // > 2.0
        );

        bytes32 pauseExecution = abi.decode(result, (bytes32));
        assertEq(pauseExecution, DataTypes.PAUSE_EXECUTION);
    }

    function test_HealthFactor_AdapterId() public view {
        assertEq(healthFactorAdapter.adapterId(), bytes4(keccak256("HealthFactorAdapter")));
    }
}
