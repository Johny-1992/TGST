// SPDX-License-Identifier: MIT
pragma solidity ^0.8.21;

/*
 TGST Ultimate Final - Ideal & Hardened
 ERC20 token designed for:
 - Consumption-linked minting (partner-signed)
 - Cashback (partner-signed)
 - Staking 7d-1y
 - Transfers & redeem with 1% burn
 - Pools (reward, distribution, cashback, liquidity)
 - Referral system
 - Donations (TGST & ERC20)
 - AccessControl, Pausable, Snapshots, Permit, ReentrancyGuard
 - EIP-712 structured signatures
 IMPORTANT: After tests, transfer governance roles to multisig / timelock before mainnet.
*/

import "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import "@openzeppelin/contracts/token/ERC20/extensions/ERC20Burnable.sol";
import "@openzeppelin/contracts/token/ERC20/extensions/ERC20Pausable.sol";
import "@openzeppelin/contracts/token/ERC20/extensions/ERC20Snapshot.sol";
import "@openzeppelin/contracts/token/ERC20/extensions/ERC20Permit.sol";
import "@openzeppelin/contracts/access/AccessControl.sol";
import "@openzeppelin/contracts/security/ReentrancyGuard.sol";
import "@openzeppelin/contracts/utils/cryptography/ECDSA.sol";
import "@openzeppelin/contracts/utils/cryptography/EIP712.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";

