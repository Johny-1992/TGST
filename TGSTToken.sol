// SPDX-License-Identifier: MIT
pragma solidity ^0.8.21;

import "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import "@openzeppelin/contracts/token/ERC20/extensions/ERC20Burnable.sol";
import "@openzeppelin/contracts/token/ERC20/extensions/ERC20Pausable.sol";
import "@openzeppelin/contracts/token/ERC20/extensions/ERC20Snapshot.sol";
import "@openzeppelin/contracts/access/AccessControl.sol";
import "@openzeppelin/contracts/security/ReentrancyGuard.sol";

interface IERC20Decimals {
    function decimals() external view returns (uint8);
}

contract TGST is ERC20, ERC20Burnable, ERC20Pausable, ERC20Snapshot, AccessControl, ReentrancyGuard {

    // --- Roles ---
    bytes32 public constant MINTER_ROLE = keccak256("MINTER_ROLE");
    bytes32 public constant PAUSER_ROLE = keccak256("PAUSER_ROLE");
    bytes32 public constant SNAPSHOT_ROLE = keccak256("SNAPSHOT_ROLE");

    // --- Owner fixe ---
    address public constant OWNER = 0x40BB46B9D10Dd121e7D2150EC3784782ae648090;

    // --- Supply initiale ---
    uint256 public constant INITIAL_SUPPLY = 100_000_000_000 * 1e18; // 100B TGST
    uint256 public constant USER_AIRDROP = 250 * 1e18; 
    uint256 public constant REFERRAL_BONUS = 50 * 1e18;

    // --- Pools & régulation ---
    uint256 public liquidityPoolTGST; // TGST réservés pour liquidité
    uint256 public liquidityPoolUSDT; // USDT réservés pour pool
    IERC20Decimals public USDT; // Adresse USDT pour pool

    // --- Burn et donation ---
    uint256 public transferBurnBP = 100; // 1%
    uint256 public transferDonationBP = 50; // 0.5% vers Owner

    // --- Staking ---
    struct Stake {
        uint256 amount;
        uint256 start;
    }
    mapping(address => Stake) public stakes;
    uint256 public constant MIN_STAKE = 7 days;
    uint256 public constant MAX_STAKE = 365 days;
    uint256 public dailyRewardBP = 5; // 0.05% par jour

    // --- KYC ---
    mapping(address => bool) public isKYCed;

    // --- Events ---
    event TokensAirdropped(address indexed user, uint256 amount);
    event ReferralPaid(address indexed referrer, uint256 amount);
    event ConsumptionMint(address indexed user, uint256 amount, address partner);
    event TransferBurned(address indexed from, uint256 burned);
    event TransferDonated(address indexed from, uint256 donated);
    event Staked(address indexed user, uint256 amount);
    event Unstaked(address indexed user, uint256 amount, uint256 reward);
    event PoolUpdated(uint256 TGSTAdded, uint256 USDTAdded);
    event PoolSwapped(address indexed user, uint256 TGSTSpent, uint256 USDTReceived);

    constructor(address _usdt) ERC20("Token Global Smart Trade", "TGST") {
        _grantRole(DEFAULT_ADMIN_ROLE, OWNER);
        _grantRole(MINTER_ROLE, OWNER);
        _grantRole(PAUSER_ROLE, OWNER);
        _grantRole(SNAPSHOT_ROLE, OWNER);

        USDT = IERC20Decimals(_usdt);

        // Mint initial 100B TGST à OWNER
        _mint(OWNER, INITIAL_SUPPLY);
    }

    // --- KYC management ---
    modifier onlyKYCed(address user) {
        require(isKYCed[user], "TGST: user not KYCed");
        _;
    }

    function setKYC(address user, bool status) external onlyRole(DEFAULT_ADMIN_ROLE) {
        isKYCed[user] = status;
    }

    // --- Transfer override avec burn et donation ---
    function _transfer(address sender, address recipient, uint256 amount) internal override {
        require(!paused(), "TGST: paused");

        uint256 burnAmount = (amount * transferBurnBP) / 10000;
        uint256 donationAmount = (amount * transferDonationBP) / 10000;
        uint256 sendAmount = amount - burnAmount - donationAmount;

        if(burnAmount > 0){
            super._burn(sender, burnAmount);
            emit TransferBurned(sender, burnAmount);
        }
        if(donationAmount > 0){
            super._transfer(sender, OWNER, donationAmount);
            emit TransferDonated(sender, donationAmount);
        }
        super._transfer(sender, recipient, sendAmount);
    }

    // --- Staking ---
    function stake(uint256 amount) external onlyKYCed(msg.sender) {
        require(amount > 0 && balanceOf(msg.sender) >= amount, "TGST: invalid stake");
        _transfer(msg.sender, address(this), amount);
        stakes[msg.sender].amount += amount;
        stakes[msg.sender].start = block.timestamp;
        emit Staked(msg.sender, amount);
    }

    function unstake() external onlyKYCed(msg.sender) {
        Stake storage s = stakes[msg.sender];
        require(s.amount > 0, "TGST: no stake");
        uint256 stakedTime = block.timestamp - s.start;
        require(stakedTime >= MIN_STAKE, "TGST: stake too short");
        require(stakedTime <= MAX_STAKE, "TGST: stake too long");

        uint256 reward = (s.amount * dailyRewardBP * (stakedTime / 1 days)) / 10000;
        _transfer(address(this), msg.sender, s.amount + reward);

        emit Unstaked(msg.sender, s.amount, reward);
        s.amount = 0;
        s.start = 0;
    }

    // --- Mint automatique consommation ---
    function mintConsumption(address user, uint256 amount, address partner) external onlyRole(MINTER_ROLE) onlyKYCed(user) {
        require(amount > 0, "TGST: zero amount");
        _mint(user, amount);
        emit ConsumptionMint(user, amount, partner);
    }

    // --- Airdrop initial + referral ---
    function airdrop(address user, address referrer) external onlyRole(MINTER_ROLE) onlyKYCed(user) {
        _mint(user, USER_AIRDROP);
        emit TokensAirdropped(user, USER_AIRDROP);

        if(referrer != address(0) && isKYCed[referrer]){
            _mint(referrer, REFERRAL_BONUS);
            emit ReferralPaid(referrer, REFERRAL_BONUS);
        }
    }

    // --- Pool TGST/USDT ---
    function addLiquidityPool(uint256 tgstAmount, uint256 usdtAmount) external onlyRole(MINTER_ROLE) {
        require(tgstAmount > 0 && usdtAmount > 0, "TGST: zero pool");
        _transfer(msg.sender, address(this), tgstAmount);
        USDT.transferFrom(msg.sender, address(this), usdtAmount);
        liquidityPoolTGST += tgstAmount;
        liquidityPoolUSDT += usdtAmount;
        emit PoolUpdated(tgstAmount, usdtAmount);
    }

    function swapTGSTtoUSDT(uint256 tgstAmount) external onlyKYCed(msg.sender) nonReentrant {
        require(tgstAmount > 0 && liquidityPoolTGST > 0 && liquidityPoolUSDT > 0, "TGST: pool empty");

        uint256 usdtAmount = (tgstAmount * liquidityPoolUSDT) / liquidityPoolTGST;
        require(usdtAmount <= liquidityPoolUSDT, "TGST: not enough USDT in pool");

        _transfer(msg.sender, address(this), tgstAmount);
        USDT.transfer(msg.sender, usdtAmount);

        liquidityPoolTGST += tgstAmount;
        liquidityPoolUSDT -= usdtAmount;

        emit PoolSwapped(msg.sender, tgstAmount, usdtAmount);
    }

    // --- Pause & Snapshot ---
    function pause() external onlyRole(PAUSER_ROLE) { _pause(); }
    function unpause() external onlyRole(PAUSER_ROLE) { _unpause(); }
    function snapshot() external onlyRole(SNAPSHOT_ROLE) { _snapshot(); }

    // --- Overrides pour héritage ---
    function _beforeTokenTransfer(address from, address to, uint256 amount) internal override(ERC20, ERC20Pausable, ERC20Snapshot) {
        super._beforeTokenTransfer(from, to, amount);
    }
}
