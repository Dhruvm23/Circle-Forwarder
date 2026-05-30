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

We have automated the entire environment setup! The system uses Foundry's `anvil` to create zero-cost local forks of the Base and Arbitrum mainnets, allowing you to test cross-chain execution without spending real money.

### 1. Prerequisites
- Node.js (v18+)
- Foundry (`forge`, `cast`, `anvil`)
- MetaMask installed in your browser

### 2. Automated Blockchain Bootstrap
Run the setup script from the root directory. This will start both blockchain forks in the background, deploy the smart contracts, configure your `.env` variables, and mint you 1,000,000 fake USDC for testing!

```bash
chmod +x scripts/setup-local.sh
./scripts/setup-local.sh
```

### 3. Start the Off-chain Solver API
Open a new terminal and navigate to the `solver` directory:
```bash
cd solver
npm install
npm start
```
The solver API will start on `http://localhost:4000`.

### 4. Start the React UI
Open another terminal and navigate to the `frontend` directory:
```bash
cd frontend
npm install
npm run dev
```
Open `http://localhost:5173` (or the port Vite provides) in your browser. 

Connect MetaMask, it will automatically prompt you to add the **Local Base Fork**. Sign your intent, and watch the relay execute in real-time!
