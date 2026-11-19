---
name: creative-adk-peers
description: Invoke Creative Pixels (`edit-pixels`) and Dear Creative (`dear-creative`) Google ADK peer agents and check article x402 pricing status via `adk-peer-call`.
---

# Creative ADK Peer Bridges (`edit-pixels` & `dear-creative`)

Use `/usr/local/bin/adk-peer-call` inside `hermes-swarm` to collaborate directly with the two live Google ADK peer services over Cloud Run OIDC authentication (`hermes-swarm-sa`).

## Commands

### 1. Discover Available ADK Apps on a Peer
```bash
adk-peer-call list-apps --peer pixels
adk-peer-call list-apps --peer dear-creative
```

### 2. Delegate Creative Direction to Creative Pixels (`edit-pixels`)
```bash
adk-peer-call run --peer pixels --message "Story-board a 30-second Base creator launch spot"
```
Optional flags: `--user-id <id>`, `--session-id <id>`, `--app-name <name>`.

### 3. Delegate Editorial Work to Dear Creative (`adam` ADK — Phase 1 In-House Pipeline)
```bash
adk-peer-call run --peer dear-creative --message "Draft a teaser and outline for this week's creator economy issue"
```

### 4. Check Dear Creative Article Paywall Mode (Phase 2 Free vs. $1.00 USDC)
```bash
adk-peer-call check-article --slug "<article-slug>"
```
Returns JSON including `"pricingMode": "free" | "paid" | "unknown"` and the upstream status (`200` for free, `402` for paid).

## Monetization Boundaries

- **Creative Pixels (`edit-pixels`)**:
  - Humans inside `edit-pixels` pay/hold **CRTVAI** tokens (`POST /api/director`).
  - External AI agents pay **$0.25 Base USDC** via x402 v2 at `POST ${HERMES_GATEWAY_URL}/v1/x402/creative-director`.
- **Dear Creative (`dear-creative`)**:
  - **Phase 1 (Current):** In-house editorial workflow coordinated between `hermes-agent` (`default` Orchestrator) and the `adam` ADK peer.
  - **Phase 2:** Writers toggle individual articles Free (`$0.00`) or Paid (`$1.00 Base USDC`); external agents access them at `GET ${HERMES_GATEWAY_URL}/v1/x402/dear-creative/articles/:slug` (settling into Safe Vault `0xf46F1BA19A9280F752a451d0973b047D81c63D70`).