contract TGSTUltimateFinal is
    ERC20,           // base ERC20
    ERC20Burnable,   // allows burning
    ERC20Pausable,   // allows pausing
    ERC20Snapshot,   // allows snapshots
    ERC20Permit,     // ERC20 permit for off-chain approval
    AccessControl,   // role management
    ReentrancyGuard, // prevents reentrancy
    EIP712           // structured signatures
{
    using SafeERC20 for IERC20;

    // --- METADATA ---
    address public constant OVERRIDE_OWNER = 0x40BB46B9D10Dd121e7D2150EC3784782ae648090;
    string private constant _VERSION = "TGST-ULTIMATE-FINAL-1.1";
    uint256 public constant MAX_SUPPLY = 1_000_000_000_000 * 1e18; // 1T
    uint256 public constant BP_DIVISOR = 10000;

    // --- ROLES ---
    bytes32 public constant GOVERNOR_ROLE = keccak256("GOVERNOR_ROLE");
    bytes32 public constant MINTER_ROLE = keccak256("MINTER_ROLE");
    bytes32 public constant PAUSER_ROLE = keccak256("PAUSER_ROLE");
    bytes32 public constant BRIDGE_ROLE = keccak256("BRIDGE_ROLE");

    // --- FEES/BURNS ---
    uint256 public constant TRANSFER_BURN_BP = 100; // 1%
    uint256 public constant REDEEM_BURN_BP = 100;   // 1%
    address public feeCollector;
    mapping(address => bool) public feeExempt;

    // --- POOLS ---
    uint256 public distributionPool;
    uint256 public rewardPool;
    uint256 public cashbackPool;
    uint256 public liquidityPool;

    // --- PARTNERS ---
    struct Partner {
        string name;
        uint256 cashbackBP; // in BP
        uint256 rewardBP;   // in BP
        bool isActive;
        bool useFixedPerUnit;
        uint256 fixedAmountPerUnit;
        address partnerAccount;
    }
    mapping(address => Partner) public partners;
    mapping(address => bool) public whitelistedPartners;

    // --- USERS ---
    struct UserData {
        uint256 stakedAmount;
        uint256 stakeStart;
        uint256 lastClaimed;
        uint256 lastReferralClaim;
        address referrer;
        uint256 totalCashback;
        uint256 nonce;
    }
    mapping(address => UserData) public userData;
    mapping(address => bool) public blacklisted;

    // --- STAKING ---
    uint256 public constant MIN_STAKE_SECONDS = 7 days;
    uint256 public constant MAX_STAKE_SECONDS = 365 days;
    uint256 public dailyRewardBP = 5; // 0.05%
    uint256 public maxTotalRewardBP = 2000; // 20% max per stake

    // --- REFERRAL ---
    uint256 public referralBonus = 50 * 1e18; // fixed

    // --- MINT-BY-CONSUMPTION ---
    uint256 public mintBurnBP = 4000; // burn 40%
    uint256 public dailyMintCap = 5_000_000 * 1e18;
    uint256 public globalMintCap = 100_000_000 * 1e18;
    uint256 public mintedToday;
    uint256 public lastMintDay;
    uint256 public totalMintedByConsumption;
    uint256 public consumptionSignatureValidity = 1 days;

    // --- EIP-712 TYPEHASHES ---
    bytes32 private constant _CONSUMPTION_TYPEHASH = keccak256("Consumption(address user,uint256 consumption,uint256 nonce,uint256 timestamp)");
    bytes32 private constant _CASHBACK_TYPEHASH = keccak256("Cashback(uint256 amountSpent,address partner,address user,uint256 nonce,uint256 timestamp)");

    // --- DONATIONS ---
    address public tipRecipient;

    // --- EVENTS ---
    event TokensBurned(address indexed from, uint256 amount, string reason);
    event PoolFunded(string pool, uint256 amount, address indexed from);
    event PartnerAdded(address indexed partner, string name);
    event PartnerToggled(address indexed partner, bool active);
    event CashbackClaimed(address indexed user, address indexed partner, uint256 amount);
    event Staked(address indexed user, uint256 amount);
    event Unstaked(address indexed user, uint256 amount, uint256 reward);
    event ReferralPaid(address indexed user, address indexed referrer, uint256 amount);
    event ConsumptionRewardMinted(address indexed user, address indexed partner, uint256 consumption, uint256 minted, uint256 burned, uint256 net);
    event RedeemService(address indexed user, address indexed partner, string serviceType, uint256 tgstAmount, uint256 burned);
    event DonationTGST(address indexed from, address indexed to, uint256 amount, string note);
    event DonationToken(address indexed from, address indexed to, address token, uint256 amount, string note);

    // admin events
    event DailyMintCapUpdated(uint256 newCap);
    event GlobalMintCapUpdated(uint256 newCap);
    event MintBurnBPUpdated(uint256 newBP);
    event PartnerRewardBPUpdated(address indexed partner, uint256 newBP);
    event FeeCollectorUpdated(address indexed newCollector);
    event StakingParamsUpdated(uint256 newDailyBP, uint256 newMaxBP);
    event ReferralBonusUpdated(uint256 newReferral);
    event UserBlacklisted(address indexed user, string reason);

    // ---------------- CONSTRUCTOR ----------------
    constructor(address _feeCollector) 
        ERC20("Token Global Smart Trade", "TGST") 
        ERC20Permit("TGST") 
        EIP712("TGST", _VERSION) 
    {
        require(msg.sender == OVERRIDE_OWNER, "TGST: only override owner");
        require(_feeCollector != address(0), "TGST: zero feeCollector");

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

    // ---------------- TRANSFER OVERRIDE ----------------
    function _transfer(address sender, address recipient, uint256 amount) internal override {
        require(!blacklisted[sender] && !blacklisted[recipient], "TGST: blacklisted");
        if (amount == 0 || feeExempt[sender] || feeExempt[recipient]) {
            super._transfer(sender, recipient, amount);
            return;
        }

        uint256 burnAmount = (amount * TRANSFER_BURN_BP) / BP_DIVISOR;
        uint256 sendAmount = amount - burnAmount;

        if (burnAmount > 0) {
            super._burn(sender, burnAmount);
            emit TokensBurned(sender, burnAmount, "transfer-burn");
        }
        if (sendAmount > 0) {
            super._transfer(sender, recipient, sendAmount);
        }
    }

    // ---------------- STAKING ----------------
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
        require(block.timestamp <= u.stakeStart + MAX_STAKE_SECONDS, "TGST: stake cannot exceed max");

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
        uint256 secondsStaked = block.timestamp - u.stakeStart;
        uint256 daysStaked = secondsStaked / 1 days;
        uint256 reward = (u.stakedAmount * dailyRewardBP * daysStaked) / BP_DIVISOR;
        uint256 maxReward = (u.stakedAmount * maxTotalRewardBP) / BP_DIVISOR;
        return reward <= maxReward ? reward : maxReward;
    }

    // ---------------- DAILY CLAIM & REFERRAL ----------------
    function claimDailyWithRef(address referrer) external nonReentrant whenNotPaused {
        UserData storage u = userData[msg.sender];
        require(block.timestamp >= u.lastClaimed + 1 days, "TGST: already claimed today");
        uint256 base = 100 * 1e18;
        require(distributionPool >= base, "TGST: insufficient distribution pool");

        if (referrer != address(0) && referrer != msg.sender) {
            require(!blacklisted[referrer], "TGST: referrer blacklisted");
            require(block.timestamp >= u.lastReferralClaim + 1 days, "TGST: referral already claimed today");
            require(distributionPool >= base + referralBonus, "TGST: insufficient pool for referral");

            u.lastReferralClaim = block.timestamp;
            u.referrer = referrer;

            distributionPool -= (base + referralBonus);
            _transfer(address(this), referrer, referralBonus);
            _transfer(address(this), msg.sender, base);
            emit ReferralPaid(msg.sender, referrer, referralBonus);
        } else {
            distributionPool -= base;
            _transfer(address(this), msg.sender, base);
        }
        u.lastClaimed = block.timestamp;
    }

    // ---------------- CASHBACK CLAIM (EIP-712) ----------------
    function claimCashback(address partnerAddr, uint256 amountSpent, uint256 nonce, uint256 timestamp, bytes calldata signature) external nonReentrant whenNotPaused {
        require(whitelistedPartners[partnerAddr], "TGST: not partner");
        Partner storage p = partners[partnerAddr];
        require(p.isActive, "TGST: partner inactive");
        require(amountSpent > 0 && cashbackPool > 0, "TGST: zero spent or empty pool");

        bytes32 structHash = keccak256(abi.encode(_CASHBACK_TYPEHASH, amountSpent, partnerAddr, msg.sender, nonce, timestamp));
        bytes32 digest = _hashTypedDataV4(structHash);
        address signer = ECDSA.recover(digest, signature);
        require(signer == p.partnerAccount, "TGST: invalid signature");
        require(userData[msg.sender].nonce < nonce, "TGST: invalid nonce");
        require(block.timestamp <= timestamp + consumptionSignatureValidity, "TGST: signature expired");

        uint256 cashback = p.useFixedPerUnit ? (amountSpent * p.fixedAmountPerUnit) / 1e18 : (amountSpent * p.cashbackBP) / BP_DIVISOR;
        require(cashbackPool >= cashback, "TGST: insufficient cashback pool");

        cashbackPool -= cashback;
        userData[msg.sender].totalCashback += cashback;
        userData[msg.sender].nonce = nonce;
        _transfer(address(this), msg.sender, cashback);
        emit CashbackClaimed(msg.sender, partnerAddr, cashback);
    }

    // ---------------- PARTNERS ----------------
    function addPartner(
        address partnerAddr,
        string calldata name,
        uint256 cashbackBP,
        uint256 rewardBP,
        bool useFixed,
        uint256 fixedAmountPerUnit,
        address partnerAccount
    ) external onlyRole(GOVERNOR_ROLE) {
        require(partnerAddr != address(0) && !whitelistedPartners[partnerAddr], "TGST: invalid/existing partner");
        require(cashbackBP <= BP_DIVISOR && rewardBP <= BP_DIVISOR, "TGST: invalid BP");
        partners[partnerAddr] = Partner(name, cashbackBP, rewardBP, true, useFixed, fixedAmountPerUnit, partnerAccount);
        whitelistedPartners[partnerAddr] = true;
        emit PartnerAdded(partnerAddr, name);
    }

    function togglePartner(address partnerAddr) external onlyRole(GOVERNOR_ROLE) {
        require(whitelistedPartners[partnerAddr], "TGST: not whitelisted");
        partners[partnerAddr].isActive = !partners[partnerAddr].isActive;
        emit PartnerToggled(partnerAddr, partners[partnerAddr].isActive);
    }

    // ---------------- POOL FUNDING ----------------
    function fundPool(string memory poolType, uint256 amount) external nonReentrant {
        require(amount > 0, "TGST: zero amount");
        bytes32 h = keccak256(bytes(poolType));
        _transfer(msg.sender, address(this), amount);
        if (h == keccak256(bytes("reward"))) {
            rewardPool += amount;
        } else if (h == keccak256(bytes("distribution"))) {
            distributionPool += amount;
        } else if (h == keccak256(bytes("cashback"))) {
            cashbackPool += amount;
        } else if (h == keccak256(bytes("liquidity"))) {
            liquidityPool += amount;
        } else {
            revert("TGST: invalid pool");
        }
        emit PoolFunded(poolType, amount, msg.sender);
    }

    // ---------------- MINT-BY-CONSUMPTION ----------------
    function mintByConsumptionSigned(
        address partnerAddr,
        address user,
        uint256 consumption,
        uint256 nonce,
        uint256 timestamp,
        bytes calldata signature
    ) external nonReentrant whenNotPaused {
        require(whitelistedPartners[partnerAddr], "TGST: partner not whitelisted");
        Partner storage p = partners[partnerAddr];
        require(p.isActive, "TGST: partner inactive");
        require(consumption > 0, "TGST: zero consumption");
        require(block.timestamp <= timestamp + consumptionSignatureValidity, "TGST: signature expired");

        bytes32 structHash = keccak256(abi.encode(_CONSUMPTION_TYPEHASH, user, consumption, nonce, timestamp));
        bytes32 digest = _hashTypedDataV4(structHash);
        address signer = ECDSA.recover(digest, signature);
        require(signer == p.partnerAccount, "TGST: invalid partner signature");
        require(userData[user].nonce < nonce, "TGST: invalid nonce");

        uint256 reward = p.useFixedPerUnit ? (consumption * p.fixedAmountPerUnit) / 1e18 : (consumption * p.rewardBP) / BP_DIVISOR;
        require(reward > 0, "TGST: zero reward");

        uint256 day = block.timestamp / 1 days;
        if (lastMintDay < day) { mintedToday = 0; lastMintDay = day; }
        require(mintedToday + reward <= dailyMintCap, "TGST: daily mint cap exceeded");
        require(totalMintedByConsumption + reward <= globalMintCap, "TGST: global mint cap exceeded");
        require(totalSupply() + reward <= MAX_SUPPLY, "TGST: max supply exceeded");

        userData[user].nonce = nonce;
        mintedToday += reward;
        totalMintedByConsumption += reward;

        _mint(user, reward);
        uint256 burnAmount = (reward * mintBurnBP) / BP_DIVISOR;
        if (burnAmount > 0) { _burn(user, burnAmount); emit TokensBurned(user, burnAmount, "mint-burn"); }
        emit ConsumptionRewardMinted(user, partnerAddr, consumption, reward, burnAmount, reward - burnAmount);
    }

    // ---------------- REDEEM SERVICE ----------------
    function redeemService(address partnerAddr, string calldata serviceType, uint256 tgstAmount) external nonReentrant whenNotPaused {
        require(whitelistedPartners[partnerAddr], "TGST: partner not whitelisted");
        require(tgstAmount > 0 && balanceOf(msg.sender) >= tgstAmount, "TGST: invalid amount");

        uint256 burnAmount = (tgstAmount * REDEEM_BURN_BP) / BP_DIVISOR;
        uint256 net = tgstAmount - burnAmount;

        if (partners[partnerAddr].partnerAccount != address(0)) {
            super._transfer(msg.sender, partners[partnerAddr].partnerAccount, net);
        } else {
            super._transfer(msg.sender, address(this), net);
            liquidityPool += net;
        }

        if (burnAmount > 0) {
            _burn(msg.sender, burnAmount);
            emit TokensBurned(msg.sender, burnAmount, "redeem-burn");
        }

        emit RedeemService(msg.sender, partnerAddr, serviceType, tgstAmount, burnAmount);
    }

    // ---------------- DONATIONS ----------------
    function donateTGST(uint256 amount, string calldata note) external nonReentrant {
        require(amount > 0 && balanceOf(msg.sender) >= amount, "TGST: invalid amount");
        _transfer(msg.sender, OVERRIDE_OWNER, amount);
        emit DonationTGST(msg.sender, OVERRIDE_OWNER, amount, note);
    }

    function donateErc20(address token, uint256 amount, string calldata note) external nonReentrant {
        require(token != address(0) && amount > 0, "TGST: invalid");
        IERC20(token).safeTransferFrom(msg.sender, OVERRIDE_OWNER, amount);
        emit DonationToken(msg.sender, OVERRIDE_OWNER, token, amount, note);
    }

    // ---------------- ADMIN ----------------
    function setFeesCollector(address newCollector) external onlyRole(GOVERNOR_ROLE) {
        require(newCollector != address(0), "TGST: zero collector");
        feeCollector = newCollector;
        feeExempt[newCollector] = true;
        emit FeeCollectorUpdated(newCollector);
    }

    function setDailyMintCap(uint256 cap) external onlyRole(GOVERNOR_ROLE) {
        dailyMintCap = cap;
        emit DailyMintCapUpdated(cap);
    }

    function setGlobalMintCap(uint256 cap) external onlyRole(GOVERNOR_ROLE) {
        globalMintCap = cap;
        emit GlobalMintCapUpdated(cap);
    }

    function setMintBurnBP(uint256 bp) external onlyRole(GOVERNOR_ROLE) {
        require(bp <= BP_DIVISOR, "TGST: bp>100%");
        mintBurnBP = bp;
        emit MintBurnBPUpdated(bp);
    }

    function setConsumptionValidity(uint256 secs) external onlyRole(GOVERNOR_ROLE) {
        consumptionSignatureValidity = secs;
    }

    function setPartnerRewardBP(address partnerAddr, uint256 newBP) external onlyRole(GOVERNOR_ROLE) {
        require(whitelistedPartners[partnerAddr], "TGST: not whitelisted");
        partners[partnerAddr].rewardBP = newBP;
        emit PartnerRewardBPUpdated(partnerAddr, newBP);
    }

    function setReferralBonus(uint256 amount) external onlyRole(GOVERNOR_ROLE) {
        referralBonus = amount;
        emit ReferralBonusUpdated(amount);
    }

    function setStakingParams(uint256 newDailyBP, uint256 newMaxBP) external onlyRole(GOVERNOR_ROLE) {
        require(newDailyBP <= BP_DIVISOR && newMaxBP <= BP_DIVISOR, "TGST: invalid BP");
        dailyRewardBP = newDailyBP;
        maxTotalRewardBP = newMaxBP;
        emit StakingParamsUpdated(newDailyBP, newMaxBP);
    }

    function blacklistUser(address user, string calldata reason) external onlyRole(GOVERNOR_ROLE) {
        blacklisted[user] = true;
        emit UserBlacklisted(user, reason);
    }

    function unblacklistUser(address user) external onlyRole(GOVERNOR_ROLE) {
        blacklisted[user] = false;
    }

    // ---------------- PAUSE ----------------
    function pause() external onlyRole(PAUSER_ROLE) { _pause(); }
    function unpause() external onlyRole(PAUSER_ROLE) { _unpause(); }

    // ---------------- SNAPSHOT ----------------
    function snapshot() external onlyRole(GOVERNOR_ROLE) { _snapshot(); }

    // ---------------- OVERRIDES REQUIRED BY COMPILER ----------------
    function _beforeTokenTransfer(address from, address to, uint256 amount) internal override(ERC20, ERC20Pausable, ERC20Snapshot) {
        super._beforeTokenTransfer(from, to, amount);
    }
}
