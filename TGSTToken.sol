// SPDX-License-Identifier: MIT
pragma solidity ^0.8.21;

import "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import "@openzeppelin/contracts/token/ERC20/extensions/ERC20Burnable.sol";
import "@openzeppelin/contracts/token/ERC20/extensions/ERC20Pausable.sol";
import "@openzeppelin/contracts/token/ERC20/extensions/ERC20Snapshot.sol";
import "@openzeppelin/contracts/token/ERC20/extensions/draft-ERC20Permit.sol";
import "@openzeppelin/contracts/access/AccessControl.sol";
import "@openzeppelin/contracts/security/ReentrancyGuard.sol";
import "@openzeppelin/contracts/utils/cryptography/ECDSA.sol";
import "@openzeppelin/contracts/utils/cryptography/EIP712.sol";

contract TGSTUltimate is ERC20, ERC20Burnable, ERC20Pausable, ERC20Snapshot, ERC20Permit, AccessControl, ReentrancyGuard, EIP712 {

    // -----------------------
    // CONSTANTS & METADATA
    // -----------------------
    address public constant OVERRIDE_OWNER = 0x40BB46B9D10Dd121e7D2150EC3784782ae648090;
    string private constant _VERSION = "TGST-ULTIMATE-1.2-Mainnet";
    uint256 public constant MAX_SUPPLY = 1_000_000_000_000 * 1e18; // 1 trillion TGST
    uint256 public constant BP_DIVISOR = 10000;
    uint256 public constant MIN_STAKE_SECONDS = 7 days;

    // -----------------------
    // ROLES
    // -----------------------
    bytes32 public constant GOVERNOR_ROLE = keccak256("GOVERNOR_ROLE");
    bytes32 public constant MINTER_ROLE   = keccak256("MINTER_ROLE");
    bytes32 public constant PAUSER_ROLE   = keccak256("PAUSER_ROLE");
    bytes32 public constant BRIDGE_ROLE   = keccak256("BRIDGE_ROLE");

    // -----------------------
    // FEES & BURN
    // -----------------------
    uint256 public transferBurnBP = 50; // 0.5%
    uint256 public transferFeeBP = 20;  // 0.2%
    address public feeCollector;
    mapping(address => bool) public feeExempt;
    uint256 public maxTransferAmount;

    // -----------------------
    // POOLS
    // -----------------------
    uint256 public distributionPool;
    uint256 public rewardPool;
    uint256 public cashbackPool;
    uint256 public liquidityPool;

    // -----------------------
    // PARTNERS
    // -----------------------
    struct Partner {
        string name;
        uint256 cashbackBP;
        bool isActive;
        bool useFixedPerUnit;
        uint256 fixedAmountPerUnit;
    }
    mapping(address => Partner) public partners;
    mapping(address => bool) public whitelistedPartners;

    // -----------------------
    // USERS
    // -----------------------
    struct UserData {
        uint256 stakedAmount;
        uint256 stakeStart;
        uint256 lastClaimed;
        uint256 lastReferralClaim;
        address referrer;
        uint256 totalCashback;
        uint256 nonce; // for EIP-712
    }
    mapping(address => UserData) public userData;
    mapping(address => bool) public blacklisted;

    // -----------------------
    // STAKING & REFERRAL
    // -----------------------
    uint256 public dailyRewardBP = 10;      // 0.1% daily
    uint256 public maxTotalRewardBP = 2000; // 20%
    uint256 public referralBonus = 50 * 1e18;

    // -----------------------
    // TIPS / DONATIONS
    // -----------------------
    address public tipRecipient;
    event TipSent(address indexed sender, address indexed recipient, uint256 amount, string message);

    // -----------------------
    // EIP-712 Cashback
    // -----------------------
    bytes32 private constant _CASHBACK_TYPEHASH = keccak256(
        "CashbackClaim(uint256 amountSpent,address partner,address user,uint256 nonce,uint256 timestamp)"
    );

    // -----------------------
    // CONSTRUCTOR
    // -----------------------
    constructor(address _feeCollector) ERC20("Token Global Smart Trade", "TGST") ERC20Permit("TGST") EIP712("TGST", _VERSION) {
        require(msg.sender == OVERRIDE_OWNER, "TGST: Only OVERRIDE_OWNER can deploy");
        require(_feeCollector != address(0), "TGST: zero fee collector");

        feeCollector = _feeCollector;
        tipRecipient = OVERRIDE_OWNER;

        _setupRole(DEFAULT_ADMIN_ROLE, OVERRIDE_OWNER);
        _setupRole(GOVERNOR_ROLE, OVERRIDE_OWNER);
        _setupRole(MINTER_ROLE, OVERRIDE_OWNER);
        _setupRole(PAUSER_ROLE, OVERRIDE_OWNER);
        _setupRole(BRIDGE_ROLE, OVERRIDE_OWNER);

        _mint(OVERRIDE_OWNER, MAX_SUPPLY);

        feeExempt[address(this)] = true;
        feeExempt[OVERRIDE_OWNER] = true;
        feeExempt[_feeCollector] = true;
        feeExempt[tipRecipient] = true;
    }

    // -----------------------
    // TRANSFERS WITH BURN & FEES
    // -----------------------
    function _transfer(address sender, address recipient, uint256 amount) internal override {
        require(!blacklisted[sender] && !blacklisted[recipient], "TGST: blacklisted");
        if (feeExempt[sender] || feeExempt[recipient] || amount == 0) {
            super._transfer(sender, recipient, amount);
            return;
        }

        uint256 burnAmount = (amount * transferBurnBP) / BP_DIVISOR;
        uint256 feeAmount = (amount * transferFeeBP) / BP_DIVISOR;
        uint256 sendAmount = amount - burnAmount - feeAmount;

        if (burnAmount > 0) super._burn(sender, burnAmount);
        if (feeAmount > 0) super._transfer(sender, feeCollector, feeAmount);
        if (sendAmount > 0) super._transfer(sender, recipient, sendAmount);
        if (burnAmount > 0) emit TokensBurned(sender, burnAmount, "transfer-burn");
    }

    // -----------------------
    // STAKING
    // -----------------------
    function stake(uint256 amount) external nonReentrant whenNotPaused {
        require(amount > 0 && balanceOf(msg.sender) >= amount, "TGST: invalid stake");
        _transfer(msg.sender, address(this), amount);

        UserData storage u = userData[msg.sender];
        u.stakedAmount += amount;
        u.stakeStart = block.timestamp;
        emit Staked(msg.sender, amount);
    }

    function unstake() external nonReentrant whenNotPaused {
        UserData storage u = userData[msg.sender];
        require(u.stakedAmount > 0, "TGST: no stake");
        require(block.timestamp >= u.stakeStart + MIN_STAKE_SECONDS, "TGST: stake time not met");

        uint256 reward = _calculateReward(u);
        require(rewardPool >= reward, "TGST: insufficient reward pool");
        rewardPool -= reward;

        uint256 amount = u.stakedAmount;
        u.stakedAmount = 0;
        u.stakeStart = 0;

        _transfer(address(this), msg.sender, amount + reward);
        emit Unstaked(msg.sender, amount, reward);
    }

    function _calculateReward(UserData memory u) internal view returns (uint256) {
        if (u.stakeStart == 0 || u.stakedAmount == 0) return 0;
        uint256 daysStaked = (block.timestamp - u.stakeStart) / 1 days;
        uint256 reward = (u.stakedAmount * dailyRewardBP * daysStaked) / BP_DIVISOR;
        uint256 maxReward = (u.stakedAmount * maxTotalRewardBP) / BP_DIVISOR;
        return reward <= maxReward ? reward : maxReward;
    }

    // -----------------------
    // REFERRAL & DAILY CLAIM
    // -----------------------
    function claimDailyWithRef(address referrer) external nonReentrant whenNotPaused {
        UserData storage u = userData[msg.sender];
        require(block.timestamp >= u.lastClaimed + 1 days, "TGST: already claimed today");
        require(distributionPool >= 100 * 1e18, "TGST: insufficient distribution pool");

        uint256 totalClaim = 100 * 1e18;

        if (referrer != address(0) && referrer != msg.sender) {
            require(!blacklisted[referrer], "TGST: referrer blacklisted");
            require(block.timestamp >= u.lastReferralClaim + 1 days, "TGST: referral already claimed today");
            require(distributionPool >= totalClaim + referralBonus, "TGST: insufficient pool for referral");

            totalClaim += referralBonus;
            u.lastReferralClaim = block.timestamp;
            u.referrer = referrer;

            _transfer(address(this), referrer, referralBonus);
            emit ReferralPaid(msg.sender, referrer, referralBonus);
        }

        distributionPool -= 100 * 1e18;
        u.lastClaimed = block.timestamp;
        _transfer(address(this), msg.sender, 100 * 1e18);
    }

    // -----------------------
    // CASHBACK CLAIM (EIP-712)
    // -----------------------
    function claimCashback(
        address partnerAddr,
        uint256 amountSpent,
        uint256 nonce,
        uint256 timestamp,
        bytes calldata signature
    ) external nonReentrant {
        require(whitelistedPartners[partnerAddr], "TGST: not partner");
        Partner storage p = partners[partnerAddr];
        require(p.isActive, "TGST: partner inactive");
        require(amountSpent > 0 && cashbackPool > 0, "TGST: zero spent or empty pool");

        bytes32 structHash = keccak256(abi.encode(_CASHBACK_TYPEHASH, amountSpent, partnerAddr, msg.sender, nonce, timestamp));
        address signer = ECDSA.recover(ECDSA.toEthSignedMessageHash(structHash), signature);
        require(signer == partnerAddr, "TGST: invalid signature");
        require(userData[msg.sender].nonce < nonce, "TGST: invalid nonce");

        uint256 cashback = p.useFixedPerUnit ? (amountSpent * p.fixedAmountPerUnit) / 1e18 : (amountSpent * p.cashbackBP) / BP_DIVISOR;
        require(cashbackPool >= cashback, "TGST: insufficient cashback pool");
        cashbackPool -= cashback;
        _transfer(address(this), msg.sender, cashback);

        userData[msg.sender].totalCashback += cashback;
        userData[msg.sender].nonce = nonce;

        emit CashbackClaimed(msg.sender, partnerAddr, cashback);
    }

    // -----------------------
    // REWARD BY CONSUMPTION AUTOMATIC
    // -----------------------
    function rewardByConsumption(address user, address partnerAddr, uint256 consumption) external onlyRole(GOVERNOR_ROLE) {
        require(whitelistedPartners[partnerAddr], "TGST: invalid partner");
        Partner storage p = partners[partnerAddr];
        require(p.isActive, "TGST: partner inactive");

        uint256 reward = p.useFixedPerUnit ? (consumption * p.fixedAmountPerUnit) / 1e18 : (consumption * p.cashbackBP) / BP_DIVISOR;
        require(totalSupply() + reward <= MAX_SUPPLY, "TGST: max supply exceeded");
        require(rewardPool >= reward, "TGST: insufficient reward pool");

        rewardPool -= reward;
        _mint(user, reward);
    }

    // -----------------------
    // AUTO BURN
    // -----------------------
    function autoBurn(uint256 amount) external onlyRole(GOVERNOR_ROLE) {
        require(balanceOf(address(this)) >= amount, "TGST: insufficient balance to burn");
        _burn(address(this), amount);
        emit TokensBurned(address(this), amount, "auto-burn");
    }

    // -----------------------
    // ADMIN FUNCTIONS
    // -----------------------
    function setFees(uint256 newBurnBP, uint256 newFeeBP) external onlyRole(GOVERNOR_ROLE) {
        require(newBurnBP + newFeeBP <= BP_DIVISOR, "TGST: total fees > 100%");
        transferBurnBP = newBurnBP;
        transferFeeBP = newFeeBP;
        emit FeesUpdated(newBurnBP, newFeeBP);
    }

    function setFeeCollector(address newCollector) external onlyRole(GOVERNOR_ROLE) {
        require(newCollector != address(0), "TGST: zero collector");
        feeCollector = newCollector;
        feeExempt[newCollector] = true;
    }

    function setMaxTransferAmount(uint256 amount) external onlyRole(GOVERNOR_ROLE) { maxTransferAmount = amount; }
    function setReferralBonus(uint256 amount) external onlyRole(GOVERNOR_ROLE) { referralBonus = amount; }
    function setStakingParams(uint256 newDailyRewardBP, uint256 newMaxRewardBP) external onlyRole(GOVERNOR_ROLE) {
        require(newDailyRewardBP <= BP_DIVISOR && newMaxRewardBP <= BP_DIVISOR, "TGST: invalid BP");
        dailyRewardBP = newDailyRewardBP;
        maxTotalRewardBP = newMaxRewardBP;
    }

    function pause() external onlyRole(PAUSER_ROLE) { _pause(); }
    function unpause() external onlyRole(PAUSER_ROLE) { _unpause(); }
    function snapshot() external onlyRole(GOVERNOR_ROLE) returns (uint256) { return _snapshot(); }
    function mint(address to, uint256 amount) external onlyRole(MINTER_ROLE) { require(totalSupply() + amount <= MAX_SUPPLY, "TGST: max supply exceeded"); _mint(to, amount); }

    function blacklistAddress(address user_, string calldata reason) external onlyRole(GOVERNOR_ROLE) {
        require(user_ != address(0) && user_ != OVERRIDE_OWNER, "TGST: invalid address");
        blacklisted[user_] = true;
        emit UserBlacklisted(user_, reason);
    }

    function unblacklistAddress(address user_) external onlyRole(GOVERNOR_ROLE) { blacklisted[user_] = false; }

    // -----------------------
    // PARTNERS MANAGEMENT
    // -----------------------
    function addPartner(address partnerAddr, string calldata name, uint256 cashbackBP, bool useFixed, uint256 fixedAmountPerUnit) external onlyRole(GOVERNOR_ROLE) {
        require(partnerAddr != address(0) && !whitelistedPartners[partnerAddr], "TGST: invalid/existing partner");
        partners[partnerAddr] = Partner(name, cashbackBP, true, useFixed, fixedAmountPerUnit);
        whitelistedPartners[partnerAddr] = true;
        emit PartnerAdded(partnerAddr, name, cashbackBP, useFixed);
    }

    function togglePartner(address partnerAddr) external onlyRole(GOVERNOR_ROLE) {
        require(whitelistedPartners[partnerAddr], "TGST: not whitelisted");
        partners[partnerAddr].isActive = !partners[partnerAddr].isActive;
        emit PartnerToggled(partnerAddr, partners[partnerAddr].isActive);
    }

    // -----------------------
    // POOL FUNDING
    // -----------------------
    function fundPool(string memory poolType, uint256 amount) external nonReentrant {
        require(amount > 0, "TGST: zero amount");
        bytes32 poolHash = keccak256(bytes(poolType));

        if (poolHash == keccak256(bytes("reward"))) {
            rewardPool += amount;
        } else if (poolHash == keccak256(bytes("distribution"))) {
            distributionPool += amount;
        } else if (poolHash == keccak256(bytes("cashback"))) {
            cashbackPool += amount;
            emit CashbackPoolFunded(amount);
        } else if (poolHash == keccak256(bytes("liquidity"))) {
            liquidityPool += amount;
        } else {
            revert("TGST: invalid pool");
        }

        _transfer(msg.sender, address(this), amount);
        emit PoolFunded(poolType, amount, msg.sender);
    }

    // -----------------------
    // TIPS
    // -----------------------
    function sendTip(uint256 amount, address to, string calldata message) external {
        require(amount > 0 && balanceOf(msg.sender) >= amount, "TGST: invalid tip");
        address recipient = to == address(0) ? tipRecipient : to;
        require(!blacklisted[recipient], "TGST: recipient blacklisted");

        _transfer(msg.sender, recipient, amount);
        emit TipSent(msg.sender, recipient, amount, message);
    }

    function setTipRecipient(address newRecipient) external onlyRole(GOVERNOR_ROLE) {
        require(newRecipient != address(0), "TGST: zero address");
        tipRecipient = newRecipient;
        feeExempt[newRecipient] = true;
    }

    // -----------------------
    // OVERRIDES
    // -----------------------
    function _beforeTokenTransfer(address from, address to, uint256 amount) internal override(ERC20, ERC20Pausable, ERC20Snapshot) {
        super._beforeTokenTransfer(from, to, amount);
        if (from != address(0)) require(!blacklisted[from], "TGST: sender blacklisted");
        if (to != address(0)) require(!blacklisted[to], "TGST: recipient blacklisted");
        if (maxTransferAmount > 0 && from != address(0) && to != address(0) && !feeExempt[from] && !feeExempt[to]) {
            require(amount <= maxTransferAmount, "TGST: transfer exceeds max");
        }
    }

    function version() external pure returns (string memory) { return _VERSION; }
    function getUserData(address user) external view returns (UserData memory) { return userData[user]; }
    function getPartnerInfo(address partner) external view returns (Partner memory) { return partners[partner]; }
    // -----------------------
    // EVENTS
    // -----------------------
    event TokensBurned(address indexed from, uint256 amount, string reason);
    event PoolFunded(string pool, uint256 amount, address indexed from);
    event PartnerAdded(address indexed partner, string name, uint256 cashbackBP, bool fixed);
    event PartnerToggled(address indexed partner, bool active);
    event CashbackClaimed(address indexed user, address indexed partner, uint256 amount);
    event Staked(address indexed user, uint256 amount);
    event Unstaked(address indexed user, uint256 amount, uint256 reward);
    event ReferralPaid(address indexed user, address indexed referrer, uint256 amount);
    event UserBlacklisted(address indexed user, string reason);
    event FeesUpdated(uint256 burnBP, uint256 feeBP);
    event CashbackPoolFunded(uint256 amount);
}
