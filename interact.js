const { ethers } = require("ethers");

async function main() {
  const provider = new ethers.JsonRpcProvider(process.env.BSC_TESTNET_RPC);
  const wallet = new ethers.Wallet(process.env.PRIVATE_KEY || ethers.Wallet.createRandom().privateKey, provider);
  const abi = ["function totalSupply() view returns (uint256)"];
  const contract = new ethers.Contract(process.env.CONTRACT_ADDRESS, abi, wallet);

  const supply = await contract.totalSupply();
  console.log("Total supply:", supply.toString());
}
main();
