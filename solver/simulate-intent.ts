import { ethers } from "ethers";
import * as dotenv from "dotenv";

dotenv.config();

const BASE_RPC_URL = process.env.BASE_RPC_URL || "http://localhost:8545";
const BASE_RECEIVER_ADDRESS = process.env.BASE_RECEIVER_ADDRESS!;

// Test accounts from our local Anvil setup
const USER_KEY = "0x5de4111afa1a4b94908f83103eb1f1706367c2e68ca870fc3fb9a804cdab365a";
const SOLVER_KEY = process.env.SOLVER_PRIVATE_KEY!;

const ARBITRUM_DOMAIN = 3;
const MOCK_AAVE_VAULT = "0x794a61358D6845594F94dc1DB02A252b5b4814aD";
const BASE_USDC = "0x833589fCD6eDb6E08f4c7C32D4f71b54bdA02913";

async function main() {
    const provider = new ethers.JsonRpcProvider(BASE_RPC_URL);
    const userWallet = new ethers.Wallet(USER_KEY, provider);
    const solverWallet = new ethers.Wallet(SOLVER_KEY, provider);

    const intent = {
        user: userWallet.address,
        amount: ethers.parseUnits("10", 6), // 10 USDC
        destinationDomain: ARBITRUM_DOMAIN,
        destinationVault: MOCK_AAVE_VAULT,
        nonce: 0,
        deadline: Math.floor(Date.now() / 1000) + 3600
    };

    const domain = {
        name: "CircleForwarder",
        version: "1",
        chainId: 8453, // Base chain ID
        verifyingContract: BASE_RECEIVER_ADDRESS
    };

    const types = {
        CrossChainIntent: [
            { name: "user", type: "address" },
            { name: "amount", type: "uint256" },
            { name: "destinationDomain", type: "uint32" },
            { name: "destinationVault", type: "address" },
            { name: "nonce", type: "uint256" },
            { name: "deadline", type: "uint256" }
        ]
    };

    console.log(`[1] User ${userWallet.address} signing EIP-712 Intent off-chain...`);
    const signature = await userWallet.signTypedData(domain, types, intent);
    console.log(`    Signature generated!\n`);

    const usdcAbi = ["function approve(address spender, uint256 amount) external returns (bool)"];
    const usdcContract = new ethers.Contract(BASE_USDC, usdcAbi, userWallet);
    console.log(`[2] User pre-approving BaseReceiver to spend their USDC (simulating prior app usage)...`);
    await (await usdcContract.approve(BASE_RECEIVER_ADDRESS, intent.amount)).wait();
    console.log(`    Approval confirmed!\n`);

    const receiverAbi = ["function executeIntent(tuple(address user, uint256 amount, uint32 destinationDomain, address destinationVault, uint256 nonce, uint256 deadline) intent, bytes signature) external returns (uint64)"];
    const receiverContract = new ethers.Contract(BASE_RECEIVER_ADDRESS, receiverAbi, solverWallet);

    console.log(`[3] Solver ${solverWallet.address} submitting transaction to BaseReceiver (paying gas)...`);
    const tx = await receiverContract.executeIntent(intent, signature);
    console.log(`    Tx Hash: ${tx.hash}`);
    const receipt = await tx.wait();
    
    console.log(`\n✅ Intent successfully executed on Base (Block ${receipt.blockNumber})!`);
    console.log(`👉 The listener should pick this up immediately...`);
}

main().catch(console.error);
