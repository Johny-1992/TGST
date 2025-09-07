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
import "@openzeppelin/contracts/utils/math/Math.sol";

/// @title TGST Ultimate - Token Global Smart Trade (Version Optimisée)
/// @notice Token universel avec staking, cashback, récompenses dynamiques et gouvernance sécurisée
contract TGSTUltimate is
    ERC20,
    ERC20Burnable,
    ERC20Pausable,
    ERC20Snapshot,
    ERC20Permit,
    AccessControl,
    ReentrancyGuard,
    EIP712
{
    using Math for uint256;

    /////////////////////////////////////////////////////////////////////////////////////////
    // CONSTANTES & CONFIGURATION SÉCURISÉE
    /////////////////////////////////////////////////////////////////////////////////////////
    string private constant _VERSION = "TGST-ULTIMATE-3.0-Optimized";
    address public constant GOVERNANCE_MULTISIG = 0x40BB46B9D10Dd121e7D2150EC3784782ae648090; // multisig sécurisé

    uint256 public constant MAX_SUPPLY = 1_000_000_000_000 * 1e18; // 1 trillion TGST
    uint256 public constant BP_DIVISOR = 10000;
    uint256 public constant MIN_STAKE_SECONDS = 7 days;
    uint256 public constant MAX_PARTNERS = 1000;
    uint256 public constant MAX_MINT_PER_TX = 100_000 * 1e18;
    uint256 public constant MAX_TRANSFER_AMOUNT = 1_000_000 * 1e18;
    uint256 public constant UNSTAKE_COOLDOWN = 7 days;
    uint256 public constant MAX_DAILY_CLAIM = 100 * 1e18;
    uint256 public constant FEE_UPDATE_DELAY = 2 days;
    uint256 public constant MAX_POOL_FUND = 1_000_000 * 1e18;
    uint256 public constant MAX_DAILY_TIP = 10_000 * 1e18;

    /////////////////////////////////////////////////////////////////////////////////////////
    // RÔLES
    /////////////////////////////////////////////////////////////////////////////////////////
    bytes32 public constant GOVERNOR_ROLE = keccak256("GOVERNOR_ROLE");
    bytes32 public constant MINTER_ROLE = keccak256("MINTER_ROLE");
    bytes32 public constant PAUSER_ROLE = keccak256("PAUSER_ROLE");
    bytes32 public constant BRIDGE_ROLE = keccak256("BRIDGE_ROLE");

    /////////////////////////////////////////////////////////////////////////////////////////
    // FRAIS & POOLS
    /////////////////////////////////////////////////////////////////////////////////////////
    uint256 public transferBurnBP = 50; // 0.5%
    uint256 public transferFeeBP = 20;  // 0.2%
    uint256 public pendingBurnBP;
    uint256 public pendingFeeBP;
    uint256 public feeUpdateTime;

    address public feeCollector;
    mapping(address => bool) public feeExempt;
    uint256 public maxTransferAmount = MAX_TRANSFER_AMOUNT;

    uint256 public rewardPool;
    uint256 public distributionPool;
    uint256 public cashbackPool;
    uint256 public liquidityPool;

    /////////////////////////////////////////////////////////////////////////////////////////
    // POURBOIRES DYNAMIQUES
    /////////////////////////////////////////////////////////////////////////////////////////
    mapping(address => address) public dynamicTipRecipient;
    mapping(address => uint256) public lastTipTime;

    /////////////////////////////////////////////////////////////////////////////////////////
    // STRUCTURES
    /////////////////////////////////////////////////////////////////////////////////////////
    struct Partner {
        string name;
        uint256 cashbackBP;
        bool isActive;
        bool useFixedPerUnit;
        uint256 fixedAmountPerUnit;
    }

    struct UserData {
        uint256 stakedAmount;
        uint256 stakeStart;
        uint256 lastClaimed;
        uint256 lastReferralClaim;
        uint256 lastUnstakeTime;
        address referrer;
        uint256 totalCashback;
        uint256 nonce;
    }

    struct PendingChange {
        uint256 newValue;
        uint256 executionTime;
    }

    enum PoolType { Reward, Distribution, Cashback, Liquidity }

    /////////////////////////////////////////////////////////////////////////////////////////
    // MAPPINGS & VARIABLES
    /////////////////////////////////////////////////////////////////////////////////////////
    mapping(address => Partner) public partners;
    mapping(address => bool) public whitelistedPartners;
    mapping(address => UserData) public userData;
    mapping(address => bool) public blacklisted;
    mapping(bytes32 => PendingChange) public pendingChanges;
    uint256 public partnerCount;

    uint256 public dailyRewardBP = 10; // 0.1% daily
    uint256 public maxTotalRewardBP = 2000; // 20%
    uint256 public referralBonus = 50 * 1e18;
    uint256 public consumptionCoefficient = 1e16;
    uint256 public dailyClaimAmount = MAX_DAILY_CLAIM;

    // EIP-712
    bytes32 private constant _CASHBACK_TYPEHASH = keccak256(
        "CashbackClaim(uint256 amountSpent,address partner,address user,uint256 nonce,uint256 timestamp)"
    );

    /////////////////////////////////////////////////////////////////////////////////////////
    // ÉVÉNEMENTS
    /////////////////////////////////////////////////////////////////////////////////////////
    event Staked(address indexed user, uint256 amount);
    event Unstaked(address indexed user, uint256 amount, uint256 reward);
    event TokensBurned(address indexed from, uint256 amount, string reason);
    event PartnerAdded(address indexed partner, string name, uint256 cashbackBP, bool useFixed);
    event PartnerToggled(address indexed partner, bool isActive);
    event PoolFunded(string poolType, uint256 amount, address indexed sender);
    event CashbackPoolFunded(uint256 amount);
    event CashbackClaimed(address indexed user, address indexed partner, uint256 amount);
    event TipSent(address indexed from, address indexed to, uint256 amount, string message);
    event TipRecipientSet(address indexed user, address indexed recipient);
    event FeesUpdated(uint256 burnBP, uint256 feeBP);
    event FeesUpdateScheduled(uint256 newBurnBP, uint256 newFeeBP, uint256 executionTime);
    event UserBlacklisted(address indexed user, string reason);
    event UserUnblacklisted(address indexed user);
    event ReferralPaid(address indexed user, address indexed referrer, uint256 amount);
    event ConsumptionRewardMinted(address indexed user, uint256 amount);

    /////////////////////////////////////////////////////////////////////////////////////////
    // CONSTRUCTEUR
    /////////////////////////////////////////////////////////////////////////////////////////
    constructor(address _feeCollector)
        ERC20("Token Global Smart Trade", "TGST")
        ERC20Permit("TGST")
        EIP712("TGST", _VERSION)
    {
        require(_feeCollector != address(0), "TGST: zero fee collector");
        require(_feeCollector != GOVERNANCE_MULTISIG, "TGST: fee collector cannot be governance");

        feeCollector = _feeCollector;

        // Rôles
        _setupRole(DEFAULT_ADMIN_ROLE, GOVERNANCE_MULTISIG);
        _setupRole(GOVERNOR_ROLE, GOVERNANCE_MULTISIG);
        _setupRole(MINTER_ROLE, GOVERNANCE_MULTISIG);
        _setupRole(PAUSER_ROLE, GOVERNANCE_MULTISIG);
        _setupRole(BRIDGE_ROLE, GOVERNANCE_MULTISIG);

        // Mint initial sécurisé (10% supply)
        _mint(GOVERNANCE_MULTISIG, MAX_SUPPLY / 10);

        // Initialisation pools
        rewardPool = 10_000_000 * 1e18;
        distributionPool = 5_000_000 * 1e18;
        cashbackPool = 2_000_000 * 1e18;

        // Exemptions de frais
        feeExempt[address(this)] = true;
        feeExempt[GOVERNANCE_MULTISIG] = true;
        feeExempt[_feeCollector] = true;

        _pause(); // Déploiement en paused
    }

    /////////////////////////////////////////////////////////////////////////////////////////
    // TRANSFERT AVEC BURN ET FEES
    /////////////////////////////////////////////////////////////////////////////////////////
    function _transfer(address sender, address recipient, uint256 amount) internal virtual override {
        require(!blacklisted[sender] && !blacklisted[recipient], "TGST: blacklisted");
        require(amount >= 1000 || feeExempt[sender] || feeExempt[recipient], "TGST: amount too small");

        if(maxTransferAmount > 0 && !feeExempt[sender] && !feeExempt[recipient]) {
            require(amount <= maxTransferAmount, "TGST: transfer exceeds max");
        }

        if(block.timestamp >= feeUpdateTime) {
            transferBurnBP = pendingBurnBP;
            transferFeeBP = pendingFeeBP;
        }

        if(feeExempt[sender] || feeExempt[recipient] || amount == 0) {
            super._transfer(sender, recipient, amount);
            return;
        }

        uint256 burnAmount = amount.mul(transferBurnBP).div(BP_DIVISOR);
        uint256 feeAmount = amount.mul(transferFeeBP).div(BP_DIVISOR);
        uint256 sendAmount = amount - burnAmount - feeAmount;

        if(burnAmount > 0) super._burn(sender, burnAmount);
        if(feeAmount > 0) super._transfer(sender, feeCollector, feeAmount);
        if(sendAmount > 0) super._transfer(sender, recipient, sendAmount);

        if(burnAmount > 0) emit TokensBurned(sender, burnAmount, "transfer-burn");
    }

    /////////////////////////////////////////////////////////////////////////////////////////
    // STAKING
    /////////////////////////////////////////////////////////////////////////////////////////
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
        require(block.timestamp >= u.lastUnstakeTime + UNSTAKE_COOLDOWN, "TGST: cooldown active");

        uint256 reward = _calculateReward(u);
        require(rewardPool >= reward, "TGST: insufficient reward pool");
        require(balanceOf(address(this)) >= u.stakedAmount + reward, "TGST: insufficient balance");

        rewardPool -= reward;
        u.lastUnstakeTime = block.timestamp;

        uint256 amount = u.stakedAmount;
        u.stakedAmount = 0;
        u.stakeStart = 0;

        _transfer(address(this), msg.sender, amount + reward);
        emit Unstaked(msg.sender, amount, reward);
    }

    function _calculateReward(UserData memory u) internal view returns (uint256) {
        if(u.stakedAmount == 0) return 0;
        uint256 daysStaked = (block.timestamp - u.stakeStart) / 1 days;
        uint256 reward = (u.stakedAmount * dailyRewardBP * daysStaked) / BP_DIVISOR;
        uint256 maxReward = (u.stakedAmount * maxTotalRewardBP) / BP_DIVISOR;
        return reward <= maxReward ? reward : maxReward;
    }

    /////////////////////////////////////////////////////////////////////////////////////////
    // DAILY CLAIM + REFERRAL
    /////////////////////////////////////////////////////////////////////////////////////////
    function claimDailyWithRef(address referrer) external nonReentrant whenNotPaused {
        UserData storage u = userData[msg.sender];
        require(block.timestamp >= u.lastClaimed + 1 days, "TGST: already claimed");
        require(distributionPool >= dailyClaimAmount, "TGST: insufficient distribution pool");

        uint256 totalClaim = dailyClaimAmount;

        if(referrer != address(0) && referrer != msg.sender) {
            require(!blacklisted[referrer], "TGST: referrer blacklisted");
            require(block.timestamp >= u.lastReferralClaim + 1 days, "TGST: referral already claimed today");
            require(distributionPool >= totalClaim + referralBonus, "TGST: insufficient pool for referral");

            totalClaim += referralBonus;
            u.lastReferralClaim = block.timestamp;
            u.referrer = referrer;

            _transfer(address(this), referrer, referralBonus);
            emit ReferralPaid(msg.sender, referrer, referralBonus);
        }

        distributionPool -= dailyClaimAmount;
        u.lastClaimed = block.timestamp;
        _transfer(address(this), msg.sender, dailyClaimAmount);
    }

    /////////////////////////////////////////////////////////////////////////////////////////
    // CASHBACK (EIP-712)
    /////////////////////////////////////////////////////////////////////////////////////////
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
        require(amountSpent > 0 && cashbackPool > 0, "TGST: invalid amount/pool");
        require(block.timestamp <= timestamp + 3600, "TGST: signature expired");

        bytes32 structHash = keccak256(
            abi.encode(_CASHBACK_TYPEHASH, amountSpent, partnerAddr, msg.sender, nonce, timestamp)
        );
        address signer = ECDSA.recover(ECDSA.toEthSignedMessageHash(structHash), signature);
        require(signer == partnerAddr, "TGST: invalid signature");
        require(userData[msg.sender].nonce < nonce, "TGST: invalid nonce");

        uint256 cashback = p.useFixedPerUnit
            ? (amountSpent * p.fixedAmountPerUnit) / 1e18
            : (amountSpent * p.cashbackBP) / BP_DIVISOR;

        require(cashbackPool >= cashback, "TGST: insufficient cashback pool");
        cashbackPool -= cashback;

        userData[msg.sender].totalCashback += cashback;
        userData[msg.sender].nonce = nonce;

        _transfer(address(this), msg.sender, cashback);
        emit CashbackClaimed(msg.sender, partnerAddr, cashback);
    }

    /////////////////////////////////////////////////////////////////////////////////////////
    // REWARD BY CONSUMPTION (MINT AUTOMATIQUE)
    /////////////////////////////////////////////////////////////////////////////////////////
    function rewardByConsumption(address user, address partnerAddr, uint256 consumption) external onlyRole(GOVERNOR_ROLE) {
        require(whitelistedPartners[partnerAddr], "TGST: invalid partner");
        Partner storage p = partners[partnerAddr];
        require(p.isActive, "TGST: partner inactive");

        uint256 reward = p.useFixedPerUnit
            ? (consumption * p.fixedAmountPerUnit) / 1e18
            : (consumption * p.cashbackBP) / BP_DIVISOR;

        require(totalSupply() + reward <= MAX_SUPPLY, "TGST: max supply exceeded");

        rewardPool -= reward;
        _mint(user, reward);
        emit ConsumptionRewardMinted(user, reward);
    }

    /////////////////////////////////////////////////////////////////////////////////////////
    // AUTO BURN
    /////////////////////////////////////////////////////////////////////////////////////////
    function autoBurn(uint256 amount) external onlyRole(GOVERNOR_ROLE) {
        require(balanceOf(address(this)) >= amount, "TGST: insufficient balance to burn");
        _burn(address(this), amount);
        emit TokensBurned(address(this), amount, "auto-burn");
    }

    /////////////////////////////////////////////////////////////////////////////////////////
    // POURBOIRES
    /////////////////////////////////////////////////////////////////////////////////////////
    function sendTip(uint256 amount, address to, string calldata message) external {
        require(amount > 0 && balanceOf(msg.sender) >= amount, "TGST: invalid tip");
        address recipient = to == address(0) ? dynamicTipRecipient[msg.sender] : to;
        require(!blacklisted[recipient], "TGST: recipient blacklisted");
        require(amount <= MAX_DAILY_TIP, "TGST: exceeds daily tip max");

        _transfer(msg.sender, recipient, amount);
        emit TipSent(msg.sender, recipient, amount, message);
    }

    function setTipRecipient(address newRecipient) external onlyRole(GOVERNOR_ROLE) {
        require(newRecipient != address(0), "TGST: zero address");
        dynamicTipRecipient[msg.sender] = newRecipient;
        feeExempt[newRecipient] = true;
        emit TipRecipientSet(msg.sender, newRecipient);
    }

    /////////////////////////////////////////////////////////////////////////////////////////
    // PARTENAIRES
    /////////////////////////////////////////////////////////////////////////////////////////
    function addPartner(
        address partnerAddr,
        string calldata name,
        uint256 cashbackBP,
        bool useFixed,
        uint256 fixedAmountPerUnit
    ) external onlyRole(GOVERNOR_ROLE) {
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

    /////////////////////////////////////////////////////////////////////////////////////////
    // POOLS
    /////////////////////////////////////////////////////////////////////////////////////////
    function fundPool(string memory poolType, uint256 amount) external nonReentrant {
        require(amount > 0, "TGST: zero amount");
        bytes32 poolHash = keccak256(bytes(poolType));

        if(poolHash == keccak256(bytes("reward"))) rewardPool += amount;
        else if(poolHash == keccak256(bytes("distribution"))) distributionPool += amount;
        else if(poolHash == keccak256(bytes("cashback"))) {
            cashbackPool += amount;
            emit CashbackPoolFunded(amount);
        } else if(poolHash == keccak256(bytes("liquidity"))) liquidityPool += amount;
        else revert("TGST: invalid pool");

        _transfer(msg.sender, address(this), amount);
        emit PoolFunded(poolType, amount, msg.sender);
    }

    /////////////////////////////////////////////////////////////////////////////////////////
    // ADMIN & CONTROLE
    /////////////////////////////////////////////////////////////////////////////////////////
    function blacklistAddress(address user_, string calldata reason) external onlyRole(GOVERNOR_ROLE) {
        blacklisted[user_] = true;
        emit UserBlacklisted(user_, reason);
    }

    function unblacklistAddress(address user_) external onlyRole(GOVERNOR_ROLE) {
        blacklisted[user_] = false;
        emit UserUnblacklisted(user_);
    }

    function setFees(uint256 newBurnBP, uint256 newFeeBP) external onlyRole(GOVERNOR_ROLE) {
        require(newBurnBP + newFeeBP <= BP_DIVISOR, "TGST: total fees > 100%");
        transferBurnBP = newBurnBP;
        transferFeeBP = newFeeBP;
        emit FeesUpdated(newBurnBP, newFeeBP);
    }

    function pause() external onlyRole(PAUSER_ROLE) { _pause(); }
    function unpause() external onlyRole(PAUSER_ROLE) { _unpause(); }

    /////////////////////////////////////////////////////////////////////////////////////////
    // OVERRIDES
    /////////////////////////////////////////////////////////////////////////////////////////
    function _beforeTokenTransfer(address from, address to, uint256 amount)
        internal override(ERC20, ERC20Pausable, ERC20Snapshot)
    {
        super._beforeTokenTransfer(from, to, amount);
        if(from != address(0)) require(!blacklisted[from], "TGST: sender blacklisted");
        if(to != address(0)) require(!blacklisted[to], "TGST: recipient blacklisted");
        if(maxTransferAmount > 0 && from != address(0) && to != address(0) && !feeExempt[from] && !feeExempt[to])
            require(amount <= maxTransferAmount, "TGST: transfer exceeds max");
    }

    function version() external pure returns (string memory) { return _VERSION; }

    function getUserData(address user) external view returns (UserData memory) { return userData[user]; }
    function getPartnerInfo(address partner) external view returns (Partner memory) { return partners[partner]; }

    function _domainSeparator() internal view override returns (bytes32) { return EIP712._domainSeparatorV4(); }
    function _hashTypedData(bytes32 structHash) internal view virtual returns (bytes32) { return EIP712.hash(structHash); }
}
