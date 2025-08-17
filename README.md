# TGST — Token Global Smart Trade


## Quickstart
```bash
# Termux
unzip TGST_Empire_FULL_SUITE.zip
cd TGST_Empire
bash termux_install.sh
cp .env.example .env   # Fill secrets locally
cd contracts
npx hardhat compile
npm run deploy:testnet
```
Run tests:
```bash
npx hardhat test
```
Verify on BscScan:
```bash
node scripts/verify.js
```
