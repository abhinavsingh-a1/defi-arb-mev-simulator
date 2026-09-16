/**
 * realtime-price-pusher.js
 *
 * Fetches a REAL, live price from CoinGecko's public API (free, no API key
 * required: https://api.coingecko.com/api/v3/simple/price) and pushes it
 * on-chain into MockChainlinkFeed on an interval — a genuine independent
 * price source, not a simulated random walk.
 *
 * This replaces the earlier stubbed version of this script. In a real
 * deployment you'd more likely run an actual Chainlink node, or at least
 * poll multiple independent sources and median them — this is a single
 * public REST endpoint, which is fine for local dev/demo purposes but is
 * itself a single point of failure you wouldn't want in production.
 *
 * Usage:
 *   node realtime-price-pusher.js
 *
 * Env vars:
 *   RPC_URL              - JSON-RPC endpoint
 *   PRIVATE_KEY           - reporter's private key (must be the
 *                            MockChainlinkFeed contract's `owner`)
 *   CHAINLINK_FEED_ADDRESS - deployed MockChainlinkFeed address
 *   COINGECKO_ID           - CoinGecko coin id to price (default: "ethereum")
 *   VS_CURRENCY             - fiat currency to price against (default: "usd")
 *   PUSH_INTERVAL_MS        - how often to fetch + push (default: 60000 —
 *                              CoinGecko's free tier rate-limits aggressive
 *                              polling, so don't go much faster than this)
 */

const { ethers } = require("ethers");

const RPC_URL = process.env.RPC_URL || "http://127.0.0.1:8545";
const PRIVATE_KEY = process.env.PRIVATE_KEY;
const CHAINLINK_FEED_ADDRESS = process.env.CHAINLINK_FEED_ADDRESS;
const COINGECKO_ID = process.env.COINGECKO_ID || "ethereum";
const VS_CURRENCY = process.env.VS_CURRENCY || "usd";
const PUSH_INTERVAL_MS = Number(process.env.PUSH_INTERVAL_MS || "60000");

const CHAINLINK_FEED_ABI = [
  "function pushRound(int256 newAnswer) external",
  "function decimals() view returns (uint8)",
  "function latestRoundData() view returns (uint80 roundId, int256 answer, uint256 startedAt, uint256 updatedAt, uint80 answeredInRound)",
  "event AnswerUpdated(int256 indexed current, uint80 indexed roundId, uint256 updatedAt)",
];

if (!PRIVATE_KEY || !CHAINLINK_FEED_ADDRESS) {
  console.error(
    "Missing required env vars. Need PRIVATE_KEY and CHAINLINK_FEED_ADDRESS."
  );
  process.exit(1);
}

/**
 * Fetches the live price from CoinGecko's public /simple/price endpoint.
 * No API key required for this endpoint at the time of writing, but it is
 * rate-limited on the free tier — don't poll faster than PUSH_INTERVAL_MS's
 * default without checking CoinGecko's current rate-limit policy.
 */
async function fetchLivePrice() {
  const url = `https://api.coingecko.com/api/v3/simple/price?ids=${encodeURIComponent(
    COINGECKO_ID
  )}&vs_currencies=${encodeURIComponent(VS_CURRENCY)}`;

  const res = await fetch(url);
  if (!res.ok) {
    throw new Error(`CoinGecko request failed: ${res.status} ${res.statusText}`);
  }

  const data = await res.json();
  const price = data?.[COINGECKO_ID]?.[VS_CURRENCY];

  if (typeof price !== "number" || !Number.isFinite(price) || price <= 0) {
    throw new Error(`Unexpected CoinGecko response shape: ${JSON.stringify(data)}`);
  }

  return price;
}

/**
 * Converts a JS float price into an integer answer at the feed's own
 * `decimals` precision (matching real Chainlink feeds, typically 8 for
 * USD pairs), without floating point creeping into the on-chain value.
 */
function toFeedPrecision(priceFloat, decimals) {
  const scaled = Math.round(priceFloat * 10 ** decimals);
  return BigInt(scaled);
}

async function main() {
  const provider = new ethers.JsonRpcProvider(RPC_URL);
  const wallet = new ethers.Wallet(PRIVATE_KEY, provider);
  const feed = new ethers.Contract(CHAINLINK_FEED_ADDRESS, CHAINLINK_FEED_ABI, wallet);

  const decimals = await feed.decimals();

  console.log(`realtime-price-pusher starting`);
  console.log(`  RPC:      ${RPC_URL}`);
  console.log(`  feed:     ${CHAINLINK_FEED_ADDRESS} (decimals=${decimals})`);
  console.log(`  signer:   ${wallet.address}`);
  console.log(`  source:   CoinGecko ${COINGECKO_ID}/${VS_CURRENCY}`);
  console.log(`  interval: ${PUSH_INTERVAL_MS}ms`);

  const tick = async () => {
    try {
      const livePrice = await fetchLivePrice();
      const answer = toFeedPrecision(livePrice, decimals);

      const tx = await feed.pushRound(answer);
      await tx.wait();

      console.log(
        `[${new Date().toISOString()}] pushed ${COINGECKO_ID}/${VS_CURRENCY} = $${livePrice} (tx ${tx.hash})`
      );
    } catch (err) {
      console.error(`[${new Date().toISOString()}] push failed:`, err.message || err);
    }
  };

  await tick(); // push immediately on startup
  setInterval(tick, PUSH_INTERVAL_MS);
}

main().catch((err) => {
  console.error("Fatal error:", err);
  process.exit(1);
});
