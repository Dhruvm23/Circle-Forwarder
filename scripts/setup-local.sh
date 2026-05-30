#!/bin/bash
# ═══════════════════════════════════════════════════════════════
#  Circle Forwarder — Local Environment Bootstrap Script
#  Starts Anvil forks, deploys contracts, configures .env files
# ═══════════════════════════════════════════════════════════════

set -e

# ─── Colors ───
RED='\033[0;31m'
GREEN='\033[0;32m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color
BOLD='\033[1m'

# ─── Project Root ───
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_ROOT="$(dirname "$SCRIPT_DIR")"
CONTRACTS_DIR="$PROJECT_ROOT/contracts"
SOLVER_DIR="$PROJECT_ROOT/solver"

# ─── Anvil Default Accounts ───
# These are deterministic test accounts provided by Anvil with 10,000 ETH each
DEPLOYER_KEY="0xac0974bec39a17e36ba4a6b4d238ff944bacb478cbed5efcae784d7bf4f2ff80"
DEPLOYER_ADDRESS="0xf39Fd6e51aad88F6F4ce6aB8827279cffFb92266"

SOLVER_KEY="0x59c6995e998f97a5a0044966f0945389dc9e86dae88c7a8412f4603b6b78690d"
SOLVER_ADDRESS="0x70997970C51812dc3A010C7d01b50e0d17dc79C8"

USER_KEY="0x5de4111afa1a4b94908f83103eb1f1706367c2e68ca870fc3fb9a804cdab365a"
USER_ADDRESS="0x3C44CdDdB6a900fa2b585dd299e03d12FA4293BC"

# ─── RPC Configuration ───
BASE_FORK_URL="https://mainnet.base.org"
ARB_FORK_URL="https://arb1.arbitrum.io/rpc"
BASE_LOCAL_RPC="http://localhost:8545"
ARB_LOCAL_RPC="http://localhost:8546"

# ─── USDC Addresses ───
BASE_USDC="0x833589fCD6eDb6E08f4c7C32D4f71b54bdA02913"

echo ""
echo -e "${CYAN}╔════════════════════════════════════════════════════════════════╗${NC}"
echo -e "${CYAN}║     ${BOLD}CIRCLE FORWARDER — LOCAL ENVIRONMENT BOOTSTRAP${NC}${CYAN}          ║${NC}"
echo -e "${CYAN}║     Zero-Cost Sandbox via Foundry Anvil Engine               ║${NC}"
echo -e "${CYAN}╚════════════════════════════════════════════════════════════════╝${NC}"
echo ""

# ═══════════════════════════════════════════════════════════════
#  STEP 1: Kill any existing Anvil instances
# ═══════════════════════════════════════════════════════════════
echo -e "${YELLOW}[1/6]${NC} Cleaning up existing Anvil instances..."
pkill -f "anvil" 2>/dev/null || true
sleep 1

# ═══════════════════════════════════════════════════════════════
#  STEP 2: Start Anvil fork of Base (port 8545)
# ═══════════════════════════════════════════════════════════════
echo -e "${YELLOW}[2/6]${NC} Starting Anvil fork of Base mainnet on port 8545..."
anvil --fork-url "$BASE_FORK_URL" --port 8545 --chain-id 84530 --silent &
ANVIL_BASE_PID=$!
echo -e "       PID: ${BLUE}$ANVIL_BASE_PID${NC}"

# ═══════════════════════════════════════════════════════════════
#  STEP 3: Start Anvil fork of Arbitrum (port 8546)
# ═══════════════════════════════════════════════════════════════
echo -e "${YELLOW}[3/6]${NC} Starting Anvil fork of Arbitrum mainnet on port 8546..."
anvil --fork-url "$ARB_FORK_URL" --port 8546 --chain-id 42161 --silent &
ANVIL_ARB_PID=$!
echo -e "       PID: ${BLUE}$ANVIL_ARB_PID${NC}"

# Wait for Anvil nodes to be ready
echo -e "       Waiting for RPC nodes to initialize..."
sleep 5

# Verify both nodes are responsive
if ! cast block-number --rpc-url "$BASE_LOCAL_RPC" > /dev/null 2>&1; then
    echo -e "${RED}ERROR: Base Anvil fork not responding on port 8545${NC}"
    exit 1
fi
if ! cast block-number --rpc-url "$ARB_LOCAL_RPC" > /dev/null 2>&1; then
    echo -e "${RED}ERROR: Arbitrum Anvil fork not responding on port 8546${NC}"
    exit 1
fi
echo -e "       ${GREEN}✓ Both Anvil forks are running${NC}"

# ═══════════════════════════════════════════════════════════════
#  STEP 4: Deploy BaseReceiver to Base fork
# ═══════════════════════════════════════════════════════════════
echo ""
echo -e "${YELLOW}[4/6]${NC} Deploying BaseReceiver to Base fork (localhost:8545)..."

