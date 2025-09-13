// SPDX-License-Identifier: MIT
pragma solidity ^0.8.21;

import "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/security/Pausable.sol";
import "@openzeppelin/contracts/security/ReentrancyGuard.sol";

interface IPriceOracle {
    function getPrice() external view returns (uint256);
}

contract TGST_UltimatePlus is ERC20, Ownable, Pausable, ReentrancyGuard {
    uint256 public constant MAX_SUPPLY = 1_000_000_000_000 * 1e18;
    uint256 public constant AIRDROP_POOL = 25_000_000_000 * 1e18;
    uint256 public constant MAX_REWARD_BP = 500;
    uint256 public constant MIN_STAKE_DURATION = 7 days;
    uint256 public constant MAX_STAKE_DURATION = 30 days;

    IPriceOracle public priceOracle;

    struct StakeInfo { uint128 amount; uint40 start; uint40 duration; }
    mapping(address => StakeInfo) public stakes;

    uint256 public airdropClaimedCount;
    mapping(address => bool) public airdropClaimed;

    uint16 public burnBP = 100; // 1% base burn rate
    uint256 public stabilizerPool; // burn portion for partners/stabilization

    event BotAirdrop(address indexed user, uint256 amount);
    event Stake(address indexed user, uint256 amount, uint256 duration);
    event Unstake(address indexed user, uint256 amount, uint256 reward);
    event ConsumptionMint(address indexed user, uint256 amount);
    event BurnRateUpdated(uint16 newBP);
    event StabilizerUpdated(uint256 amount);

    constructor() ERC20("Token Global Smart Trade Ultimate+", "TGSTU+") {
        _mint(msg.sender, MAX_SUPPLY - AIRDROP_POOL);
        _mint(address(this), AIRDROP_POOL);
        stabilizerPool = AIRDROP_POOL / 2; // initial stabilizer pool
    }

    // ----- Airdrop léger et garanti -----
    function claimAirdrop() external whenNotPaused nonReentrant {
        require(!airdropClaimed[msg.sender], "Already claimed");
        require(airdropClaimedCount < 1000, "Airdrop pool finished");

        uint256 reward = AIRDROP_POOL / 1000;
        _transfer(address(this), msg.sender, reward);

        airdropClaimed[msg.sender] = true;
        airdropClaimedCount += 1;

        emit BotAirdrop(msg.sender, reward);
    }

    // ----- Staking simple et léger -----
    function stake(uint256 amount, uint256 duration) external whenNotPaused nonReentrant {
        require(amount > 0, "Zero amount");
        require(duration >= MIN_STAKE_DURATION && duration <= MAX_STAKE_DURATION, "Invalid duration");
        require(balanceOf(msg.sender) >= amount, "Insufficient balance");

        _transfer(msg.sender, address(this), amount);
        stakes[msg.sender] = StakeInfo({amount: uint128(amount), start: uint40(block.timestamp), duration: uint40(duration)});
        emit Stake(msg.sender, amount, duration);
    }

    function unstake() external whenNotPaused nonReentrant {
        StakeInfo memory s = stakes[msg.sender];
        require(s.amount > 0, "No stake");
        require(block.timestamp >= s.start + s.duration, "Stake locked");

        uint256 reward = s.amount * s.duration * MAX_REWARD_BP / (MAX_STAKE_DURATION * 10000);
        delete stakes[msg.sender];

        _transfer(address(this), msg.sender, s.amount + reward);
        emit Unstake(msg.sender, s.amount, reward);
    }

    // ----- Consumption Mint via Oracle -----
    function consumptionMint(uint256 amountInUSDT) external whenNotPaused nonReentrant {
        require(address(priceOracle) != address(0), "Oracle not set");
        uint256 price = priceOracle.getPrice();
        require(price > 0, "Invalid price");

        uint256 mintAmount = amountInUSDT * 1e18 / price;
        require(totalSupply() + mintAmount <= MAX_SUPPLY, "Max supply exceeded");

        _mint(msg.sender, mintAmount);
        emit ConsumptionMint(msg.sender, mintAmount);
    }

    // ----- Burn automatique intelligent sur transfert -----
    function _transfer(address sender, address recipient, uint256 amount) internal override whenNotPaused {
        require(sender != address(0) && recipient != address(0), "Zero address");

        // Burn calculé proportionnel : plus le prix oracle est bas, plus le burn est élevé
        uint256 burnAmount = burnBP * amount / 10000;
        if(address(priceOracle) != address(0)){
            uint256 price = priceOracle.getPrice();
            burnAmount = burnAmount * (1e18 / (price + 1)); // auto-régulation burn inversément proportionnelle au prix
        }

        uint256 stabilizerAmount = burnAmount / 2; // 50% du burn va au pool partenaires
        uint256 sendAmount = amount - burnAmount;

        if(burnAmount > 0){
            _burn(sender, burnAmount - stabilizerAmount);
            stabilizerPool += stabilizerAmount;
            emit StabilizerUpdated(stabilizerPool);
        }

        super._transfer(sender, recipient, sendAmount);
    }

    // ----- Owner functions -----
    function updateBurnBP(uint16 newBP) external onlyOwner {
        require(newBP <= 1000, "Max 10%");
        burnBP = newBP;
        emit BurnRateUpdated(newBP);
    }

    function setPriceOracle(address oracleAddr) external onlyOwner { priceOracle = IPriceOracle(oracleAddr); }
    function pause() external onlyOwner { _pause(); }
    function unpause() external onlyOwner { _unpause(); }
    function withdrawStabilizer(address to, uint256 amount) external onlyOwner {
        require(amount <= stabilizerPool, "Exceeds pool");
        _transfer(address(this), to, amount);
        stabilizerPool -= amount;
        emit StabilizerUpdated(stabilizerPool);
    }

    function _beforeTokenTransfer(address from, address to, uint256 amount) internal override whenNotPaused { super._beforeTokenTransfer(from, to, amount); }
}
