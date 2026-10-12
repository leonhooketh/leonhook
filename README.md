# LEON — Ethereum mainnet launch sources

Exact sources submitted to the Programmable Custom Launch API (profile 3.6.0, chain 1).

- `src/RouletteTokenEth.sol` — fixed-supply ERC-20, no owner, no mint. ETH sent to it is credited to holders pro rata (the pool, the initializer and the dead address are excluded); each holder claims their share.
- `src/RouletteHookEth.sol` — Uniswap v4 hook: 3.3% of the gross ETH side of every swap: 2% to the round pot, 1% keeper upkeep and 0.3% Programmable platform fee.
  The 0.3% is charged on every buy and sell through any router, on the initial buy and on the hook's own buybacks, accrues in `platformAccrued` and can only be paid out to the fixed recipient `0xD88539d3c4C460136a733A3Fd60cf6BF269079da` via `claimPlatform()`, which anyone may call.
  Every 33 swaps the pot goes to one of four outcomes (burn, dip buyback, holder rewards, permanent full-range liquidity), picked from a committed secret and a future block hash; the market mood makes one of them the 55% favourite.
- `src/RouletteInitializerEth.sol` — creates the pool and locks the whole supply as one-sided liquidity; it has no owner and no way to withdraw. ETH sent with the launch call is an initial buy: it buys in the same pool (paying the usual 3.3%) and every bought token is burned, so the launcher keeps none.
- `standard-json/main.json` — the exact solc 0.8.26 Standard JSON input; `artifacts/` — its output.
- `evidence/fork-tests.json` — fork test results against the mainnet Uniswap v4 PoolManager.
- `evidence/platform-fee.json` — per-scenario proof of the 0.3% platform fee: gross native base, 30 bps amount and recipient credit (alternate routers incl. the mainnet Universal Router, initial buy, own buybacks, claim).
