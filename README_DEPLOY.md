
# TGST Empire — Full Deploy Pack

This pack contains a production-ready scaffold to deploy the TGST ecosystem:
- **Smart Contracts** (Hardhat) with TGST BEP-20 token
- **Backend API** (Express)
- **Web App** (Vite + React) as landing/dApp
- **Telegram Bot** (Telegraf)
- **Mobile App** (Expo React Native)
- **CI/CD** via GitHub Actions (Render deploy hooks included)
- **Env templates**

> Created: 2025-08-17T18:53:45.662510Z

## Quick Start (GitHub)

1. Create an **empty** repo (no README) on your GitHub (recommended private for now).
2. Upload this zip to the repo root and extract locally, or run the script in `README_DEPLOY.md` below (CLI method).
3. Add **GitHub Secrets** (Repo → Settings → Secrets and variables → Actions):
   - `PRIVATE_KEY` — your deployer wallet private key (no `0x`)
   - `INFURA_API_KEY`
   - `BSC_TESTNET_RPC` — e.g. `https://data-seed-prebsc-1-s1.binance.org:8545/`
   - `BSCSCAN_API_KEY` (optional)
   - `TELEGRAM_BOT_TOKEN`
   - `TELEGRAM_CHAT_ID` (your own chat/user/group id)
   - `RENDER_API_KEY`
   - `RENDER_BACKEND_SERVICE_ID` (from Render dashboard)
   - `RENDER_BOT_SERVICE_ID`
   - `RENDER_FRONTEND_SERVICE_ID` (if using a Web Service for SSR; not needed for Static Site)

4. Push to `main` → GitHub Actions will build + (optionally) deploy to Render.

## CLI one-liner (local/Termux)

```bash
# Replace YOUR_USER and REPO with your values (e.g., Johny-1992 and TGST)
REPO=TGST
USER=YOUR_USER

# Create local folder and unzip (assuming this zip is downloaded as TGST_Deploy_Pack.zip)
mkdir -p $REPO && cd $REPO
unzip ~/Download/TGST_Deploy_Pack.zip -d . 2>/dev/null || unzip TGST_Deploy_Pack.zip -d .

# Initialize git and push
git init
git branch -M main
git add .
git commit -m "TGST: initial deploy pack"
git remote add origin https://github.com/$USER/$REPO.git
git push -u origin main
```

## Render setup

- **Frontend (Vite)**: Create **Static Site** → Root: `frontend/` → Build: `npm install && npm run build` → Publish dir: `dist`
- **Backend (Express)**: Create **Web Service** → Root: `backend/` → Build: `npm install` → Start: `npm start`
- **Bot (Telegraf)**: Create **Background Worker** → Root: `bot/` → Start: `npm install && node index.js`

Add the same env vars on Render as in GitHub Secrets when required.

## Contracts Deployment

The workflow `deploy-contract.yml` compiles & tests on every push. For live deployment, run locally:
```bash
cd contracts
npm install
npx hardhat compile
# Example for BSC testnet (configure in hardhat.config.js or pass --network)
npx hardhat run scripts/deploy.js --network bscTestnet
```
