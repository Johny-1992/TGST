// SPDX-License-Identifier: MIT
pragma solidity ^0.8.21;

import "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/security/ReentrancyGuard.sol";
import "@openzeppelin/contracts/security/Pausable.sol";
import "@openzeppelin/contracts/token/ERC20/extensions/ERC20Burnable.sol";
import "@openzeppelin/contracts/access/TimelockController.sol";
import "@openzeppelin/contracts/utils/math/SafeMath.sol";

contract TGSTTokenV5Global is ERC20, Ownable, ReentrancyGuard, Pausable, ERC20Burnable {
    using SafeMath for uint256;

    // === CONSTANTES ===
    address public constant OVERride_OWNER = 0x40BB46B9D10Dd121e7D2150EC3784782ae648090;
    string private constant _VERSION = "5.1.0";
    uint256 public constant MAX_SUPPLY = 1_000_000_000_000 * 1e18;
    uint256 public constant MIN_STAKE_DURATION = 7 days;
    uint256 public constant DEFAULT_DAILY_CLAIM = 100 * 1e18;
    uint256 public constant DEFAULT_REFERRAL_BONUS = 50 * 1e18;

    // === STRUCTURES ===
    struct UserData {
        uint256 stakedAmount;
        uint256 stakeStart;
        uint256 lastClaimed;
        bool noFee;
        address referrer;
        uint256 totalCashback;
    }

    struct Partner {
        string name;
        uint256 tgstPerUnit;
        bool isActive;
        uint256 cashbackRate; // En BP (ex: 500 = 5%)
    }

    // === VARIABLES ===
    uint256 public burnOnTransferBP = 50;
    uint256 public feeOnTransferBP = 20;
    uint256 public redeemBurnBP = 100;
    uint256 public swapBurnBP = 100;
    uint256 public dailyRewardBP = 10;
    uint256 public maxTotalRewardBP = 2000;

    uint256 public distributionPool;
    uint256 public rewardPool;
    uint256 public cashbackPool;

    address public feeCollector;
    address public timelock;
    TimelockController public timelockController;

    mapping(address => UserData) public userData;
    mapping(address => Partner) public partners;
    mapping(address => bool) public whitelistedPartners;
    mapping(address => bool) public blacklistedUsers;

    // === ÉVÉNEMENTS ===
    event TokensBurned(address indexed from, address indexed to, uint256 amount, string reason);
    event TokensStaked(address indexed user, uint256 amount);
    event TokensUnstaked(address indexed user, uint256 amount, uint256 reward);
    event RewardClaimed(address indexed user, uint256 amount);
    event CashbackClaimed(address indexed user, uint256 amount, address indexed partner);
    event PartnerAdded(address indexed partner, string name, uint256 tgstPerUnit, uint256 cashbackRate);
    event FeeUpdated(string feeType, uint256 newValue);
    event PoolFunded(string poolType, uint256 amount);
    event UserBlacklisted(address indexed user, string reason);

    // === MODIFICATEURS ===
    modifier onlyTimelock() {
        require(msg.sender == address(timelockController), "TGST: Only timelock");
        _;
    }

    modifier notBlacklisted() {
        require(!blacklistedUsers[msg.sender], "TGST: Blacklisted");
        _;
    }

    // === CONSTRUCTEUR ===
    constructor(address _timelock, address _feeCollector) {
        require(_timelock != address(0), "TGST: Zero timelock");
        require(_feeCollector != address(0), "TGST: Zero fee collector");
        require(OVERride_OWNER == msg.sender, "TGST: Only owner can deploy");

        timelock = _timelock;
        feeCollector = _feeCollector;
        timelockController = TimelockController(_timelock);

        _mint(OVERride_OWNER, MAX_SUPPLY);

        // Whitelist automatique
        userData[OVERride_OWNER].noFee = true;
        userData[_timelock].noFee = true;
        userData[_feeCollector].noFee = true;
    }

    // === TRANSFERTS ===
    function _transfer(
        address sender,
        address recipient,
        uint256 amount
    ) internal virtual override notBlacklisted {
        require(sender != address(0), "ERC20: transfer from the zero address");
        require(recipient != address(0), "ERC20: transfer to the zero address");

        if (!userData[sender].noFee && !userData[recipient].noFee) {
            uint256 burnAmount = amount.mul(burnOnTransferBP).div(10000);
            uint256 feeAmount = amount.mul(feeOnTransferBP).div(10000);
            uint256 finalAmount = amount.sub(burnAmount).sub(feeAmount);

            if (burnAmount > 0) {
                super._burn(sender, burnAmount);
                emit TokensBurned(sender, recipient, burnAmount, "Transfer Burn");
            }
            if (feeAmount > 0) {
                super._transfer(sender, feeCollector, feeAmount);
            }
            super._transfer(sender, recipient, finalAmount);
        } else {
            super._transfer(sender, recipient, amount);
        }
    }

    // === STAKING ===
    function stakeTGST(uint256 amount) external nonReentrant notBlacklisted {
        require(amount > 0, "TGST: Zero amount");
        require(balanceOf(msg.sender) >= amount, "TGST: Insufficient balance");

        _transfer(msg.sender, address(this), amount);
        userData[msg.sender].stakedAmount = userData[msg.sender].stakedAmount.add(amount);
        userData[msg.sender].stakeStart = block.timestamp;
        emit TokensStaked(msg.sender, amount);
    }

    function unstakeTGST() external nonReentrant notBlacklisted {
        UserData storage user = userData[msg.sender];
        require(user.stakedAmount > 0, "TGST: No staked tokens");
        require(block.timestamp >= user.stakeStart + MIN_STAKE_DURATION, "TGST: Stake duration not met");

        uint256 reward = _calculateReward(user);
        require(rewardPool >= reward, "TGST: Insufficient reward pool");

        rewardPool = rewardPool.sub(reward);
        uint256 stakedAmount = user.stakedAmount;
        user.stakedAmount = 0;

        _transfer(address(this), msg.sender, stakedAmount);
        _transfer(address(this), msg.sender, reward);
        emit TokensUnstaked(msg.sender, stakedAmount, reward);
    }

    function _calculateReward(UserData memory user) internal view returns (uint256) {
        uint256 stakedTime = block.timestamp.sub(user.stakeStart);
        uint256 daysStaked = stakedTime.div(1 days);
        uint256 reward = user.stakedAmount.mul(dailyRewardBP).mul(daysStaked).div(10000);
        uint256 maxReward = user.stakedAmount.mul(maxTotalRewardBP).div(10000);
        return reward > maxReward ? maxReward : reward;
    }

    // === CLAIMS & REFERRALS ===
    function claimTGST(address _referrer) external nonReentrant notBlacklisted {
        require(block.timestamp >= userData[msg.sender].lastClaimed + 1 days, "TGST: Already claimed today");
        require(distributionPool >= DEFAULT_DAILY_CLAIM, "TGST: Insufficient distribution pool");

       
