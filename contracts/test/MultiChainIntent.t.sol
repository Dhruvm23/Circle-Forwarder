// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "forge-std/Test.sol";
import {BaseReceiver, ITokenMessenger} from "../src/BaseReceiver.sol";
import {ArbExecutor, IPool} from "../src/ArbExecutor.sol";
import {CrossChainIntent, IntentLib} from "../src/types/IntentStructures.sol";
import {Addresses} from "../src/constants/Addresses.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {MessageHashUtils} from "@openzeppelin/contracts/utils/cryptography/MessageHashUtils.sol";

/// @title MultiChainIntentTest — In-Memory Multi-Fork Integration Test Suite
/// @notice Validates the complete Circle Forwarder protocol across Base and Arbitrum forks
/// @dev Uses Foundry's vm.createFork and vm.selectFork to simulate cross-chain state shifts.
///      Each test operates on forked mainnet state, ensuring production-equivalent validation.
///
///      Test coverage:
///      - EIP-712 signature generation, recovery, and verification
///      - Temporal deadline enforcement
///      - Sequential nonce replay protection
///      - Invalid signer rejection
///      - ArbExecutor fulfillment with real Aave V3 integration
///      - Solver access control enforcement
contract MultiChainIntentTest is Test {
    // ═══════════════════════════════════════════════════════════════
    //                        FORK STATE
    // ═══════════════════════════════════════════════════════════════

    /// @dev Fork identifier for Base mainnet state
    uint256 internal baseFork;

    /// @dev Fork identifier for Arbitrum mainnet state
    uint256 internal arbFork;

    // ═══════════════════════════════════════════════════════════════
    //                      TEST IDENTITIES
    // ═══════════════════════════════════════════════════════════════

    /// @dev Deterministic private key for the test user (used with vm.sign)
    uint256 internal constant USER_PRIVATE_KEY = 0xBEEF;

    /// @dev Derived address from USER_PRIVATE_KEY
    address internal user;

    /// @dev Solver address for relay operations
    address internal solver;

    // ═══════════════════════════════════════════════════════════════
    //                    CONTRACT INSTANCES
    // ═══════════════════════════════════════════════════════════════

    /// @dev BaseReceiver deployed on the Base fork
    BaseReceiver internal baseReceiver;

    /// @dev ArbExecutor deployed on the Arbitrum fork
    ArbExecutor internal arbExecutor;

    // ═══════════════════════════════════════════════════════════════
    //                        CONSTANTS
    // ═══════════════════════════════════════════════════════════════

    /// @dev Standard test amount: 100 USDC (6 decimals)
    uint256 internal constant INTENT_AMOUNT = 100e6;

    /// @dev Mock CCTP nonce returned by the mocked TokenMessenger
    uint64 internal constant MOCK_CCTP_NONCE = 42;

    // ═══════════════════════════════════════════════════════════════
    //                          SETUP
    // ═══════════════════════════════════════════════════════════════

    function setUp() public {
        // Create mainnet forks using RPC endpoints from foundry.toml
        baseFork = vm.createFork("base");
        arbFork = vm.createFork("arbitrum");

        // Derive test identities
        user = vm.addr(USER_PRIVATE_KEY);
        solver = makeAddr("solver");

        // ─── Deploy BaseReceiver on Base Fork ───
        vm.selectFork(baseFork);
        baseReceiver = new BaseReceiver(solver);

        // ─── Deploy ArbExecutor on Arbitrum Fork ───
        vm.selectFork(arbFork);
        arbExecutor = new ArbExecutor(solver);
    }

    // ═══════════════════════════════════════════════════════════════
    //                    INTERNAL HELPERS
    // ═══════════════════════════════════════════════════════════════

    /// @notice Creates a CrossChainIntent struct with standard test parameters
    /// @param nonce The nonce value for the intent
    /// @param deadline The deadline timestamp for the intent
    /// @return The constructed CrossChainIntent struct
    function _createIntent(
        uint256 nonce,
        uint256 deadline
    ) internal view returns (CrossChainIntent memory) {
        return CrossChainIntent({
            user: user,
            amount: INTENT_AMOUNT,
            destinationDomain: Addresses.ARBITRUM_DOMAIN,
            destinationVault: address(arbExecutor),
            nonce: nonce,
            deadline: deadline
        });
    }

    /// @notice Generates an EIP-712 signature for a CrossChainIntent
    /// @dev Reconstructs the typed data hash using the BaseReceiver's domain separator
    ///      and signs with the provided private key using vm.sign
    /// @param intent The intent struct to sign
    /// @param privateKey The private key to sign with
    /// @return The packed signature bytes (r || s || v)
    function _signIntent(
        CrossChainIntent memory intent,
        uint256 privateKey
    ) internal view returns (bytes memory) {
        bytes32 structHash = IntentLib.hashIntent(intent);
        bytes32 domainSeparator = baseReceiver.getDomainSeparator();
        bytes32 digest = MessageHashUtils.toTypedDataHash(domainSeparator, structHash);
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(privateKey, digest);
        return abi.encodePacked(r, s, v);
    }

    /// @notice Sets up Base fork state for intent execution tests
    /// @dev Deals USDC to user, approves BaseReceiver, and mocks Circle TokenMessenger
    function _setupBaseState() internal {
        vm.selectFork(baseFork);

        // Deal USDC to the test user on the Base fork
        deal(Addresses.BASE_USDC, user, INTENT_AMOUNT);

        // User approves BaseReceiver to spend their USDC (simulates prior on-chain approval)
        vm.prank(user);
        IERC20(Addresses.BASE_USDC).approve(address(baseReceiver), type(uint256).max);

        // Mock Circle TokenMessenger's depositForBurn to return a deterministic CCTP nonce
        // This isolates our protocol logic from Circle's CCTP infrastructure during testing
        vm.mockCall(
            Addresses.BASE_TOKEN_MESSENGER,
            abi.encodeWithSelector(ITokenMessenger.depositForBurn.selector),
            abi.encode(MOCK_CCTP_NONCE)
        );
    }

    // ═══════════════════════════════════════════════════════════════
    //        TEST 1: EIP-712 SIGNATURE VERIFICATION & EXECUTION
    // ═══════════════════════════════════════════════════════════════

    /// @notice Validates the complete happy-path intent execution flow
    /// @dev Verifies: signature recovery, nonce increment, USDC transfer, event emission
    function test_EIP712_SignatureVerification() public {
        _setupBaseState();

        // Construct a valid intent with nonce 0 and future deadline
        CrossChainIntent memory intent = _createIntent(0, block.timestamp + 1 hours);
        bytes memory signature = _signIntent(intent, USER_PRIVATE_KEY);

        // Expect the IntentExecuted event with correct parameters
        vm.expectEmit(true, false, false, true);
        emit BaseReceiver.IntentExecuted(user, INTENT_AMOUNT, Addresses.ARBITRUM_DOMAIN, 0, MOCK_CCTP_NONCE);

        // Execute the intent
        uint64 cctpNonce = baseReceiver.executeIntent(intent, signature);

        // ─── Assertions ───
        // Verify nonce was incremented from 0 → 1
        assertEq(baseReceiver.nonces(user), 1, "Nonce should increment to 1 after execution");

        // Verify CCTP nonce matches mock return value
        assertEq(cctpNonce, MOCK_CCTP_NONCE, "CCTP nonce should match mocked return value");

        // Verify user's USDC was fully consumed
        assertEq(
            IERC20(Addresses.BASE_USDC).balanceOf(user), 0, "User USDC balance should be zero after intent execution"
        );
    }

    // ═══════════════════════════════════════════════════════════════
    //            TEST 2: REJECT EXPIRED INTENT
    // ═══════════════════════════════════════════════════════════════

    /// @notice Validates that intents with past deadlines are rejected
    /// @dev The contract should revert with IntentExpired() before any state mutation
    function test_RejectExpiredIntent() public {
        _setupBaseState();

        // Create intent with deadline in the past
        CrossChainIntent memory intent = _createIntent(0, block.timestamp - 1);
        bytes memory signature = _signIntent(intent, USER_PRIVATE_KEY);

        // Expect revert with IntentExpired error
        vm.expectRevert(BaseReceiver.IntentExpired.selector);
        baseReceiver.executeIntent(intent, signature);

        // Verify no state was mutated
        assertEq(baseReceiver.nonces(user), 0, "Nonce should remain 0 after rejected intent");
    }

    // ═══════════════════════════════════════════════════════════════
    //            TEST 3: REJECT INVALID SIGNER
    // ═══════════════════════════════════════════════════════════════

    /// @notice Validates that signatures from non-user addresses are rejected
    /// @dev Uses a different private key to sign the intent, resulting in a different signer
    function test_RejectInvalidSigner() public {
        _setupBaseState();

        // Create a valid intent but sign with the wrong private key
        CrossChainIntent memory intent = _createIntent(0, block.timestamp + 1 hours);
        uint256 wrongPrivateKey = 0xDEAD;
        bytes memory badSignature = _signIntent(intent, wrongPrivateKey);

        // Expect revert with InvalidSignature error
        vm.expectRevert(BaseReceiver.InvalidSignature.selector);
        baseReceiver.executeIntent(intent, badSignature);

        // Verify no state was mutated
        assertEq(baseReceiver.nonces(user), 0, "Nonce should remain 0 after invalid signature");
    }

    // ═══════════════════════════════════════════════════════════════
    //            TEST 4: REJECT INVALID NONCE
    // ═══════════════════════════════════════════════════════════════

    /// @notice Validates that out-of-sequence nonces are rejected
    /// @dev User's current nonce is 0, but the intent specifies nonce 1
    function test_RejectInvalidNonce() public {
        _setupBaseState();

        // Create intent with nonce 1 (expected: 0)
        CrossChainIntent memory intent = _createIntent(1, block.timestamp + 1 hours);
        bytes memory signature = _signIntent(intent, USER_PRIVATE_KEY);

        // Expect revert with InvalidNonce error
        vm.expectRevert(BaseReceiver.InvalidNonce.selector);
        baseReceiver.executeIntent(intent, signature);
    }

    // ═══════════════════════════════════════════════════════════════
    //       TEST 5: SEQUENTIAL NONCE INCREMENT ACROSS INTENTS
    // ═══════════════════════════════════════════════════════════════

    /// @notice Validates that multiple sequential intents execute correctly
    /// @dev Executes two intents in sequence (nonce 0, then nonce 1)
    function test_SequentialNonceExecution() public {
        _setupBaseState();

        // Deal additional USDC for second intent
        deal(Addresses.BASE_USDC, user, INTENT_AMOUNT * 2);
        vm.prank(user);
        IERC20(Addresses.BASE_USDC).approve(address(baseReceiver), type(uint256).max);

        // Execute first intent (nonce 0)
        CrossChainIntent memory intent0 = _createIntent(0, block.timestamp + 1 hours);
        bytes memory sig0 = _signIntent(intent0, USER_PRIVATE_KEY);
        baseReceiver.executeIntent(intent0, sig0);
        assertEq(baseReceiver.nonces(user), 1, "Nonce should be 1 after first intent");

        // Execute second intent (nonce 1)
        CrossChainIntent memory intent1 = _createIntent(1, block.timestamp + 1 hours);
        bytes memory sig1 = _signIntent(intent1, USER_PRIVATE_KEY);
        baseReceiver.executeIntent(intent1, sig1);
        assertEq(baseReceiver.nonces(user), 2, "Nonce should be 2 after second intent");
    }

    // ═══════════════════════════════════════════════════════════════
    //        TEST 6: ARB EXECUTOR FULFILLS INTENT VIA AAVE V3
    // ═══════════════════════════════════════════════════════════════

    /// @notice Validates ArbExecutor's fulfillment flow on an Arbitrum mainnet fork
    /// @dev Uses real Aave V3 Pool on the fork to verify USDC supply succeeds
    function test_ArbExecutor_FulfillIntent() public {
        vm.selectFork(arbFork);

        uint256 supplyAmount = 100e6; // 100 USDC

        // Deal USDC to solver on Arbitrum fork
        deal(Addresses.ARB_USDC, solver, supplyAmount);

        // Solver approves ArbExecutor to spend USDC
        vm.prank(solver);
        IERC20(Addresses.ARB_USDC).approve(address(arbExecutor), supplyAmount);

        // Record solver balance before fulfillment
        uint256 solverBalanceBefore = IERC20(Addresses.ARB_USDC).balanceOf(solver);

        // Expect IntentFulfilled event
        vm.expectEmit(true, false, false, true);
        emit ArbExecutor.IntentFulfilled(user, supplyAmount, Addresses.ARB_AAVE_V3_POOL);

        // Solver fulfills the intent — supplies USDC to Aave V3 on behalf of user
        vm.prank(solver);
        arbExecutor.fulfillIntent(user, supplyAmount, Addresses.ARB_AAVE_V3_POOL);

        // ─── Assertions ───
        // Verify solver's USDC was fully consumed
        assertEq(
            IERC20(Addresses.ARB_USDC).balanceOf(solver),
            solverBalanceBefore - supplyAmount,
            "Solver USDC should decrease by supply amount"
        );

        // Verify ArbExecutor holds no residual USDC (all forwarded to Aave)
        assertEq(
            IERC20(Addresses.ARB_USDC).balanceOf(address(arbExecutor)),
            0,
            "ArbExecutor should have zero residual USDC balance"
        );
    }

    // ═══════════════════════════════════════════════════════════════
    //        TEST 7: ARB EXECUTOR REJECTS NON-SOLVER CALLER
    // ═══════════════════════════════════════════════════════════════

    /// @notice Validates that unauthorized addresses cannot call fulfillIntent
    /// @dev An imposter address should trigger the OnlySolver revert
    function test_ArbExecutor_RejectsNonSolver() public {
        vm.selectFork(arbFork);

        address imposter = makeAddr("imposter");

        // Imposter attempts to call fulfillIntent
        vm.prank(imposter);
        vm.expectRevert(ArbExecutor.OnlySolver.selector);
        arbExecutor.fulfillIntent(user, INTENT_AMOUNT, Addresses.ARB_AAVE_V3_POOL);
    }
}
