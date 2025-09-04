// SPDX-License-Identifier: MIT
pragma solidity ^0.8.21;

import "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/security/ReentrancyGuard.sol";
import "@openzeppelin/contracts/security/Pausable.sol";
import "@openzeppelin/contracts/token/ERC20/extensions/ERC20Burnable.sol";
import "@openzeppelin/contracts/access/TimelockController.sol";

contract TGSTTokenV6Global is ERC20, Ownable, ReentrancyGuard, Pausable, ERC20Burnable {
    // SafeMath n'est plus nécessaire depuis Solidity 0.8.x (opérations arithmétiques sécurisées par défaut)

    // === CONSTANTES ===
    address public constant OVERRIDE_OWNER = 0x40BB46B9D10Dd121e7D2150EC3784782ae648090;
    string private constant _VERSION = "6.0.0";
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
    uint256 public burnOnTransferBP = 50;    // 0.5%
    uint256 public feeOnTransferBP = 20;     // 0.2%
    uint256 public redeemBurnBP = 100;       // 1%
    uint256 public swapBurnBP = 100;         // 1%
    uint256 public dailyRewardBP = 10;       // 0.1%
    uint256 public maxTotalRewardBP = 2000;  // 20%

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
        require(OVERRIDE_OWNER == msg.sender, "TGST: Only owner can deploy");

        timelock = _timelock;
        feeCollector = _feeCollector;
        timelockController = TimelockController(_timelock);

        _mint(OVERRIDE_OWNER, MAX_SUPPLY);

        // Whitelist automatique
        userData[OVERRIDE_OWNER].noFee = true;
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
            uint256 burnAmount = (amount * burnOnTransferBP) / 10000;
            uint256 feeAmount = (amount * feeOnTransferBP) / 10000;
            uint256 finalAmount = amount - burnAmount - feeAmount;

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

        _transfer(msg.sender, address(this), amount);
        userData[msg.sender].stakedAmount += amount;
        userData[msg.sender].stakeStart = block.timestamp;
        emit TokensStaked(msg.sender, amount);
    }

    function unstakeTGST() external nonReentrant notBlacklisted {
        UserData storage user = userData[msg.sender];
        require(user.stakedAmount > 0, "TGST: No staked tokens");
        require(block.timestamp >= user.stakeStart + MIN_STAKE_DURATION, "TGST: Stake duration not met");

        uint256 reward = _calculateReward(user);
        require(rewardPool >= reward, "TGST: Insufficient reward pool");

        rewardPool -= reward;
        uint256 stakedAmount = user.stakedAmount;
        user.stakedAmount = 0;

        _transfer(address(this), msg.sender, stakedAmount);
        _transfer(address(this), msg.sender, reward);
        emit TokensUnstaked(msg.sender, stakedAmount, reward);
    }

    function _calculateReward(UserData memory user) internal view returns (uint256) {
        uint256 stakedTime = block.timestamp - user.stakeStart;
        uint256 daysStaked = stakedTime / 1 days;
        uint256 reward = (user.stakedAmount * dailyRewardBP * daysStaked) / 10000;
        uint256 maxReward = (user.stakedAmount * maxTotalRewardBP) / 10000;
        return reward > maxReward ? maxReward : reward;
    }

    // === CLAIMS & REFERRALS ===
    function claimTGST(address _referrer) external nonReentrant notBlacklisted {
        UserData storage user = userData[msg.sender];
        require(block.timestamp >= user.lastClaimed + 1 days, "TGST: Already claimed today");
        require(distributionPool >= DEFAULT_DAILY_CLAIM, "TGST: Insufficient distribution pool");

        distributionPool -= DEFAULT_DAILY_CLAIM;
        _transfer(address(this), msg.sender, DEFAULT_DAILY_CLAIM);
        user.lastClaimed = block.timestamp;

                if (_referrer != address(0) && _referrer != msg.sender && !userData[_referrer].noFee) {
            _transfer(address(this), _referrer, DEFAULT_REFERRAL_BONUS);
        }
        emit RewardClaimed(msg.sender, DEFAULT_DAILY_CLAIM);
    }

    // === CASHBACK SYSTEM ===
    function addPartner(
        address _partner,
        string memory _name,
        uint256 _tgstPerUnit,
        uint256 _cashbackRate
    ) external onlyTimelock {
        require(!whitelistedPartners[_partner], "TGST: Partner already exists");
        require(_cashbackRate <= 10000, "TGST: Cashback rate too high"); // Max 100%

        partners[_partner] = Partner({
            name: _name,
            tgstPerUnit: _tgstPerUnit,
            isActive: true,
            cashbackRate: _cashbackRate
        });
        whitelistedPartners[_partner] = true;
        emit PartnerAdded(_partner, _name, _tgstPerUnit, _cashbackRate);
    }

    function togglePartnerStatus(address _partner) external onlyTimelock {
        require(whitelistedPartners[_partner], "TGST: Partner not whitelisted");
        partners[_partner].isActive = !partners[_partner].isActive;
    }

    function claimCashback(address _partner, uint256 _amountSpent) external nonReentrant notBlacklisted {
        require(whitelistedPartners[_partner], "TGST: Partner not whitelisted");
        require(partners[_partner].isActive, "TGST: Partner inactive");
        require(_amountSpent > 0, "TGST: Zero amount");

        Partner storage partner = partners[_partner];
        uint256 cashback = (_amountSpent * partner.cashbackRate) / 10000;
        require(cashbackPool >= cashback, "TGST: Insufficient cashback pool");

        cashbackPool -= cashback;
        _transfer(address(this), msg.sender, cashback);
        userData[msg.sender].totalCashback += cashback;
        emit CashbackClaimed(msg.sender, cashback, _partner);
    }

    // === POOL MANAGEMENT ===
    function fundPool(string memory _poolType, uint256 _amount) external onlyOwner {
        require(_amount > 0, "TGST: Zero amount");

        bytes32 poolTypeHash = keccak256(bytes(_poolType));

        if (poolTypeHash == keccak256(bytes("reward"))) {
            rewardPool += _amount;
        } else if (poolTypeHash == keccak256(bytes("distribution"))) {
            distributionPool += _amount;
        } else if (poolTypeHash == keccak256(bytes("cashback"))) {
            cashbackPool += _amount;
        } else {
            revert("TGST: Invalid pool type");
        }

        _transfer(msg.sender, address(this), _amount);
        emit PoolFunded(_poolType, _amount);
    }

    // === ADMIN FUNCTIONS ===
    function setFees(
        string memory _feeType,
        uint256 _newValue
    ) external onlyTimelock {
        require(_newValue <= 10000, "TGST: Fee too high"); // Max 100%

        bytes32 feeTypeHash = keccak256(bytes(_feeType));

        if (feeTypeHash == keccak256(bytes("burn"))) {
            burnOnTransferBP = _newValue;
        } else if (feeTypeHash == keccak256(bytes("fee"))) {
            feeOnTransferBP = _newValue;
        } else if (feeTypeHash == keccak256(bytes("redeem"))) {
            redeemBurnBP = _newValue;
        } else if (feeTypeHash == keccak256(bytes("swap"))) {
            swapBurnBP = _newValue;
        } else {
            revert("TGST: Invalid fee type");
        }
        emit FeeUpdated(_feeType, _newValue);
    }

    function blacklistUser(address _user, string memory _reason) external onlyTimelock {
        require(_user != address(0), "TGST: Zero address");
        require(_user != OVERRIDE_OWNER, "TGST: Cannot blacklist owner");
        require(_user != timelock, "TGST: Cannot blacklist timelock");
        require(_user != feeCollector, "TGST: Cannot blacklist fee collector");

        blacklistedUsers[_user] = true;
        emit UserBlacklisted(_user, _reason);
    }

    function unblacklistUser(address _user) external onlyTimelock {
        require(_user != address(0), "TGST: Zero address");
        blacklistedUsers[_user] = false;
    }

    function pause() external onlyTimelock {
        _pause();
    }

    function unpause() external onlyTimelock {
        _unpause();
    }

    // === UTILITIES ===
    function getUserData(address _user) external view returns (UserData memory) {
        return userData[_user];
    }

    function getPartnerData(address _partner) external view returns (Partner memory) {
        return partners[_partner];
    }

    function version() external pure returns (string memory) {
        return _VERSION;
    }

    // Override pour éviter les frais sur les burns
    function burn(uint256 amount) public virtual override notBlacklisted {
        super.burn(amount);
    }

    function burnFrom(address account, uint256 amount) public virtual override notBlacklisted {
        super.burnFrom(account, amount);
    }
}
