// SPDX-License-Identifier: MIT
pragma solidity ^0.8.21;

/*
 TGST Final - Hardened & Corrected
 - ERC20 + Permit + Snapshot + Burnable + Pausable
 - AccessControl roles, ReentrancyGuard
 - EIP-712 signature verification via OpenZeppelin (ERC20Permit -> EIP712)
 - Mint-by-consumption signed by partnerAccount (strict nonce)
 - Cashback signed by partnerAccount (strict nonce)
 - Staking (7d - 1y) with reward pool
 - Daily claim + referral
 - Pools (reward, distribution, cashback, liquidity)
 - Redeem service uses pull -> burn -> distribute pattern
 - Per-user & per-day caps for consumption minting
 - Circuit-breaker: auto-pause on abnormal minting
 - Events for all important state changes
 IMPORTANT: After exhaustive testing, transition governance roles to a Timelock / multisig.
*/

import "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import "@openzeppelin/contracts/token/ERC20/extensions/ERC20Burnable.sol";
import "@openzeppelin/contracts/token/ERC20/extensions/ERC20Snapshot.sol";
import "@openzeppelin/contracts/token/ERC20/extensions/ERC20Permit.sol";
import "@openzeppelin/contracts/access/AccessControl.sol";
import "@openzeppelin/contracts/security/ReentrancyGuard.sol";
import "@openzeppelin/contracts/security/Pausable.sol";
import "@openzeppelin/contracts/utils/cryptography/ECDSA.sol";

