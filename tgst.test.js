
const { expect } = require("chai");

describe("TGSTToken", function () {
  it("deploys and mints 1T supply", async function () {
    const [owner] = await ethers.getSigners();
    const TGST = await ethers.getContractFactory("TGSTToken");
    const tgst = await TGST.deploy(owner.address);
    await tgst.deployed();
    const total = await tgst.totalSupply();
    expect(total).to.equal(ethers.parseUnits("1000000000000", 18));
  });
});
