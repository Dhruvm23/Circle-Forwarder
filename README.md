# Circle Forwarder — Gasless Cross-Chain Intent Relay

Circle Forwarder is an intent-based relay architecture that abstracts away blockchain bridges and gas fees. It allows users to execute complex cross-chain operations (like supplying USDC to Aave on Arbitrum from their wallet on Base) with a single click and zero gas fees.

## Overview

The system utilizes an **Intent-Based Architecture**. Instead of submitting standard transactions, users sign **EIP-712 Typed Data** intents. An off-chain solver captures these intents, pays the gas fees on the source chain, and fulfills the operation on the destination chain.

Under the hood, cross-chain messaging and liquidity transfer are handled natively via **Circle's Cross-Chain Transfer Protocol (CCTP)**.

### Features
* **Zero-Gas Experience:** Users pay no native gas tokens (ETH). All execution gas is sponsored by the off-chain solver.
* **Abstracted Bridging:** Bypasses complex bridge UIs. The user simply declares their desired end-state.
* **Single-Click UX:** A single MetaMask signature initiates the entire multi-chain sequence.
* **Atomic Settlement:** Leverages Circle CCTP to guarantee 1:1 USDC burn and mint without liquidity pool slippage.

## System Architecture
1. **Frontend (React + Vite + Ethers.js):** Captures user input and generates an EIP-712 signature.
2. **Solver API (Express + Ethers.js):** Off-chain engine that ingests signatures, broadcasts transactions to the source chain, and polls for events.
3. **Smart Contracts (Foundry):**
   - `BaseReceiver.sol`: Source chain contract that verifies the signature and burns USDC.
   - `ArbExecutor.sol`: Destination chain contract that receives minted USDC and supplies it to Aave V3.

## Local Development Setup

To run the full end-to-end system locally, we use Foundry's `anvil` to fork both Base and Arbitrum mainnets.

### 1. Prerequisites
- Node.js (v18+)
- Foundry (`forge`, `cast`, `anvil`)
- MetaMask installed in your browser

### 2. Start Local Blockchain Forks
Open two separate terminals to run the Base and Arbitrum forks:

```bash
# Terminal 1: Base Fork (Source)
anvil --fork-url https://mainnet.base.org --port 8544 --chain-id 84530

# Terminal 2: Arbitrum Fork (Destination)
anvil --fork-url https://arb1.arbitrum.io/rpc --port 8546 --chain-id 421610
```

### 3. Deploy Smart Contracts
Navigate to the `contracts` directory:
```bash
cd contracts
forge install

# Deploy BaseReceiver to Base (Port 8544)
forge create --broadcast --rpc-url http://localhost:8544 --private-key <SOLVER_PRIVATE_KEY> src/BaseReceiver.sol:BaseReceiver --constructor-args <SOLVER_ADDRESS>

# Deploy ArbExecutor to Arbitrum (Port 8546)
forge create --broadcast --rpc-url http://localhost:8546 --private-key <SOLVER_PRIVATE_KEY> src/ArbExecutor.sol:ArbExecutor --constructor-args <SOLVER_ADDRESS>
```
*Note: Update the addresses in your `.env` files with the deployed contract addresses.*

### 4. Start the Off-chain Solver
Navigate to the `solver` directory:
```bash
cd solver
npm install
npm start
```
The solver API will start on `http://localhost:4000`.

### 5. Start the Frontend
Navigate to the `frontend` directory:
```bash
cd frontend
npm install
npm run dev
```
Open `http://localhost:3000` in your browser. Connect MetaMask to the `Local Base Fork` network (`http://localhost:8544`, Chain ID: `84530`), sign the intent, and watch the relay execute!
