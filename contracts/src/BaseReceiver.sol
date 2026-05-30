// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {ECDSA} from "@openzeppelin/contracts/utils/cryptography/ECDSA.sol";
import {EIP712} from "@openzeppelin/contracts/utils/cryptography/EIP712.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {CrossChainIntent, IntentLib} from "./types/IntentStructures.sol";
import {Addresses} from "./constants/Addresses.sol";

/// @title ITokenMessenger — Circle CCTP TokenMessenger Interface
/// @notice Minimal interface for Circle's cross-chain burn-and-mint bridge
interface ITokenMessenger {
    /// @notice Burns tokens on the source chain and triggers minting on the destination chain
    /// @param amount Amount of tokens to burn
    /// @param destinationDomain CCTP domain identifier for the target chain
    /// @param mintRecipient Address (as bytes32) that will receive minted tokens on destination
    /// @param burnToken Address of the token to burn on this chain
    /// @return nonce CCTP message nonce for attestation tracking
    function depositForBurn(
        uint256 amount,
        uint32 destinationDomain,
        bytes32 mintRecipient,
        address burnToken
    ) external returns (uint64 nonce);
}

/// @title BaseReceiver — Source Chain Intent Verification & CCTP Burn Engine
/// @notice Validates EIP-712 signed intents, pulls user USDC, and initiates cross-chain
///         burns via Circle's CCTP TokenMessenger on the Base network
/// @dev Deployed on Base mainnet. Uses OpenZeppelin's EIP712 for domain separator management.
///      The mintRecipient is the destination contract (ArbExecutor) or solver that receives
///      minted USDC on the target chain after CCTP attestation completes.
///
///      Security model:
///      - Users sign off-chain EIP-712 structured data (gasless)
///      - Solvers submit the signed intent and sponsor all gas costs
///      - Sequential nonces prevent replay attacks
///      - Temporal deadlines prevent stale intent execution
contract BaseReceiver is EIP712 {
    using IntentLib for CrossChainIntent;

    // ═══════════════════════════════════════════════════════════════
    //                          STATE
    // ═══════════════════════════════════════════════════════════════

    /// @notice Tracks the next valid nonce for each user address
    /// @dev Monotonically increasing; each successful execution increments by 1
    mapping(address => uint256) public nonces;

    /// @notice The address that will receive minted USDC on the destination chain
    /// @dev Stored as address, converted to bytes32 (left-padded) for CCTP calls
    address public immutable mintRecipient;

    // ═══════════════════════════════════════════════════════════════
    //                          EVENTS
    // ═══════════════════════════════════════════════════════════════

    /// @notice Emitted when a cross-chain intent is successfully executed and USDC burned
    /// @param user The intent originator whose USDC was burned
    /// @param amount The USDC amount burned and bridged (6 decimal precision)
    /// @param destinationDomain The CCTP domain of the target chain
    /// @param nonce The user's intent nonce consumed by this execution
    /// @param cctpNonce The CCTP-assigned burn nonce for off-chain attestation tracking
    event IntentExecuted(
        address indexed user, uint256 amount, uint32 destinationDomain, uint256 nonce, uint64 cctpNonce
    );

    // ═══════════════════════════════════════════════════════════════
    //                          ERRORS
    // ═══════════════════════════════════════════════════════════════

    /// @notice Thrown when the intent's deadline timestamp has passed
    error IntentExpired();

    /// @notice Thrown when the recovered EIP-712 signer does not match the intent's user field
    error InvalidSignature();

    /// @notice Thrown when the intent's nonce does not match the user's current expected nonce
    error InvalidNonce();

    // ═══════════════════════════════════════════════════════════════
    //                        CONSTRUCTOR
    // ═══════════════════════════════════════════════════════════════

    /// @notice Initializes the BaseReceiver with EIP-712 domain parameters and mint recipient
    /// @param _mintRecipient Address of the ArbExecutor or solver on the destination chain
    ///        that will receive the minted USDC after CCTP attestation
    constructor(
        address _mintRecipient
    ) EIP712("CircleForwarder", "1") {
        mintRecipient = _mintRecipient;
    }

    // ═══════════════════════════════════════════════════════════════
    //                      EXTERNAL FUNCTIONS
    // ═══════════════════════════════════════════════════════════════

    /// @notice Validates an EIP-712 signed intent, pulls USDC from the user, and burns via CCTP
    /// @dev Execution flow:
    ///      1. Verify temporal validity (deadline not passed)
    ///      2. Verify sequential nonce matches expected value
    ///      3. Recover signer from EIP-712 typed data hash using ECDSA
    ///      4. Validate recovered signer matches declared intent user
    ///      5. Increment nonce for replay protection
    ///      6. Pull USDC from user via transferFrom (requires prior approval)
    ///      7. Approve Circle TokenMessenger to spend pulled USDC
    ///      8. Burn USDC via CCTP depositForBurn for cross-chain minting
    ///      9. Emit IntentExecuted event for solver tracking
    ///
    ///      The caller (solver) sponsors all gas. The user only provides a signature.
    ///
    /// @param intent The cross-chain intent struct containing user parameters
    /// @param signature The EIP-712 signature bytes (r, s, v packed as 65 bytes)
    /// @return cctpNonce The CCTP burn nonce for off-chain attestation tracking
    function executeIntent(
        CrossChainIntent calldata intent,
        bytes calldata signature
    ) external returns (uint64 cctpNonce) {
        // Step 1: Verify temporal validity — reject expired intents
        if (block.timestamp > intent.deadline) revert IntentExpired();

        // Step 2: Verify sequential nonce — reject out-of-order or replayed intents
        if (intent.nonce != nonces[intent.user]) revert InvalidNonce();

        // Step 3: Recover signer from EIP-712 typed data hash
        bytes32 structHash = IntentLib.hashIntent(intent);
        bytes32 digest = _hashTypedDataV4(structHash);
        address signer = ECDSA.recover(digest, signature);

        // Step 4: Validate recovered signer matches declared user
        if (signer != intent.user) revert InvalidSignature();

        // Step 5: Increment nonce — consumes this nonce value permanently
        unchecked {
            nonces[intent.user]++;
        }

        // Step 6: Pull USDC from user into this contract
        IERC20(Addresses.BASE_USDC).transferFrom(intent.user, address(this), intent.amount);

        // Step 7: Approve Circle TokenMessenger to spend the pulled USDC
        IERC20(Addresses.BASE_USDC).approve(Addresses.BASE_TOKEN_MESSENGER, intent.amount);

        // Step 8: Burn USDC via CCTP for cross-chain minting on destination domain
        cctpNonce = ITokenMessenger(Addresses.BASE_TOKEN_MESSENGER)
            .depositForBurn(
                intent.amount, intent.destinationDomain, _addressToBytes32(mintRecipient), Addresses.BASE_USDC
            );

        // Step 9: Emit execution event for off-chain solver tracking
        emit IntentExecuted(intent.user, intent.amount, intent.destinationDomain, intent.nonce, cctpNonce);
    }

    /// @notice Returns the EIP-712 domain separator for off-chain signature construction
    /// @dev Exposed for external callers and test contracts to reconstruct the typed data hash
    /// @return The keccak256 domain separator hash
    function getDomainSeparator() external view returns (bytes32) {
        return _domainSeparatorV4();
    }

    // ═══════════════════════════════════════════════════════════════
    //                      INTERNAL UTILITIES
    // ═══════════════════════════════════════════════════════════════

    /// @notice Converts an Ethereum address to a bytes32 value (left-padded with zeros)
    /// @dev Required by CCTP's depositForBurn which expects mintRecipient as bytes32
    /// @param addr The address to convert
    /// @return The bytes32 representation with the address in the lower 20 bytes
    function _addressToBytes32(
        address addr
    ) internal pure returns (bytes32) {
        return bytes32(uint256(uint160(addr)));
    }
}
