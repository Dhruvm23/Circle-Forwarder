// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {Addresses} from "./constants/Addresses.sol";

/// @title IPool — Aave V3 Lending Pool Interface
/// @notice Minimal interface for Aave V3 supply operations
interface IPool {
    /// @notice Supplies an asset into the Aave V3 lending pool
    /// @param asset The address of the underlying asset to supply
    /// @param amount The amount to supply (in asset's native decimals)
    /// @param onBehalfOf The address that will receive the corresponding aTokens
    /// @param referralCode Referral code for integrator tracking (0 for none)
    function supply(
        address asset,
        uint256 amount,
        address onBehalfOf,
        uint16 referralCode
    ) external;
}

/// @title ArbExecutor — Destination Chain Strategy Fulfillment Engine
/// @notice Receives USDC on Arbitrum and deploys it into Aave V3 on behalf of the intent user
/// @dev Deployed on Arbitrum mainnet. Only the authorized solver can call fulfillment functions.
///
///      Capital flow:
///      1. CCTP mints USDC to the solver on Arbitrum (off-chain attestation)
///      2. Solver transfers USDC to this contract via fulfillIntent
///      3. This contract supplies USDC into Aave V3 on behalf of the original intent user
///      4. User receives aUSDC position in their wallet without any on-chain interaction
///
///      Access control: Simple immutable solver pattern — only the constructor-set solver
///      address can trigger fulfillment. This prevents unauthorized capital deployment.
contract ArbExecutor {
    // ═══════════════════════════════════════════════════════════════
    //                          STATE
    // ═══════════════════════════════════════════════════════════════

    /// @notice The authorized solver address that can trigger intent fulfillment
    /// @dev Set once at deployment, cannot be changed (immutable)
    address public immutable solver;

    // ═══════════════════════════════════════════════════════════════
    //                          EVENTS
    // ═══════════════════════════════════════════════════════════════

    /// @notice Emitted when an intent is fulfilled and capital deployed to the target vault
    /// @param user The original intent user who receives the Aave aUSDC position
    /// @param amount The USDC amount supplied to Aave V3 (6 decimal precision)
    /// @param vault The target vault address (Aave V3 Pool)
    event IntentFulfilled(address indexed user, uint256 amount, address vault);

    // ═══════════════════════════════════════════════════════════════
    //                          ERRORS
    // ═══════════════════════════════════════════════════════════════

    /// @notice Thrown when a non-solver address attempts to call restricted functions
    error OnlySolver();

    // ═══════════════════════════════════════════════════════════════
    //                        MODIFIERS
    // ═══════════════════════════════════════════════════════════════

    /// @notice Restricts function access to the authorized solver address
    modifier onlySolver() {
        if (msg.sender != solver) revert OnlySolver();
        _;
    }

    // ═══════════════════════════════════════════════════════════════
    //                        CONSTRUCTOR
    // ═══════════════════════════════════════════════════════════════

    /// @notice Initializes the ArbExecutor with the authorized solver address
    /// @param _solver The address authorized to trigger intent fulfillment
    constructor(
        address _solver
    ) {
        solver = _solver;
    }

    // ═══════════════════════════════════════════════════════════════
    //                      EXTERNAL FUNCTIONS
    // ═══════════════════════════════════════════════════════════════

    /// @notice Fulfills a cross-chain intent by supplying USDC to Aave V3 on behalf of the user
    /// @dev Execution flow:
    ///      1. Pull USDC from solver (msg.sender) via transferFrom
    ///      2. Approve the target vault (Aave V3 Pool) to spend the USDC
    ///      3. Supply USDC to Aave V3 with the user as the beneficiary
    ///      4. Emit IntentFulfilled event for tracking and indexing
    ///
    ///      The solver must have approved this contract to spend USDC before calling.
    ///      After execution, the user will hold aUSDC in their wallet representing
    ///      their Aave V3 lending position.
    ///
    /// @param user The original intent user who will receive the Aave aUSDC position
    /// @param amount The USDC amount to supply to Aave V3 (6 decimal precision)
    /// @param vault The target vault address (should be the Aave V3 Pool proxy)
    function fulfillIntent(
        address user,
        uint256 amount,
        address vault
    ) external onlySolver {
        // Step 1: Pull USDC from solver into this contract
        IERC20(Addresses.ARB_USDC).transferFrom(msg.sender, address(this), amount);

        // Step 2: Approve the Aave V3 Pool to spend the USDC
        IERC20(Addresses.ARB_USDC).approve(vault, amount);

        // Step 3: Supply USDC to Aave V3 on behalf of the original intent user
        IPool(vault).supply(Addresses.ARB_USDC, amount, user, 0);

        // Step 4: Emit fulfillment event for off-chain tracking
        emit IntentFulfilled(user, amount, vault);
    }
}
