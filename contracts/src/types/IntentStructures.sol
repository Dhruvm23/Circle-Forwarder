// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/// @title IntentStructures — Cross-Chain Intent Type Definitions
/// @notice Defines the canonical EIP-712 typed data structures for cross-chain intent execution
/// @dev All structs and type hashes used across the Circle Forwarder protocol

/// @notice Represents a user's cross-chain capital allocation intent
/// @param user The address of the intent originator
/// @param amount The quantity of USDC (6 decimals) to bridge and deploy
/// @param destinationDomain The CCTP domain identifier for the target chain
/// @param destinationVault The target DeFi vault/protocol address on the destination chain
/// @param nonce Sequential nonce for replay protection
/// @param deadline Unix timestamp after which the intent becomes invalid
struct CrossChainIntent {
    address user;
    uint256 amount;
    uint32 destinationDomain;
    address destinationVault;
    uint256 nonce;
    uint256 deadline;
}

/// @title IntentLib — EIP-712 Hashing Library for CrossChainIntent
/// @notice Provides type hash constants and hashing functions for EIP-712 compliance
library IntentLib {
    /// @notice EIP-712 type hash for the CrossChainIntent struct
    /// @dev keccak256 of the fully qualified type string per EIP-712 specification
    bytes32 internal constant INTENT_TYPEHASH = keccak256(
        "CrossChainIntent(address user,uint256 amount,uint32 destinationDomain,address destinationVault,uint256 nonce,uint256 deadline)"
    );

    /// @notice Computes the EIP-712 struct hash for a CrossChainIntent
    /// @param intent The intent struct to hash
    /// @return The keccak256 hash of the ABI-encoded struct with its type hash
    function hashIntent(
        CrossChainIntent memory intent
    ) internal pure returns (bytes32) {
        return keccak256(
            abi.encode(
                INTENT_TYPEHASH,
                intent.user,
                intent.amount,
                intent.destinationDomain,
                intent.destinationVault,
                intent.nonce,
                intent.deadline
            )
        );
    }
}