export BASE_RPC_URL="$BASE_LOCAL_RPC"
export ARB_RPC_URL="$ARB_LOCAL_RPC"

BASE_RECEIVER_OUTPUT=$(MINT_RECIPIENT=$SOLVER_ADDRESS forge create \
    src/BaseReceiver.sol:BaseReceiver \
    \
    --rpc-url "$BASE_LOCAL_RPC" \
    --private-key "$DEPLOYER_KEY" \
    --root "$CONTRACTS_DIR" \
    --broadcast \
    --constructor-args "$SOLVER_ADDRESS" \
    2>&1)

BASE_RECEIVER_ADDRESS=$(echo "$BASE_RECEIVER_OUTPUT" | grep "Deployed to:" | awk '{print $3}')

if [ -z "$BASE_RECEIVER_ADDRESS" ]; then
    echo -e "${RED}ERROR: Failed to deploy BaseReceiver${NC}"
    echo "$BASE_RECEIVER_OUTPUT"
    exit 1
fi

echo -e "       ${GREEN}✓ BaseReceiver deployed at: ${BOLD}$BASE_RECEIVER_ADDRESS${NC}"

# ═══════════════════════════════════════════════════════════════
#  STEP 5: Deploy ArbExecutor to Arbitrum fork
# ═══════════════════════════════════════════════════════════════
echo -e "${YELLOW}[5/6]${NC} Deploying ArbExecutor to Arbitrum fork (localhost:8546)..."

ARB_EXECUTOR_OUTPUT=$(SOLVER_ADDRESS=$SOLVER_ADDRESS forge create \
    src/ArbExecutor.sol:ArbExecutor \
    \
    --rpc-url "$ARB_LOCAL_RPC" \
    --private-key "$DEPLOYER_KEY" \
    --root "$CONTRACTS_DIR" \
    --broadcast \
    --constructor-args "$SOLVER_ADDRESS" \
    2>&1)

ARB_EXECUTOR_ADDRESS=$(echo "$ARB_EXECUTOR_OUTPUT" | grep "Deployed to:" | awk '{print $3}')

if [ -z "$ARB_EXECUTOR_ADDRESS" ]; then
    echo -e "${RED}ERROR: Failed to deploy ArbExecutor${NC}"
    echo "$ARB_EXECUTOR_OUTPUT"
    exit 1
fi

echo -e "       ${GREEN}✓ ArbExecutor deployed at: ${BOLD}$ARB_EXECUTOR_ADDRESS${NC}"

# ═══════════════════════════════════════════════════════════════
#  STEP 6: Fund test user with USDC on Base fork
# ═══════════════════════════════════════════════════════════════
echo -e "${YELLOW}[6/6]${NC} Funding test user with 1000 USDC on Base fork..."

# Use cast to set the user's USDC balance on the Base fork
# USDC uses a storage slot at mapping(address => uint256) at slot 9 for balances
# We use `cast rpc anvil_setBalance` or deal via direct storage manipulation
# Simpler: use `cast send` from a whale, or `cast rpc anvil_impersonateAccount`

# Impersonate the USDC contract and mint (using Anvil's cheat codes)
# Actually, the simplest way is to use `cast rpc hardhat_setBalance` equivalent
# For USDC specifically, we'll impersonate a whale and transfer
# The Circle Master Minter has USDC: let's just use anvil_setStorageAt

# For Base USDC (a proxy), the balance slot for address A is:
# keccak256(abi.encode(A, 9)) for the standard USDC implementation
SLOT=$(cast index address "$USER_ADDRESS" 9)
BALANCE_HEX=$(cast to-hexdata "0x$(printf '%064x' 1000000000)") # 1000 USDC (6 decimals)

cast rpc anvil_setStorageAt "$BASE_USDC" "$SLOT" "0x000000000000000000000000000000000000000000000000000000003B9ACA00" \
    --rpc-url "$BASE_LOCAL_RPC" > /dev/null 2>&1

USER_BALANCE=$(cast call "$BASE_USDC" "balanceOf(address)(uint256)" "$USER_ADDRESS" --rpc-url "$BASE_LOCAL_RPC" 2>/dev/null)
echo -e "       ${GREEN}✓ User USDC balance: $USER_BALANCE (raw units, 6 decimals)${NC}"

# ═══════════════════════════════════════════════════════════════
#  WRITE CONFIGURATION FILES
# ═══════════════════════════════════════════════════════════════
echo ""
echo -e "${CYAN}Writing configuration files...${NC}"

# Write solver/.env
cat > "$SOLVER_DIR/.env" <<EOF
# ═══════════════════════════════════════════════════════════════
#  Auto-generated by setup-local.sh — $(date)
# ═══════════════════════════════════════════════════════════════

