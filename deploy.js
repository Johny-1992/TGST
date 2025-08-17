
const hre = require("hardhat");

async function main() {
  const feeCollector = process.env.FEE_COLLECTOR || "0x000000000000000000000000000000000000dEaD";
  const TGST = await hre.ethers.getContractFactory("TGSTToken");
  const tgst = await TGST.deploy(feeCollector);
  await tgst.deployed();
  console.log("TGST deployed:", tgst.address);
}

main().catch((error) => {
  console.error(error);
  process.exitCode = 1;
});
