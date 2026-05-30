// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/// @title Addresses — Production Contract Coordinates
/// @notice Canonical deployment addresses for Circle CCTP, USDC, and Aave V3 across supported networks
/// @dev All addresses point to live mainnet proxy contracts verified on-chain.
///      These coordinates are immutable references to production infrastructure.

library Addresses {
    // ═══════════════════════════════════════════════════════════════
    //                    BASE MAINNET (Chain ID: 8453)
    // ═══════════════════════════════════════════════════════════════

    /// @notice Circle's native USDC token on Base
    /// @dev Proxy contract — FiatTokenV2_2 implementation
    address internal constant BASE_USDC = 0x833589fCD6eDb6E08f4c7C32D4f71b54bdA02913;

    /// @notice Circle CCTP TokenMessenger proxy on Base
    /// @dev Handles depositForBurn calls for cross-chain USDC transfers
    address internal constant BASE_TOKEN_MESSENGER = 0x1682Ae6375C4E4A97e4B583BC394c861A46D8962;

    // ═══════════════════════════════════════════════════════════════
    //                  ARBITRUM MAINNET (Chain ID: 42161)
    // ═══════════════════════════════════════════════════════════════

    /// @notice Circle's native USDC token on Arbitrum
    /// @dev Proxy contract — FiatTokenV2_2 implementation
    address internal constant ARB_USDC = 0xaf88d065e77c8cC2239327C5EDb3A432268e5831;

    /// @notice Aave V3 Lending Pool proxy on Arbitrum
    /// @dev Entry point for supply, borrow, and liquidation operations
    address internal constant ARB_AAVE_V3_POOL = 0x794a61358D6845594F94dc1DB02A252b5b4814aD;

    // ═══════════════════════════════════════════════════════════════
    //                    CCTP DOMAIN IDENTIFIERS
    // ═══════════════════════════════════════════════════════════════

    /// @notice CCTP domain ID for Arbitrum One
    uint32 internal constant ARBITRUM_DOMAIN = 3;

    /// @notice CCTP domain ID for Base
    uint32 internal constant BASE_DOMAIN = 6;
}
