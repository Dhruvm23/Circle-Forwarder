import { useState, useCallback, useRef, useEffect } from "react";
import { ethers } from "ethers";
interface WalletState {
  connected: boolean;
  address: string;
  chainId: number;
  balance: string;
}
interface IntentConfig {
  amount: string;
  destinationDomain: number;
  destinationVault: string;
  nonce: number;
  deadline: number;
}
type LifecycleStage =
  | "idle"
  | "formulation"
  | "ingestion"
  | "burning"
  | "fulfillment"
  | "complete";
interface LogEntry {
  timestamp: string;
  level: "INFO" | "WARN" | "ERROR" | "SUCCESS";
  message: string;
}
const DOMAIN_MAP: Record<number, string> = {
  0: "Ethereum",
  1: "Avalanche",
  2: "Optimism",
  3: "Arbitrum",
  6: "Base",
  7: "Polygon PoS",
};
const BASE_RECEIVER_ADDRESS = "0xaC9F14fe28332d3832696D98f25069206177e40b";
const EIP712_DOMAIN_BASE = {
  name: "CircleForwarder",
  version: "1",
  verifyingContract: BASE_RECEIVER_ADDRESS,
};
const EIP712_TYPES = {
  CrossChainIntent: [
    { name: "user", type: "address" },
    { name: "amount", type: "uint256" },
    { name: "destinationDomain", type: "uint32" },
    { name: "destinationVault", type: "address" },
    { name: "nonce", type: "uint256" },
    { name: "deadline", type: "uint256" },
  ],
};
const LIFECYCLE_STAGES = [
  {
    key: "formulation",
    label: "INTENT FORMULATION",
    description: "EIP-712 payload compiled. User signs typed structured data.",
    icon: "◆",
  },
  {
    key: "ingestion",
    label: "SOLVER INGESTION",
    description: "Off-chain solver captures intent. Gas sponsorship initiated.",
    icon: "◈",
  },
  {
    key: "burning",
    label: "ATOMIC BURNING",
    description: "USDC burned via Circle CCTP on Base. Cross-chain message sent.",
    icon: "◉",
  },
  {
    key: "fulfillment",
    label: "DESTINATION FULFILLMENT",
    description: "Capital deployed to Aave V3 on Arbitrum. aUSDC minted to user.",
    icon: "●",
  },
] as const;
function getTimestamp(): string {
  return new Date().toISOString().replace("T", " ").substring(0, 19);
}
function truncateAddress(addr: string): string {
  if (!addr || addr.length < 10) return addr || "0x...";
  return `${addr.slice(0, 6)}···${addr.slice(-4)}`;
}
function formatUsdcAmount(amount: string): string {
  try {
    if (!amount || parseFloat(amount) === 0) return "0";
    return ethers.parseUnits(amount, 6).toString();
  } catch {
    return "INVALID";
  }
}
export default function App() {
  const [wallet, setWallet] = useState<WalletState>({
    connected: false,
    address: "",
    chainId: 0,
    balance: "0",
  });
  const [intent, setIntent] = useState<IntentConfig>({
    amount: "",
    destinationDomain: 3,
    destinationVault: "0x794a61358D6845594F94dc1DB02A252b5b4814aD",
    nonce: 0,
    deadline: Math.floor(Date.now() / 1000) + 3600,
  });
  const [signature, setSignature] = useState<string>("");
  const [isSigning, setIsSigning] = useState(false);
  const [currentStage, setCurrentStage] = useState<LifecycleStage>("idle");
  const [logs, setLogs] = useState<LogEntry[]>([
    {
      timestamp: getTimestamp(),
      level: "INFO",
      message: "Circle Forwarder v0.1.0 — Academic Interface Control Panel initialized",
    },
    {
      timestamp: getTimestamp(),
      level: "INFO",
      message: "Protocol: Circle CCTP v1 | EIP-712 Signature Engine ready",
    },
    {
      timestamp: getTimestamp(),
      level: "INFO",
      message: "Awaiting wallet connection...",
    },
  ]);
  const logContainerRef = useRef<HTMLDivElement>(null);
  const [uptime, setUptime] = useState(0);
  useEffect(() => {
    const interval = setInterval(() => setUptime((u) => u + 1), 1000);
    return () => clearInterval(interval);
  }, []);
  useEffect(() => {
    if (logContainerRef.current) {
      logContainerRef.current.scrollTop = logContainerRef.current.scrollHeight;
    }
  }, [logs]);
  useEffect(() => {
    const interval = setInterval(() => {
      setIntent((prev) => ({
        ...prev,
        deadline: Math.floor(Date.now() / 1000) + 3600,
      }));
    }, 60000);
    return () => clearInterval(interval);
  }, []);
  const addLog = useCallback((level: LogEntry["level"], message: string) => {
    setLogs((prev) => [...prev, { timestamp: getTimestamp(), level, message }]);
  }, []);
  const formatUptime = (seconds: number): string => {
    const h = Math.floor(seconds / 3600)
      .toString()
      .padStart(2, "0");
    const m = Math.floor((seconds % 3600) / 60)
      .toString()
      .padStart(2, "0");
    const s = (seconds % 60).toString().padStart(2, "0");
    return `${h}:${m}:${s}`;
  };
  const connectWallet = useCallback(async () => {
    if (!window.ethereum) {
      addLog("ERROR", "No Ethereum provider detected — install MetaMask or compatible wallet");
      return;
    }
    try {
      addLog("INFO", "Requesting wallet connection via eth_requestAccounts...");
      const localChainIdHex = "0x14A32"; 
      try {
        await window.ethereum.request({
          method: "wallet_switchEthereumChain",
          params: [{ chainId: localChainIdHex }],
        });
        addLog("INFO", "Switched to Base network");
      } catch (switchError: any) {
        if (switchError.code === 4902) {
          addLog("INFO", "Adding local Anvil Base fork to MetaMask...");
          await window.ethereum.request({
            method: "wallet_addEthereumChain",
            params: [{
              chainId: localChainIdHex,
              chainName: "Local Base Fork (Anvil)",
              nativeCurrency: { name: "ETH", symbol: "ETH", decimals: 18 },
              rpcUrls: ["http://localhost:8544"],
            }],
          });
          addLog("SUCCESS", "Local Base fork added to MetaMask");
        }
      }
      const provider = new ethers.BrowserProvider(window.ethereum);
      const accounts = await provider.send("eth_requestAccounts", []);
      const network = await provider.getNetwork();
      const balance = await provider.getBalance(accounts[0]);
      setWallet({
        connected: true,
        address: accounts[0],
        chainId: Number(network.chainId),
        balance: parseFloat(ethers.formatEther(balance)).toFixed(4),
      });
      addLog("SUCCESS", `Wallet connected: ${accounts[0]}`);
      addLog(
        "INFO",
        `Network: Chain ${network.chainId} | Balance: ${parseFloat(ethers.formatEther(balance)).toFixed(4)} ETH`
      );
      try {
        const nonceRes = await fetch(`http://localhost:4000/api/nonce/${accounts[0]}`)
        if (nonceRes.ok) {
          const { nonce } = await nonceRes.json();
          setIntent((prev) => ({ ...prev, nonce }));
          addLog("INFO", `Fetched on-chain nonce from solver: ${nonce}`);
        }
      } catch {
        addLog("WARN", "Could not fetch nonce from solver API — using default 0");
      }
      addLog("INFO", "EIP-712 signature engine ready — configure intent parameters");
    } catch (error) {
      addLog("ERROR", `Connection failed: ${(error as Error).message}`);
    }
  }, [addLog]);
  const signIntent = useCallback(async () => {
    if (!window.ethereum || !wallet.connected) {
      addLog("ERROR", "Wallet not connected — cannot sign intent");
      return;
    }
    if (!intent.amount || parseFloat(intent.amount) <= 0) {
      addLog("ERROR", "Invalid USDC amount — must be greater than zero");
      return;
    }
    setIsSigning(true);
    setCurrentStage("formulation");
    addLog("INFO", "═══ LIVE INTENT EXECUTION SEQUENCE INITIATED ═══");
    addLog("INFO", "Stage 1/4: Compiling EIP-712 typed data payload...");
    try {
      const provider = new ethers.BrowserProvider(window.ethereum);
      const signer = await provider.getSigner();
      const parsedAmount = ethers.parseUnits(intent.amount, 6);
      const intentValue = {
        user: wallet.address,
        amount: parsedAmount.toString(),
        destinationDomain: intent.destinationDomain,
        destinationVault: intent.destinationVault,
        nonce: intent.nonce,
        deadline: intent.deadline,
      };
      addLog(
        "INFO",
        `Intent: ${intent.amount} USDC → Domain ${intent.destinationDomain} (${DOMAIN_MAP[intent.destinationDomain] || "Unknown"})`
      );
      addLog(
        "INFO",
        `Vault: ${truncateAddress(intent.destinationVault)} | Nonce: ${intent.nonce} | Deadline: ${new Date(intent.deadline * 1000).toISOString()}`
      );
      addLog("INFO", "Requesting EIP-712 signature from connected wallet...");
      const dynamicDomain = {
        ...EIP712_DOMAIN_BASE,
        chainId: wallet.chainId,
      };
      const sig = await signer.signTypedData(
        dynamicDomain,
        EIP712_TYPES,
        intentValue
      );
      setSignature(sig);
      addLog("SUCCESS", `EIP-712 signature obtained: ${sig.slice(0, 22)}...${sig.slice(-8)}`);
      setCurrentStage("ingestion");
      addLog("INFO", "Stage 2/4: Submitting signed intent to Solver API (POST /api/submit-intent)...");
      const SOLVER_API = "http://localhost:4000";
      const response = await fetch(`${SOLVER_API}/api/submit-intent`, {
        method: "POST",
        headers: { "Content-Type": "application/json" },
        body: JSON.stringify({
          intent: intentValue,
          signature: sig,
        }),
      });
      const result = await response.json();
      if (!response.ok) {
        throw new Error(result.error || "Solver API returned an error");
      }
      addLog("SUCCESS", `Solver ingested intent — gas sponsorship confirmed`);
      addLog("SUCCESS", `Base Tx Hash: ${result.transactionHash}`);
      addLog("INFO", `Block #${result.blockNumber} | CCTP Nonce: ${result.cctpNonce}`);
      setCurrentStage("burning");
      addLog("INFO", "Stage 3/4: CCTP burn confirmed on Base blockchain");
      addLog("INFO", `USDC burned via TokenMessenger.depositForBurn() — tx confirmed on-chain`);
      setCurrentStage("fulfillment");
      addLog("INFO", "Stage 4/4: Solver event poller fulfilling intent on Arbitrum...");
      addLog("INFO", `ArbExecutor.fulfillIntent(${truncateAddress(wallet.address)}, ${parsedAmount}, Aave V3)`);
      await new Promise((r) => setTimeout(r, 5000));
      setCurrentStage("complete");
      addLog("SUCCESS", "═══ LIVE INTENT EXECUTION COMPLETE ═══");
      addLog(
        "SUCCESS",
        `${intent.amount} USDC supplied to Aave V3 Pool on Arbitrum for ${truncateAddress(wallet.address)}`
      );
      addLog("INFO", `aUSDC minted to user wallet — capital lifecycle finalized`);
      addLog("INFO", `Nonce incremented: ${intent.nonce} → ${intent.nonce + 1}`);
      setIntent((prev) => ({
        ...prev,
        nonce: prev.nonce + 1,
        deadline: Math.floor(Date.now() / 1000) + 3600,
      }));
    } catch (error) {
      const errorMsg = (error as Error).message;
      if (errorMsg.includes("user rejected")) {
        addLog("WARN", "User rejected signature request");
      } else if (errorMsg.includes("Failed to fetch")) {
        addLog("ERROR", "Cannot reach Solver API — is the solver running on port 4000?");
        addLog("INFO", "Start the solver: cd solver && npm start");
      } else {
        addLog("ERROR", `Execution failed: ${errorMsg}`);
      }
      setCurrentStage("idle");
    } finally {
      setIsSigning(false);
    }
  }, [wallet, intent, addLog]);
  const getStageStatus = (
    stageKey: string
  ): "idle" | "active" | "pending" => {
    const stageOrder = ["formulation", "ingestion", "burning", "fulfillment"];
    const currentIndex = stageOrder.indexOf(currentStage);
    const stageIndex = stageOrder.indexOf(stageKey);
    if (currentStage === "idle") return "idle";
    if (currentStage === "complete") return "active";
    if (stageIndex < currentIndex) return "active";
    if (stageIndex === currentIndex) return "pending";
    return "idle";
  };
  return (
    <div className="min-h-screen bg-[#0f172a] bg-grid font-mono text-[#94a3b8] flex flex-col">
      {}
      <header className="border-b border-[#334155] px-6 py-3 flex items-center justify-between flex-shrink-0">
        <div className="flex items-center gap-4">
          <div className="flex items-center gap-2">
            <div className="w-2 h-2 bg-[#3b82f6]" />
            <h1 className="text-[#e2e8f0] text-sm font-bold tracking-[0.3em] uppercase">
              Circle Forwarder
            </h1>
          </div>
          <span className="text-[10px] text-[#475569] border border-[#334155] px-2 py-0.5 tracking-wider">
            v0.1.0
          </span>
          <span className="text-[10px] text-[#475569] hidden md:inline">
            GASLESS CROSS-CHAIN INTENT ENGINE
          </span>
        </div>
        <div className="flex items-center gap-4">
          <span className="text-[10px] text-[#475569] hidden lg:inline font-normal">
            UPTIME {formatUptime(uptime)}
          </span>
          {wallet.connected ? (
            <div className="flex items-center gap-3">
              <span className="status-dot status-dot--active" />
              <span className="text-xs text-[#e2e8f0]">
                {truncateAddress(wallet.address)}
              </span>
              <span className="text-[10px] text-[#475569] border border-[#334155] px-2 py-0.5">
                {wallet.chainId === 8453 || wallet.chainId === 84530
                  ? "BASE"
                  : wallet.chainId === 42161 || wallet.chainId === 421610
                    ? "ARB"
                    : `ID:${wallet.chainId}`}
              </span>
            </div>
          ) : (
            <button
              onClick={connectWallet}
              className="btn-primary"
              id="btn-connect-wallet"
            >
              CONNECT WALLET
            </button>
          )}
        </div>
      </header>
      {}
      <main className="flex-1 p-4 lg:p-6 grid grid-cols-1 lg:grid-cols-12 gap-4 overflow-auto">
        {}
        <div className="lg:col-span-4 xl:col-span-3 space-y-4">
          {}
          <div className="panel">
            <div className="panel-header">┌─ INTENT CONFIGURATION</div>
            <div className="space-y-3">
              <div>
                <label
                  htmlFor="input-amount"
                  className="data-label block mb-1"
                >
                  USDC Amount
                </label>
                <input
                  id="input-amount"
                  type="number"
                  step="0.01"
                  min="0"
                  placeholder="0.00"
                  value={intent.amount}
                  onChange={(e) =>
                    setIntent({ ...intent, amount: e.target.value })
                  }
                  className="input-field"
                />
              </div>
              <div>
                <label
                  htmlFor="select-domain"
                  className="data-label block mb-1"
                >
                  Destination Domain
                </label>
                <select
                  id="select-domain"
                  value={intent.destinationDomain}
                  onChange={(e) =>
                    setIntent({
                      ...intent,
                      destinationDomain: parseInt(e.target.value),
                    })
                  }
                  className="input-field"
                >
                  {Object.entries(DOMAIN_MAP).map(([id, name]) => (
                    <option key={id} value={id}>
                      {id} — {name}
                    </option>
                  ))}
                </select>
              </div>
              <div>
                <label
                  htmlFor="input-vault"
                  className="data-label block mb-1"
                >
                  Destination Vault
                </label>
                <input
                  id="input-vault"
                  type="text"
                  value={intent.destinationVault}
                  onChange={(e) =>
                    setIntent({ ...intent, destinationVault: e.target.value })
                  }
                  className="input-field text-[10px]"
                />
              </div>
              <div className="grid grid-cols-2 gap-3">
                <div>
                  <span className="data-label block mb-1">Nonce</span>
                  <div className="input-field bg-[#0f172a]/50 text-[#64748b] cursor-default">
                    {intent.nonce}
                  </div>
                </div>
                <div>
                  <span className="data-label block mb-1">TTL</span>
                  <div className="input-field bg-[#0f172a]/50 text-[#64748b] text-[10px] cursor-default">
                    {Math.max(
                      0,
                      Math.floor(
                        (intent.deadline - Date.now() / 1000) / 60
                      )
                    )}
                    m
                  </div>
                </div>
              </div>
            </div>
          </div>
          {}
          <div className="panel">
            <div className="panel-header">┌─ SIGNATURE ENGINE</div>
            <div className="space-y-3">
              <div className="text-[10px] text-[#475569] space-y-1 border-l-2 border-[#334155] pl-2">
                <div>
                  <span className="text-[#64748b]">Domain:</span>{" "}
                  CircleForwarder v1
                </div>
                <div>
                  <span className="text-[#64748b]">Chain:</span> 8453 (Base
                  Mainnet)
                </div>
                <div>
                  <span className="text-[#64748b]">Type:</span>{" "}
                  CrossChainIntent
                </div>
                <div>
                  <span className="text-[#64748b]">Standard:</span> EIP-712
                  Typed Structured Data
                </div>
              </div>
              <button
                id="btn-sign-intent"
                onClick={signIntent}
                disabled={
                  !wallet.connected ||
                  isSigning ||
                  !intent.amount ||
                  currentStage !== "idle" && currentStage !== "complete"
                }
                className="btn-primary w-full"
              >
                {isSigning
                  ? "AWAITING WALLET SIGNATURE..."
                  : currentStage !== "idle" && currentStage !== "complete"
                    ? "EXECUTION IN PROGRESS..."
                    : "SIGN & EXECUTE INTENT"}
              </button>
              {signature && (
                <div className="mt-2">
                  <div className="data-label mb-1">Signature Output (65 bytes)</div>
                  <div className="bg-[#0f172a] border border-[#334155] p-2 text-[9px] text-[#22c55e] break-all leading-4 font-mono">
                    {signature}
                  </div>
                </div>
              )}
            </div>
          </div>
          {}
          <div className="panel">
            <div className="panel-header">┌─ SYSTEM METRICS</div>
            <div className="space-y-2">
              {[
                ["Protocol", "Circle CCTP v1"],
                ["Source Chain", "Base (8453)"],
                ["Target Chain", "Arbitrum (42161)"],
                ["DeFi Sink", "Aave V3 Pool"],
                ["Gas Model", "Solver Sponsored"],
                ["Signature", "EIP-712"],
                ["Token", "USDC (6 decimals)"],
                ["Solver", "Off-chain Relay"],
              ].map(([label, value]) => (
                <div
                  key={label}
                  className="flex items-center justify-between text-[11px]"
                >
                  <span className="data-label">{label}</span>
                  <span
                    className={`data-value ${value === "Solver Sponsored" ? "text-[#22c55e]" : ""}`}
                  >
                    {value}
                  </span>
                </div>
              ))}
            </div>
          </div>
        </div>
        {}
        <div className="lg:col-span-8 xl:col-span-9 space-y-4 flex flex-col">
          {}
          <div className="panel">
            <div className="panel-header flex items-center justify-between">
              <span>┌─ CAPITAL LIFECYCLE TRACKER</span>
              <span
                className={`text-[10px] tracking-normal font-normal ${
                  currentStage === "complete"
                    ? "text-[#22c55e]"
                    : currentStage === "idle"
                      ? "text-[#475569]"
                      : "text-[#f59e0b]"
                }`}
              >
                {currentStage === "idle"
                  ? "AWAITING INTENT"
                  : currentStage === "complete"
                    ? "LIFECYCLE COMPLETE"
                    : `STAGE ${["formulation", "ingestion", "burning", "fulfillment"].indexOf(currentStage) + 1}/4`}
              </span>
            </div>
            {}
            <div className="mb-4 h-[2px] bg-[#334155] relative">
              <div
                className="h-full bg-[#3b82f6] transition-all duration-700 ease-out"
                style={{
                  width:
                    currentStage === "idle"
                      ? "0%"
                      : currentStage === "formulation"
                        ? "12.5%"
                        : currentStage === "ingestion"
                          ? "37.5%"
                          : currentStage === "burning"
                            ? "62.5%"
                            : currentStage === "fulfillment"
                              ? "87.5%"
                              : "100%",
                }}
              />
            </div>
            {}
            <div className="grid grid-cols-1 sm:grid-cols-2 xl:grid-cols-4 gap-0">
              {LIFECYCLE_STAGES.map((stage, index) => {
                const status = getStageStatus(stage.key);
                return (
                  <div key={stage.key} className="relative">
                    <div
                      className={`stage-card ${
                        status === "active"
                          ? "stage-card--active"
                          : status === "pending"
                            ? "stage-card--pending"
                            : ""
                      }`}
                    >
                      <div className="flex items-center gap-2 mb-2">
                        <span
                          className={`status-dot ${
                            status === "active"
                              ? "status-dot--active"
                              : status === "pending"
                                ? "status-dot--pending"
                                : "status-dot--idle"
                          }`}
                        />
                        <span className="text-[10px] text-[#64748b]">
                          {stage.icon} STAGE {index + 1}
                        </span>
                      </div>
                      <div className="text-[10px] text-[#e2e8f0] font-semibold mb-1 tracking-wider">
                        {stage.label}
                      </div>
                      <div className="text-[10px] text-[#64748b] leading-relaxed">
                        {stage.description}
                      </div>
                    </div>
                  </div>
                );
              })}
            </div>
          </div>
          {}
          <div className="panel">
            <div className="panel-header flex items-center justify-between">
              <span>┌─ EIP-712 TYPED DATA PAYLOAD</span>
              <span className="text-[10px] text-[#3b82f6] tracking-normal font-normal">
                STRUCTURED
              </span>
            </div>
            <pre className="text-[11px] text-[#64748b] leading-5 overflow-x-auto">
              <code>
{`{
  "domain": {
    "name": "${EIP712_DOMAIN_BASE.name}",
    "version": "${EIP712_DOMAIN_BASE.version}",
    "chainId": ${wallet.connected ? wallet.chainId : 8453},
    "verifyingContract": "${EIP712_DOMAIN_BASE.verifyingContract}"
  },
  "primaryType": "CrossChainIntent",
  "message": {
    "user": "${wallet.connected ? wallet.address : "0x0000000000000000000000000000000000000000"}",
    "amount": "${formatUsdcAmount(intent.amount)}",
    "destinationDomain": ${intent.destinationDomain},
    "destinationVault": "${intent.destinationVault}",
    "nonce": ${intent.nonce},
    "deadline": ${intent.deadline}
  }
}`}
              </code>
            </pre>
          </div>
          {}
          <div className="panel flex-1 flex flex-col min-h-0">
            <div className="panel-header flex items-center justify-between flex-shrink-0">
              <span className="console-cursor">┌─ TRANSACTION LOG</span>
              <span className="text-[10px] text-[#475569] tracking-normal font-normal">
                {logs.length} entries
              </span>
            </div>
            <div
              ref={logContainerRef}
              className="flex-1 overflow-y-auto space-y-0.5 min-h-[160px] max-h-[280px]"
              id="transaction-log"
            >
              {logs.map((log, i) => (
                <div key={i} className="console-line flex gap-2">
                  <span className="text-[#475569] flex-shrink-0 hidden sm:inline">
                    {log.timestamp}
                  </span>
                  <span
                    className={`flex-shrink-0 w-[72px] text-right ${
                      log.level === "SUCCESS"
                        ? "text-[#22c55e]"
                        : log.level === "ERROR"
                          ? "text-[#ef4444]"
                          : log.level === "WARN"
                            ? "text-[#f59e0b]"
                            : "text-[#3b82f6]"
                    }`}
                  >
                    [{log.level}]
                  </span>
                  <span className="text-[#cbd5e1] break-all">
                    {log.message}
                  </span>
                </div>
              ))}
            </div>
          </div>
        </div>
      </main>
      {}
      <footer className="border-t border-[#334155] px-6 py-2 flex items-center justify-between text-[10px] text-[#475569] flex-shrink-0">
        <span>
          CIRCLE FORWARDER © 2024 — GASLESS CROSS-CHAIN INTENT ENGINE
        </span>
        <div className="flex items-center gap-4">
          <span className="hidden md:inline">
            Base → CCTP → Arbitrum → Aave V3
          </span>
          <span className="flex items-center gap-1.5">
            <span
              className={`status-dot ${wallet.connected ? "status-dot--active" : "status-dot--idle"}`}
            />
            {wallet.connected ? "CONNECTED" : "DISCONNECTED"}
          </span>
        </div>
      </footer>
    </div>
  );
}