# Local Anvil Fork RPC Endpoints
BASE_RPC_URL=$BASE_LOCAL_RPC
ARB_RPC_URL=$ARB_LOCAL_RPC

# Solver Wallet (Anvil test account #1)
SOLVER_PRIVATE_KEY=$SOLVER_KEY

# Deployed Contract Addresses
BASE_RECEIVER_ADDRESS=$BASE_RECEIVER_ADDRESS
ARB_EXECUTOR_ADDRESS=$ARB_EXECUTOR_ADDRESS

# Polling Configuration
POLLING_INTERVAL_MS=3000
EOF

echo -e "       ${GREEN}✓ solver/.env written${NC}"

# ═══════════════════════════════════════════════════════════════
#  SUMMARY
# ═══════════════════════════════════════════════════════════════
echo ""
echo -e "${CYAN}╔════════════════════════════════════════════════════════════════╗${NC}"
echo -e "${CYAN}║                   ${BOLD}DEPLOYMENT COMPLETE${NC}${CYAN}                          ║${NC}"
echo -e "${CYAN}╠════════════════════════════════════════════════════════════════╣${NC}"
echo -e "${CYAN}║${NC}                                                              ${CYAN}║${NC}"
echo -e "${CYAN}║${NC}  ${BOLD}Anvil Forks:${NC}                                                ${CYAN}║${NC}"
echo -e "${CYAN}║${NC}    Base     → $BASE_LOCAL_RPC (chain 8453)               ${CYAN}║${NC}"
echo -e "${CYAN}║${NC}    Arbitrum → $ARB_LOCAL_RPC (chain 42161)              ${CYAN}║${NC}"
echo -e "${CYAN}║${NC}                                                              ${CYAN}║${NC}"
echo -e "${CYAN}║${NC}  ${BOLD}Contracts:${NC}                                                  ${CYAN}║${NC}"
echo -e "${CYAN}║${NC}    BaseReceiver → ${GREEN}$BASE_RECEIVER_ADDRESS${NC}  ${CYAN}║${NC}"
echo -e "${CYAN}║${NC}    ArbExecutor  → ${GREEN}$ARB_EXECUTOR_ADDRESS${NC}  ${CYAN}║${NC}"
echo -e "${CYAN}║${NC}                                                              ${CYAN}║${NC}"
echo -e "${CYAN}║${NC}  ${BOLD}Test Accounts (Anvil defaults):${NC}                              ${CYAN}║${NC}"
echo -e "${CYAN}║${NC}    Deployer → $DEPLOYER_ADDRESS  ${CYAN}║${NC}"
echo -e "${CYAN}║${NC}    Solver   → $SOLVER_ADDRESS  ${CYAN}║${NC}"
echo -e "${CYAN}║${NC}    User     → $USER_ADDRESS  ${CYAN}║${NC}"
echo -e "${CYAN}║${NC}                                                              ${CYAN}║${NC}"
echo -e "${CYAN}║${NC}  ${BOLD}Next Steps:${NC}                                                  ${CYAN}║${NC}"
echo -e "${CYAN}║${NC}    1. cd solver  && npm install && npx tsx listener.ts        ${CYAN}║${NC}"
echo -e "${CYAN}║${NC}    2. cd frontend && npm install && npm run dev               ${CYAN}║${NC}"
echo -e "${CYAN}║${NC}                                                              ${CYAN}║${NC}"
echo -e "${CYAN}║${NC}  ${YELLOW}To stop Anvil: pkill -f anvil${NC}                                 ${CYAN}║${NC}"
echo -e "${CYAN}║${NC}                                                              ${CYAN}║${NC}"
echo -e "${CYAN}╚════════════════════════════════════════════════════════════════╝${NC}"
echo ""

# ═══════════════════════════════════════════════════════════════
#  STEP 7: Fund Solver with USDC on Arbitrum fork
# ═══════════════════════════════════════════════════════════════
echo -e "${YELLOW}[7/7]${NC} Funding Solver with 1000 USDC on Arbitrum fork..."

ARB_USDC="0xaf88d065e77c8cC2239327C5EDb3A432268e5831"
SLOT_ARB=$(cast index address "$SOLVER_ADDRESS" 9)
cast rpc anvil_setStorageAt "$ARB_USDC" "$SLOT_ARB" "0x000000000000000000000000000000000000000000000000000000003B9ACA00" \
    --rpc-url "$ARB_LOCAL_RPC" > /dev/null 2>&1

SOLVER_BALANCE=$(cast call "$ARB_USDC" "balanceOf(address)(uint256)" "$SOLVER_ADDRESS" --rpc-url "$ARB_LOCAL_RPC" 2>/dev/null)
echo -e "       ${GREEN}✓ Solver USDC balance: $SOLVER_BALANCE (raw units, 6 decimals)${NC}"
