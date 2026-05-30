/**
 * ═══════════════════════════════════════════════════════════════
 *  Circle Forwarder — Off-Chain Solver Engine
 *  Express API + Event Polling Hybrid Architecture
 * ═══════════════════════════════════════════════════════════════
 *
 *  This solver engine runs two concurrent subsystems:
 *
 *  1. HTTP API (Express) — Receives signed intents from the React frontend
 *     via POST /api/submit-intent. The solver validates the signature,
 *     submits it to BaseReceiver on Base (paying gas on behalf of the user),
 *     and returns the transaction receipt.
 *
 *  2. Event Poller — Continuously scans the Base blockchain for
 *     IntentExecuted events. When detected, the solver automatically
 *     fulfills the intent on Arbitrum by calling ArbExecutor.fulfillIntent,
 *     which supplies the user's USDC into Aave V3.
 *
 *  This is a fully production-grade intent relay architecture.
 *  The user signs EIP-712 data (zero gas), and the solver sponsors everything.
 */
import { ethers } from "ethers";
import * as dotenv from "dotenv";
import express from "express";
import cors from "cors";
dotenv.config();
const BASE_RPC_URL: string = process.env.BASE_RPC_URL || "http://localhost:8544";
const ARB_RPC_URL: string = process.env.ARB_RPC_URL || "http://localhost:8546";
const SOLVER_PRIVATE_KEY: string | undefined = process.env.SOLVER_PRIVATE_KEY;
const BASE_RECEIVER_ADDRESS: string | undefined = process.env.BASE_RECEIVER_ADDRESS;
const ARB_EXECUTOR_ADDRESS: string | undefined = process.env.ARB_EXECUTOR_ADDRESS;
const POLLING_INTERVAL_MS: number = parseInt(process.env.POLLING_INTERVAL_MS || "3000", 10);
const API_PORT: number = parseInt(process.env.API_PORT || "4000", 10);
const BASE_RECEIVER_ABI: string[] = [
    "function executeIntent(tuple(address user, uint256 amount, uint32 destinationDomain, address destinationVault, uint256 nonce, uint256 deadline) intent, bytes signature) external returns (uint64)",
    "function nonces(address user) external view returns (uint256)",
    "event IntentExecuted(address indexed user, uint256 amount, uint32 destinationDomain, uint256 nonce, uint64 cctpNonce)",
];
const ARB_EXECUTOR_ABI: string[] = [
    "function fulfillIntent(address user, uint256 amount, address vault) external",
];
const ERC20_ABI: string[] = [
    "function approve(address spender, uint256 amount) external returns (bool)",
    "function balanceOf(address account) external view returns (uint256)",
    "function allowance(address owner, address spender) external view returns (uint256)",
];
const ARB_USDC: string = "0xaf88d065e77c8cC2239327C5EDb3A432268e5831";
const ARB_AAVE_V3_POOL: string = "0x794a61358D6845594F94dc1DB02A252b5b4814aD";
const ARBITRUM_CCTP_DOMAIN: number = 3;
function logTimestamp(): string {
    return new Date().toISOString().replace("T", " ").substring(0, 19);
}
function logInfo(message: string): void {
    console.log(`[${logTimestamp()}] [INFO]    ${message}`);
}
function logSuccess(message: string): void {
    console.log(`[${logTimestamp()}] [SUCCESS] ${message}`);
}
function logWarn(message: string): void {
    console.warn(`[${logTimestamp()}] [WARN]    ${message}`);
}
function logError(message: string, error?: unknown): void {
    console.error(`[${logTimestamp()}] [ERROR]   ${message}`);
    if (error instanceof Error) {
        console.error(`[${logTimestamp()}] [ERROR]   Detail: ${error.message}`);
    }
}
interface IntentEvent {
    user: string;
    amount: bigint;
    destinationDomain: number;
    nonce: bigint;
    cctpNonce: bigint;
    blockNumber: number;
    transactionHash: string;
}
const processedTxHashes = new Set<string>();
async function processIntent(
    event: IntentEvent,
    arbExecutor: ethers.Contract,
    arbUSDC: ethers.Contract,
    arbExecutorAddress: string
): Promise<void> {
    if (processedTxHashes.has(event.transactionHash)) {
        logWarn(`Intent from tx ${event.transactionHash.slice(0, 12)}... already processed — skipping`);
        return;
    }
    processedTxHashes.add(event.transactionHash);
    logInfo("┌─────────────────────────────────────────────────────────┐");
    logInfo(`│  Processing Intent — Block #${event.blockNumber}`);
    logInfo(`│  User     : ${event.user}`);
    logInfo(`│  Amount   : ${ethers.formatUnits(event.amount, 6)} USDC`);
    logInfo(`│  Domain   : ${event.destinationDomain}`);
    logInfo(`│  Nonce    : ${event.nonce.toString()}`);
    logInfo(`│  CCTP#    : ${event.cctpNonce.toString()}`);
    logInfo(`│  Source Tx: ${event.transactionHash}`);
    logInfo("└─────────────────────────────────────────────────────────┘");
    if (event.destinationDomain !== ARBITRUM_CCTP_DOMAIN) {
        logWarn(`Skipping non-Arbitrum intent (domain: ${event.destinationDomain})`);
        return;
    }
    const solverAddress = await (arbExecutor.runner as ethers.Wallet).getAddress();
    const solverBalance: bigint = await arbUSDC.balanceOf(solverAddress);
    logInfo(`Solver USDC balance on Arbitrum: ${ethers.formatUnits(solverBalance, 6)}`);
    if (solverBalance < event.amount) {
        logError(`Insufficient solver USDC balance: ${ethers.formatUnits(solverBalance, 6)} < ${ethers.formatUnits(event.amount, 6)}`);
        return;
    }
    logInfo("Approving ArbExecutor to spend USDC on Arbitrum...");
    const approveTx = await arbUSDC.approve(arbExecutorAddress, event.amount);
    const approveReceipt = await approveTx.wait();
    logSuccess(`USDC approval confirmed — Tx: ${approveReceipt!.hash}`);
    logInfo("Submitting fulfillIntent transaction to Arbitrum...");
    const fulfillTx = await arbExecutor.fulfillIntent(
        event.user,
        event.amount,
        ARB_AAVE_V3_POOL
    );
    const fulfillReceipt = await fulfillTx.wait();
    logSuccess(`Intent fulfilled — Tx: ${fulfillReceipt!.hash}`);
    logSuccess(`${ethers.formatUnits(event.amount, 6)} USDC supplied to Aave V3 for ${event.user}`);
}
async function main(): Promise<void> {
    if (!SOLVER_PRIVATE_KEY) {
        throw new Error("SOLVER_PRIVATE_KEY environment variable is not set");
    }
    if (!BASE_RECEIVER_ADDRESS) {
        throw new Error("BASE_RECEIVER_ADDRESS environment variable is not set");
    }
    if (!ARB_EXECUTOR_ADDRESS) {
        throw new Error("ARB_EXECUTOR_ADDRESS environment variable is not set");
    }
    const baseProvider = new ethers.JsonRpcProvider(BASE_RPC_URL);
    const arbProvider = new ethers.JsonRpcProvider(ARB_RPC_URL);
    const baseSolverWallet = new ethers.Wallet(SOLVER_PRIVATE_KEY, baseProvider);
    const arbSolverWallet = new ethers.Wallet(SOLVER_PRIVATE_KEY, arbProvider);
    const baseReceiver = new ethers.Contract(
        BASE_RECEIVER_ADDRESS,
        BASE_RECEIVER_ABI,
        baseSolverWallet
    );
    const baseReceiverReadOnly = new ethers.Contract(
        BASE_RECEIVER_ADDRESS,
        BASE_RECEIVER_ABI,
        baseProvider
    );
    const arbExecutor = new ethers.Contract(
        ARB_EXECUTOR_ADDRESS,
        ARB_EXECUTOR_ABI,
        arbSolverWallet
    );
    const arbUSDC = new ethers.Contract(ARB_USDC, ERC20_ABI, arbSolverWallet);
    console.log("");
    console.log("╔════════════════════════════════════════════════════════════════╗");
    console.log("║       CIRCLE FORWARDER — SOLVER ENGINE v0.2.0                ║");
    console.log("║       Live HTTP API + Event Polling Architecture              ║");
    console.log("╠════════════════════════════════════════════════════════════════╣");
    console.log(`║  Solver Address   : ${baseSolverWallet.address}  ║`);
    console.log(`║  Base RPC         : ${BASE_RPC_URL.padEnd(44)} ║`);
    console.log(`║  Arbitrum RPC     : ${ARB_RPC_URL.padEnd(44)} ║`);
    console.log(`║  BaseReceiver     : ${BASE_RECEIVER_ADDRESS.padEnd(44)} ║`);
    console.log(`║  ArbExecutor      : ${ARB_EXECUTOR_ADDRESS.padEnd(44)} ║`);
    console.log(`║  API Port         : ${String(API_PORT).padEnd(44)} ║`);
    console.log(`║  Polling Interval : ${(POLLING_INTERVAL_MS + "ms").padEnd(44)} ║`);
    console.log("╚════════════════════════════════════════════════════════════════╝");
    console.log("");
    const app = express();
    app.use(cors());
    app.use(express.json());
    app.get("/api/health", (_req, res) => {
        res.json({
            status: "operational",
            solver: baseSolverWallet.address,
            baseReceiver: BASE_RECEIVER_ADDRESS,
            arbExecutor: ARB_EXECUTOR_ADDRESS,
            uptime: process.uptime(),
        });
    });
    app.get("/api/nonce/:address", async (req, res) => {
        try {
            const nonce = await baseReceiver.nonces(req.params.address);
            res.json({ nonce: Number(nonce) });
        } catch (error) {
            logError("Failed to fetch nonce", error);
            res.status(500).json({ error: "Failed to fetch nonce" });
        }
    });
    /**
     * POST /api/submit-intent
     *
     * This is the core endpoint. The React frontend sends:
     *   - intent: { user, amount, destinationDomain, destinationVault, nonce, deadline }
     *   - signature: the EIP-712 signature string from MetaMask
     *
     * The solver then:
     *   1. Submits the intent + signature to BaseReceiver.executeIntent() on Base
     *   2. Pays all gas costs (the user pays nothing)
     *   3. Returns the transaction hash and block number
     *
     * The event poller (Subsystem 2) will automatically detect the resulting
     * IntentExecuted event and fulfill it on Arbitrum.
     */
    app.post("/api/submit-intent", async (req, res) => {
        try {
            const { intent, signature } = req.body;
            if (!intent || !signature) {
                res.status(400).json({ error: "Missing intent or signature" });
                return;
            }
            logInfo("═══ INCOMING INTENT VIA HTTP API ═══");
            logInfo(`User     : ${intent.user}`);
            logInfo(`Amount   : ${ethers.formatUnits(intent.amount, 6)} USDC`);
            logInfo(`Domain   : ${intent.destinationDomain}`);
            logInfo(`Nonce    : ${intent.nonce}`);
            logInfo(`Deadline : ${intent.deadline}`);
            logInfo(`Signature: ${signature.slice(0, 22)}...${signature.slice(-8)}`);
            const intentStruct = {
                user: intent.user,
                amount: BigInt(intent.amount),
                destinationDomain: intent.destinationDomain,
                destinationVault: intent.destinationVault,
                nonce: intent.nonce,
                deadline: intent.deadline,
            };
            logInfo("Submitting intent to BaseReceiver on Base (solver paying gas)...");
            const tx = await baseReceiver.executeIntent(intentStruct, signature);
            logInfo(`Tx broadcast: ${tx.hash}`);
            const receipt = await tx.wait();
            logSuccess(`Intent executed on Base — Block #${receipt!.blockNumber} | Tx: ${receipt!.hash}`);
            let cctpNonce = "0";
            for (const log of receipt!.logs) {
                try {
                    const parsed = baseReceiverReadOnly.interface.parseLog({
                        topics: log.topics as string[],
                        data: log.data,
                    });
                    if (parsed && parsed.name === "IntentExecuted") {
                        cctpNonce = parsed.args[4].toString();
                    }
                } catch {
                }
            }
            res.json({
                success: true,
                transactionHash: receipt!.hash,
                blockNumber: receipt!.blockNumber,
                cctpNonce,
                message: `Intent executed on Base. Solver is now fulfilling on Arbitrum...`,
            });
        } catch (error) {
            const errorMsg = (error as Error).message || "Unknown error";
            logError("Failed to submit intent", error);
            let userMessage = errorMsg;
            if (errorMsg.includes("InvalidSignature")) {
                userMessage = "EIP-712 signature verification failed — the signer does not match the intent user";
            } else if (errorMsg.includes("InvalidNonce")) {
                userMessage = "Intent nonce mismatch — fetch the latest nonce and retry";
            } else if (errorMsg.includes("IntentExpired")) {
                userMessage = "Intent deadline has passed — sign a new intent with a future deadline";
            } else if (errorMsg.includes("insufficient funds") || errorMsg.includes("ERC20: transfer amount exceeds balance")) {
                userMessage = "User does not have enough USDC balance on Base";
            } else if (errorMsg.includes("ERC20: insufficient allowance")) {
                userMessage = "User has not approved BaseReceiver to spend their USDC — approval required first";
            }
            res.status(500).json({ error: userMessage });
        }
    });
    app.listen(API_PORT, () => {
        logSuccess(`HTTP API listening on http://localhost:${API_PORT}`);
        logInfo("Endpoints:");
        logInfo("  GET  /api/health           — Solver status");
        logInfo("  GET  /api/nonce/:address   — Fetch user nonce");
        logInfo("  POST /api/submit-intent    — Submit signed intent for execution");
    });
    let lastProcessedBlock: number = await baseProvider.getBlockNumber();
    logInfo(`Event poller started — scanning from Base block #${lastProcessedBlock}`);
    let isRunning = true;
    const shutdown = (signal: string): void => {
        logWarn(`${signal} received — initiating graceful shutdown...`);
        isRunning = false;
    };
    process.on("SIGINT", () => shutdown("SIGINT"));
    process.on("SIGTERM", () => shutdown("SIGTERM"));
    while (isRunning) {
        try {
            const currentBlock: number = await baseProvider.getBlockNumber();
            if (currentBlock > lastProcessedBlock) {
                const fromBlock = lastProcessedBlock + 1;
                const toBlock = currentBlock;
                const filter = baseReceiverReadOnly.filters.IntentExecuted();
                const rawEvents = await baseReceiverReadOnly.queryFilter(filter, fromBlock, toBlock);
                if (rawEvents.length > 0) {
                    logInfo(`Event poller found ${rawEvents.length} IntentExecuted event(s) in blocks ${fromBlock}→${toBlock}`);
                }
                for (const rawEvent of rawEvents) {
                    const eventLog = rawEvent as ethers.EventLog;
                    const parsedLog = baseReceiverReadOnly.interface.parseLog({
                        topics: eventLog.topics as string[],
                        data: eventLog.data,
                    });
                    if (!parsedLog) {
                        logWarn("Failed to parse event log — skipping");
                        continue;
                    }
                    const intentEvent: IntentEvent = {
                        user: parsedLog.args[0] as string,
                        amount: parsedLog.args[1] as bigint,
                        destinationDomain: Number(parsedLog.args[2]),
                        nonce: parsedLog.args[3] as bigint,
                        cctpNonce: parsedLog.args[4] as bigint,
                        blockNumber: eventLog.blockNumber,
                        transactionHash: eventLog.transactionHash,
                    };
                    try {
                        await processIntent(intentEvent, arbExecutor, arbUSDC, ARB_EXECUTOR_ADDRESS);
                    } catch (relayError) {
                        logError(`Failed to relay intent for ${intentEvent.user}`, relayError);
                    }
                }
                lastProcessedBlock = currentBlock;
            }
        } catch (pollError) {
            logError("Polling cycle encountered an error", pollError);
        }
        await new Promise<void>((resolve) => setTimeout(resolve, POLLING_INTERVAL_MS));
    }
    logInfo("Solver engine stopped — goodbye.");
    process.exit(0);
}
main().catch((error: unknown) => {
    logError("Fatal error — engine crashed", error);
    process.exit(1);
});
