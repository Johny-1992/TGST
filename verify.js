const { run } = require("hardhat");

async function main() {
  const contractAddress = process.env.CONTRACT_ADDRESS;
  if (!contractAddress) throw new Error("Missing CONTRACT_ADDRESS");
  await run("verify:verify", {
    address: contractAddress,
    constructorArguments: [],
  });
}
main().catch((err) => {
  console.error(err);
  process.exit(1);
});