contract TGSTFinal is
    ERC20,
    ERC20Permit,
    ERC20Snapshot,
    ERC20Burnable,
    Pausable,
    AccessControl,
    ReentrancyGuard
{
    using ECDSA for bytes32;

    // -----------------------
    // METADATA / CONSTANTS
    // -----------------------
    address public immutable OVERRIDE_OWNER; // owner address (set at deployment)
    string private constant _VERSION = "TGST-FINAL-1.0";
    uint8 private constant _DECIMALS = 18;
    uint256 public constant MAX_SUPPLY = 1_000_000_000_000 * 10**_DECIMALS; // 1T
    uint256 public constant BP_DIVISOR = 10000;

    // -----------------------
    // ROLES
    // -----------------------
    bytes32 public constant GOVERNOR_ROLE = keccak256("GOVERNOR_ROLE");
    bytes32 public constant MINTER_ROLE   = keccak256("MINTER_ROLE");
    bytes32 public constant PAUSER_ROLE   = keccak256("PAUSER_ROLE");
    bytes32 public constant BRIDGE_ROLE   = keccak256("BRIDGE_ROLE");

    // -----------------------
    // FEES & BURN (BP)
    // -----------------------
    uint256 public transferBurnBP = 100; // 1.00%
    uint256 public redeemBurnBP   = 100; // 1.00%
    uint256 public mintBurnBP     = 4000; // 40.00% of minted reward
    address public feeCollector;
    mapping(address => bool) public feeExempt;

    // -----------------------
    // POOLS
    // -----------------------
    uint256 public distributionPool;
    uint256 public rewardPool;
    uint256 public cashbackPool;
    uint256 public liquidityPool;

    // -----------------------
    // PARTNER STRUCT
    // -----------------------
    struct Partner {
        string name;
        bool isActive;
        uint256 cashbackBP;
        uint256 rewardBP;
        bool useFixedPerUnit;
        uint256 fixedPerUnit; // scaled by 1e18 if used
        address partnerAccount; // EOA that signs consumption/cashback
        uint256 mintCap; // total tokens partner can mint
        uint256 mintedByPartner;
    }
    mapping(address => Partner) public partners;
    mapping(address => bool) public whitelistedPartner;

    // -----------------------
    // USER STRUCT
    // -----------------------
    struct UserData {
        uint256 stakedAmount;
        uint256 stakeStart;
        uint256 lastClaimed;
        uint256 lastReferralClaim;
        address referrer;
        uint256 totalCashback;
        uint256 nonce; // strict equality expected
        bool kyc;
        bool blacklisted;
    }
    mapping(address => UserData) public userData;

    // -----------------------
    // STAKING & REWARD PARAMS
    // -----------------------
    uint256 public constant MIN_STAKE_SECONDS = 7 days;
    uint256 public constant MAX_STAKE_SECONDS = 365 days;
    uint256 public dailyRewardBP = 10;      // 0.10% daily default
    uint256 public maxTotalRewardBP = 2000; // 20% max per stake
    uint256 public referralBonus = 50 * 10**_DECIMALS;

    // -----------------------
    // MINT-BY-CONSUMPTION CONTROL
    // -----------------------
    uint256 public dailyMintCap = 5_000_000 * 10**_DECIMALS;
    uint256 public globalMintCap = 100_000_000 * 10**_DECIMALS;
    uint256 public mintedToday;
    uint256 public lastMintDay;
    uint256 public totalMintedByConsumption;
    uint256 public consumptionValiditySeconds = 1 days;

    // per-user daily cap to prevent spam
    mapping(address => uint256) public userMintedToday;
    mapping(address => uint256) public userLastMintDay;
    uint256 public maxPerUserDaily = 10_000 * 10**_DECIMALS; // configurable guard

    // -----------------------
    // EIP-712 TYPEHASHES (use ERC20Permit/EIP712 _hashTypedDataV4)
    // -----------------------
    bytes32 private constant _CONSUMPTION_TYPEHASH = keccak256("Consumption(address user,uint256 consumption,uint256 nonce,uint256 timestamp)");
    bytes32 private constant _CASHBACK_TYPEHASH    = keccak256("Cashback(uint256 amountSpent,address partner,address user,uint256 nonce,uint256 timestamp)");

    // -----------------------
    // AUTO-ADJUST / SAFETY
    // -----------------------
    uint256 public maxTransferBurnBP = 2000; // 20%
    uint256 public minTransferBurnBP = 0;
    uint256 public maxDailyRewardBP = 200; // 2%
    uint256 public minDailyRewardBP = 1;   // 0.01%

    // -----------------------
    // TIP / DONATIONS
    // -----------------------
    address public tipRecipient;

    // -----------------------
    // EVENTS
    // -----------------------
    event TokensBurned(address indexed from, uint256 amount, string reason);
    event PoolFunded(string pool, uint256 amount, address indexed from);
    event PartnerAdded(address indexed partner, string name);
    event PartnerToggled(address indexed partner, bool active);
    event CashbackClaimed(address indexed user, address indexed partner, uint256 amount);
    event Staked(address indexed user, uint256 amount);
    event Unstaked(address indexed user, uint256 amount, uint256 reward);
    event ReferralPaid(address indexed user, address indexed referrer, uint256 amount);
    event ConsumptionMint(address indexed user, address indexed partner, uint256 consumption, uint256 minted, uint256 burned, uint256 net);
    event RedeemService(address indexed user, address indexed partner, string serviceType, uint256 tgstAmount, uint256 burned);
    event DonationTGST(address indexed from, address indexed to, uint256 amount, string note);
    event AutoPauseTriggered(string reason);

    // Admin events
    event DailyMintCapUpdated(uint256 newCap);
    event GlobalMintCapUpdated(uint256 newCap);
    event MintBurnBPUpdated(uint256 newBP);
    event FeeCollectorUpdated(address indexed newCollector);
    event StakingParamsUpdated(uint256 newDailyBP, uint256 newMaxBP);
    event ReferralBonusUpdated(uint256 newReferral);

    // -----------------------
    // CONSTRUCTOR
    // -----------------------
    constructor(address overrideOwner_, address feeCollector_) 
        ERC20("Token Global Smart Trade", "TGST")
        ERC20Permit("Token Global Smart Trade")
    {
        require(overrideOwner_ != address(0), "zero owner");
        require(feeCollector_ != address(0), "zero feeCollector");
        OVERRIDE_OWNER = overrideOwner_;
        feeCollector = feeCollector_;
        tipRecipient = overrideOwner_;

        _setupRole(DEFAULT_ADMIN_ROLE, OVERRIDE_OWNER);
        _setupRole(GOVERNOR_ROLE, OVERRIDE_OWNER);
        _setupRole(MINTER_ROLE, OVERRIDE_OWNER);
        _setupRole(PAUSER_ROLE, OVERRIDE_OWNER);
        _setupRole(BRIDGE_ROLE, OVERRIDE_OWNER);

        // Initial conservative mint: 100B (10% of 1T)
        uint256 initial = 100_000_000_000 * 10**_DECIMALS;
        _mint(OVERRIDE_OWNER, initial);

        feeExempt[address(this)] = true;
        feeExempt[OVERRIDE_OWNER] = true;
        feeExempt[feeCollector] = true;
        feeExempt[tipRecipient] = true;
    }

    // -----------------------
    // DECIMALS
    // -----------------------
    function decimals() public pure override returns (uint8) {
        return _DECIMALS;
    }

    // -----------------------
    // TRANSFER OVERRIDE (burn on transfer unless exempt)
    // -----------------------
    function _transfer(address sender, address recipient, uint256 amount) internal override {
        require(!userData[sender].blacklisted && !userData[recipient].blacklisted, "TGST: blacklisted");
        if (amount == 0 || feeExempt[sender] || feeExempt[recipient] || paused()) {
            super._transfer(sender, recipient, amount);
            return;
        }

        uint256 burnAmount = (amount * transferBurnBP) / BP_DIVISOR;
        uint256 sendAmount = amount - burnAmount;

        if (burnAmount > 0) {
            // Burn directly from sender to avoid intermediate accounting
            super._burn(sender, burnAmount);
            emit TokensBurned(sender, burnAmount, "transfer-burn");
        }
        super._transfer(sender, recipient, sendAmount);
    }

    // -----------------------
    // STAKING
    // -----------------------
    function stake(uint256 amount) external nonReentrant whenNotPaused {
        require(amount > 0 && balanceOf(msg.sender) >= amount, "TGST: invalid stake");
        // pull tokens into contract
        super._transfer(msg.sender, address(this), amount);

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
        require(rewardPool >= reward, "TGST: insufficient rewardPool");
        rewardPool -= reward;

        uint256 amount = u.stakedAmount;
        u.stakedAmount = 0;
        u.stakeStart = 0;

        // send principal + reward from contract
        super._transfer(address(this), msg.sender, amount + reward);
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
    // DAILY CLAIM & REFERRAL (distribution pool)
    // -----------------------
    function claimDailyWithRef(address referrer) external nonReentrant whenNotPaused {
        UserData storage u = userData[msg.sender];
        require(block.timestamp >= u.lastClaimed + 1 days, "TGST: already claimed today");
        uint256 base = 100 * 10**_DECIMALS;
        require(distributionPool >= base, "TGST: insufficient distribution pool");

        if (referrer != address(0) && referrer != msg.sender) {
            require(!userData[referrer].blacklisted, "TGST: referrer blacklisted");
            require(block.timestamp >= u.lastReferralClaim + 1 days, "TGST: referral already claimed today");
            require(distributionPool >= base + referralBonus, "TGST: insufficient pool for referral");

            u.lastReferralClaim = block.timestamp;
            u.referrer = referrer;

            distributionPool -= (base + referralBonus);
            super._transfer(address(this), referrer, referralBonus); // avoid burn on partner receipt
            super._transfer(address(this), msg.sender, base);
            emit ReferralPaid(msg.sender, referrer, referralBonus);
        } else {
            distributionPool -= base;
            super._transfer(address(this), msg.sender, base);
        }
        u.lastClaimed = block.timestamp;
    }

    // -----------------------
    // CASHBACK CLAIM (EIP-712 signed by partnerAccount)
    // -----------------------
    function claimCashback(
        address partnerAddr,
        uint256 amountSpent,
        uint256 nonce,
        uint256 timestamp,
        bytes calldata signature
    ) external nonReentrant whenNotPaused {
        require(whitelistedPartner[partnerAddr], "TGST: not partner");
        Partner storage p = partners[partnerAddr];
        require(p.isActive, "TGST: partner inactive");
        require(amountSpent > 0 && cashbackPool > 0, "TGST: zero spent or empty pool");

        // strict nonce: must equal stored nonce for user
        require(userData[msg.sender].nonce == nonce, "TGST: invalid nonce");
        require(block.timestamp <= timestamp + consumptionValiditySeconds, "TGST: signature expired");

        bytes32 structHash = keccak256(abi.encode(_CASHBACK_TYPEHASH, amountSpent, partnerAddr, msg.sender, nonce, timestamp));
        bytes32 digest = _hashTypedDataV4(structHash);
        address signer = ECDSA.recover(digest, signature);
        require(signer == p.partnerAccount, "TGST: invalid signature");

        uint256 cashback = p.useFixedPerUnit ? (amountSpent * p.fixedPerUnit) / 1e18 : (amountSpent * p.cashbackBP) / BP_DIVISOR;
        require(cashbackPool >= cashback, "TGST: insufficient cashback pool");

        cashbackPool -= cashback;
        userData[msg.sender].totalCashback += cashback;
        userData[msg.sender].nonce += 1;

        // avoid transfer-burn when paying out from contract
        super._transfer(address(this), msg.sender, cashback);
        emit CashbackClaimed(msg.sender, partnerAddr, cashback);
    }

    // -----------------------
    // MINT-BY-CONSUMPTION (partner signs)
    // -----------------------
    function _resetUserDay(address user) internal {
        uint256 day = block.timestamp / 1 days;
        if (userLastMintDay[user] < day) {
            userLastMintDay[user] = day;
            userMintedToday[user] = 0;
        }
    }

    function mintByConsumptionSigned(
        address partnerAddr,
        address user,
        uint256 consumption,
        uint256 nonce,
        uint256 timestamp,
        bytes calldata signature
    ) external nonReentrant whenNotPaused {
        require(whitelistedPartner[partnerAddr], "TGST: partner not whitelisted");
        Partner storage p = partners[partnerAddr];
        require(p.isActive, "TGST: partner inactive");
        require(consumption > 0, "TGST: zero consumption");
        require(block.timestamp <= timestamp + consumptionValiditySeconds, "TGST: signature expired");

        // strict nonce check
        require(userData[user].nonce == nonce, "TGST: invalid nonce");

        bytes32 structHash = keccak256(abi.encode(_CONSUMPTION_TYPEHASH, user, consumption, nonce, timestamp));
        bytes32 digest = _hashTypedDataV4(structHash);
        address signer = ECDSA.recover(digest, signature);
        require(signer == p.partnerAccount, "TGST: invalid partner signature");

        uint256 reward = p.useFixedPerUnit ? (consumption * p.fixedPerUnit) / 1e18 : (consumption * p.rewardBP) / BP_DIVISOR;
        require(reward > 0, "TGST: zero reward");

        // daily / global / partner caps
        uint256 day = block.timestamp / 1 days;
        if (lastMintDay < day) { mintedToday = 0; lastMintDay = day; }
        require(mintedToday + reward <= dailyMintCap, "TGST: daily mint cap exceeded");
        require(totalMintedByConsumption + reward <= globalMintCap, "TGST: global mint cap exceeded");
        require(totalSupply() + reward <= MAX_SUPPLY, "TGST: max supply exceeded");
        require(p.mintedByPartner + reward <= p.mintCap, "TGST: partner mint cap exceeded");

        // per-user daily limit
        _resetUserDay(user);
        require(userMintedToday[user] + reward <= maxPerUserDaily, "TGST: user daily cap exceeded");

        // apply state updates
        userData[user].nonce += 1;
        mintedToday += reward;
        totalMintedByConsumption += reward;
        p.mintedByPartner += reward;
        userMintedToday[user] += reward;

        // mint then burn portion
        _mint(user, reward);
        uint256 burnAmount = (reward * mintBurnBP) / BP_DIVISOR;
        if (burnAmount > 0) {
            // safer to burn from user by pulling tokens to contract first,
            // but _burn(user, burnAmount) is allowed since user just received tokens
            _burn(user, burnAmount);
            emit TokensBurned(user, burnAmount, "mint-burn");
        }

        // circuit-breaker: if daily minted exceeds cap (should not happen due to require),
        // but in case other flows increase mintedToday, auto-pause.
        if (mintedToday > dailyMintCap) {
            _pause();
            emit AutoPauseTriggered("dailyMint exceeded, auto-paused");
        }

        emit ConsumptionMint(user, partnerAddr, consumption, reward, burnAmount, reward - burnAmount);
    }

    // -----------------------
    // REDEEM SERVICE (safe pull -> burn -> distribute)
    // -----------------------
    function redeemService(address partnerAddr, string calldata serviceType, uint256 tgstAmount) external nonReentrant whenNotPaused {
        require(whitelistedPartner[partnerAddr], "TGST: partner not whitelisted");
        require(tgstAmount > 0 && balanceOf(msg.sender) >= tgstAmount, "TGST: invalid amount");

        uint256 burnAmount = (tgstAmount * redeemBurnBP) / BP_DIVISOR;
        uint256 net = tgstAmount - burnAmount;

        Partner storage p = partners[partnerAddr];
        address receiver = p.partnerAccount != address(0) ? p.partnerAccount : address(this);

        // 1) collect full amount to contract
        super._transfer(msg.sender, address(this), tgstAmount);

        // 2) burn burnAmount from contract
        if (burnAmount > 0) {
            _burn(address(this), burnAmount);
            emit TokensBurned(msg.sender, burnAmount, "redeem-burn");
        }

        // 3) transfer net to partner or keep in liquidity pool
        super._transfer(address(this), receiver, net);
        if (receiver == address(this)) {
            liquidityPool += net;
        }

        emit RedeemService(msg.sender, partnerAddr, serviceType, tgstAmount, burnAmount);
    }

    // -----------------------
    // POOL FUNDING
    // -----------------------
    function fundPool(string memory poolType, uint256 amount) external nonReentrant whenNotPaused {
        require(amount > 0 && balanceOf(msg.sender) >= amount, "TGST: zero amount or insufficient");
        bytes32 poolHash = keccak256(bytes(poolType));

        // pull tokens into contract
        super._transfer(msg.sender, address(this), amount);

        if (poolHash == keccak256(bytes("reward"))) {
            rewardPool += amount;
        } else if (poolHash == keccak256(bytes("distribution"))) {
            distributionPool += amount;
        } else if (poolHash == keccak256(bytes("cashback"))) {
            cashbackPool += amount;
        } else if (poolHash == keccak256(bytes("liquidity"))) {
            liquidityPool += amount;
        } else {
            revert("TGST: invalid pool");
        }
        emit PoolFunded(poolType, amount, msg.sender);
    }

    // -----------------------
    // PARTNER MANAGEMENT
    // -----------------------
    function addPartner(
        address partnerAddr,
        string calldata name,
        uint256 cashbackBP,
        uint256 rewardBP,
        bool useFixed,
        uint256 fixedPerUnit,
        address partnerAccount,
        uint256 mintCap
    ) external onlyRole(GOVERNOR_ROLE) {
        require(partnerAddr != address(0) && !whitelistedPartner[partnerAddr], "TGST: invalid/existing partner");
        require(cashbackBP <= BP_DIVISOR && rewardBP <= BP_DIVISOR, "TGST: invalid BP");
        partners[partnerAddr] = Partner({
            name: name,
            isActive: true,
            cashbackBP: cashbackBP,
            rewardBP: rewardBP,
            useFixedPerUnit: useFixed,
            fixedPerUnit: fixedPerUnit,
            partnerAccount: partnerAccount,
            mintCap: mintCap,
            mintedByPartner: 0
        });
        whitelistedPartner[partnerAddr] = true;
        emit PartnerAdded(partnerAddr, name);
    }

    function togglePartner(address partnerAddr) external onlyRole(GOVERNOR_ROLE) {
        require(whitelistedPartner[partnerAddr], "TGST: not whitelisted");
        partners[partnerAddr].isActive = !partners[partnerAddr].isActive;
        emit PartnerToggled(partnerAddr, partners[partnerAddr].isActive);
    }

    // -----------------------
    // DONATIONS / TIPS
    // -----------------------
    function donateTGST(uint256 amount, string calldata note) external nonReentrant whenNotPaused {
        require(amount > 0 && balanceOf(msg.sender) >= amount, "TGST: invalid amount");
        super._transfer(msg.sender, OVERRIDE_OWNER, amount);
        emit DonationTGST(msg.sender, OVERRIDE_OWNER, amount, note);
    }

    // -----------------------
    // ADMIN SETTERS
    // -----------------------
    function setFeeCollector(address newCollector) external onlyRole(GOVERNOR_ROLE) {
        require(newCollector != address(0), "TGST: zero collector");
        feeCollector = newCollector;
        feeExempt[newCollector] = true;
        emit FeeCollectorUpdated(newCollector);
    }

    function setBurns(uint256 newTransferBP, uint256 newRedeemBP, uint256 newMintBurnBP) external onlyRole(GOVERNOR_ROLE) {
        require(newTransferBP <= BP_DIVISOR && newRedeemBP <= BP_DIVISOR && newMintBurnBP <= BP_DIVISOR, "TGST: invalid BP");
        transferBurnBP = newTransferBP;
        redeemBurnBP = newRedeemBP;
        mintBurnBP = newMintBurnBP;
        emit MintBurnBPUpdated(newMintBurnBP);
    }

    function setMintCaps(uint256 newDailyCap, uint256 newGlobalCap) external onlyRole(GOVERNOR_ROLE) {
        dailyMintCap = newDailyCap;
        globalMintCap = newGlobalCap;
        emit DailyMintCapUpdated(newDailyCap);
        emit GlobalMintCapUpdated(newGlobalCap);
    }

    function setConsumptionValidity(uint256 secs) external onlyRole(GOVERNOR_ROLE) {
        require(secs > 0, "invalid");
        consumptionValiditySeconds = secs;
    }

    function setStakingParams(uint256 newDailyBP, uint256 newMaxBP) external onlyRole(GOVERNOR_ROLE) {
        require(newDailyBP <= BP_DIVISOR && newMaxBP <= BP_DIVISOR, "TGST: invalid BP");
        dailyRewardBP = newDailyBP;
        maxTotalRewardBP = newMaxBP;
        emit StakingParamsUpdated(newDailyBP, newMaxBP);
    }

    function setReferralBonus(uint256 amount) external onlyRole(GOVERNOR_ROLE) {
        referralBonus = amount;
        emit ReferralBonusUpdated(amount);
    }

    function setMaxPerUserDaily(uint256 newMax) external onlyRole(GOVERNOR_ROLE) {
        maxPerUserDaily = newMax;
    }

    // -----------------------
    // SAFETY HELPERS
    // -----------------------
    // Emergency pause/unpause
    function pause() external onlyRole(PAUSER_ROLE) { _pause(); }
    function unpause() external onlyRole(PAUSER_ROLE) { _unpause(); }

    // manual rescue for accidentally sent ERC20s (governor)
    function rescueERC20(address token, address to, uint256 amount) external onlyRole(GOVERNOR_ROLE) {
        require(token != address(this), "cannot rescue TGST");
        IERC20(token).transfer(to, amount);
    }

    // -----------------------
    // BRIDGE / MINT / BURN
    // -----------------------
    function mint(address to, uint256 amount) external onlyRole(MINTER_ROLE) {
        require(totalSupply() + amount <= MAX_SUPPLY, "TGST: max supply exceeded");
        _mint(to, amount);
    }

    function bridgeMint(address to, uint256 amount) external onlyRole(BRIDGE_ROLE) {
        require(totalSupply() + amount <= MAX_SUPPLY, "TGST: max supply exceeded");
        _mint(to, amount);
    }

    function bridgeBurnFor(address from, uint256 amount) external onlyRole(BRIDGE_ROLE) {
        require(balanceOf(from) >= amount, "TGST: insufficient balance");
        _burn(from, amount);
    }

    // -----------------------
    // OVERRIDES
    // -----------------------
    function _beforeTokenTransfer(address from, address to, uint256 amount) internal override(ERC20, ERC20Snapshot) {
        super._beforeTokenTransfer(from, to, amount);
        if (from != address(0)) require(!userData[from].blacklisted, "TGST: sender blacklisted");
        if (to != address(0)) require(!userData[to].blacklisted, "TGST: recipient blacklisted");
    }

    // -----------------------
    // VIEWS / HELPERS
    // -----------------------
    function version() external pure returns (string memory) { return _VERSION; }
    function getUserData(address u) external view returns (UserData memory) { return userData[u]; }
    function getPartner(address p) external view returns (Partner memory) { return partners[p]; }

    receive() external payable {}
}
