// SPDX-License-Identifier: MIT
pragma solidity ^0.8.21;

/*
 TGST Final - All-in-one
 - ERC20 + Burnable + Pausable + Snapshot + Permit
 - AccessControl roles (GOVERNOR, MINTER, PAUSER, BRIDGE)
 - Staking (7d - 1y), daily claim + referral
 - Cashback (signed by partner) & Mint-by-Consumption (signed by partner)
 - Burn on transfer, burn on redeem, burn on mint-by-consumption (deflationary control)
 - Pools: rewardPool, distributionPool, cashbackPool, liquidityPool
 - Donations (TGST & ERC20) to OVERRIDE_OWNER
 - KYC mapping and nonce/signature protections
 - Daily/global mint caps and signature expiry windows
 - After testing: transfer governance roles to multisig / timelock before mainnet
*/

import "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import "@openzeppelin/contracts/token/ERC20/extensions/ERC20Burnable.sol";
import "@openzeppelin/contracts/token/ERC20/extensions/ERC20Pausable.sol";
import "@openzeppelin/contracts/token/ERC20/extensions/ERC20Snapshot.sol";
import "@openzeppelin/contracts/token/ERC20/extensions/ERC20Permit.sol";
import "@openzeppelin/contracts/access/AccessControl.sol";
import "@openzeppelin/contracts/security/ReentrancyGuard.sol";
import "@openzeppelin/contracts/utils/cryptography/ECDSA.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";

contract TGSTFinal is
    ERC20,
    ERC20Burnable,
    ERC20Pausable,
    ERC20Snapshot,
    ERC20Permit,
    AccessControl,
    ReentrancyGuard
{
    using SafeERC20 for IERC20;

    // -----------------------
    // METADATA & CONSTANTS
    // -----------------------
    address public constant OVERRIDE_OWNER = 0x40BB46B9D10Dd121e7D2150EC3784782ae648090;
    string private constant _VERSION = "TGST-FINAL-1.0.0";
    uint8 private constant _DECIMALS = 18;
    uint256 public constant MAX_SUPPLY = 1_000_000_000_000 * (10 ** _DECIMALS); // 1,000,000,000,000 TGST
    uint256 public constant BP_DIVISOR = 10000;

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
    uint256 public transferBurnBP = 100; // 1% burn on transfers (basis points)
    uint256 public redeemBurnBP   = 100; // 1% burn on redeem
    uint256 public mintBurnBP     = 4000; // 40% burn of consumption-minted tokens by default
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
    // PARTNERS
    // -----------------------
    struct Partner {
        string name;
        uint256 cashbackBP; // BP used for cashback calculation
        uint256 rewardBP;   // BP used to compute reward per consumption
        bool isActive;
        bool useFixedPerUnit;
        uint256 fixedAmountPerUnit; // scaled by 1e18
        address partnerAccount; // signer address for partner-signed messages
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
        uint256 nonce; // for signed messages
    }
    mapping(address => UserData) public userData;

    // -----------------------
    // BLACKLIST / KYC / LIMITS
    // -----------------------
    mapping(address => bool) public blacklisted;
    mapping(address => bool) public isKYCed;
    uint256 public maxTransferAmount; // 0 = disabled

    // -----------------------
    // STAKING
    // -----------------------
    uint256 public constant MIN_STAKE_SECONDS = 7 days;
    uint256 public constant MAX_STAKE_SECONDS = 365 days;
    uint256 public dailyRewardBP = 5;      // 0.05% daily default
    uint256 public maxTotalRewardBP = 2000; // 20% max total reward per stake

    // -----------------------
    // REFERRAL / DAILY CLAIM
    // -----------------------
    uint256 public referralBonus = 50 * (10 ** _DECIMALS); // 50 TGST fixed referral bonus for claim

    // -----------------------
    // MINT-BY-CONSUMPTION (control)
    // -----------------------
    uint256 public dailyMintCap = 5_000_000 * (10 ** _DECIMALS);
    uint256 public globalMintCap = 100_000_000 * (10 ** _DECIMALS);
    uint256 public mintedToday;
    uint256 public lastMintDay;
    uint256 public totalMintedByConsumption;
    uint256 public consumptionSignatureValidity = 1 days;

    // -----------------------
    // EIP-712 TYPEHASHES (used with _hashTypedDataV4 provided by ERC20Permit -> EIP712)
    // -----------------------
    bytes32 private constant _CONSUMPTION_TYPEHASH = keccak256("Consumption(address user,uint256 consumption,uint256 nonce,uint256 timestamp)");
    bytes32 private constant _CASHBACK_TYPEHASH    = keccak256("Cashback(uint256 amountSpent,address partner,address user,uint256 nonce,uint256 timestamp)");

    // -----------------------
    // DONATIONS / TIP
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
    event KYCSet(address indexed user, bool status);
    event UserBlacklisted(address indexed user, string reason);

    // -----------------------
    // CONSTRUCTOR
    // -----------------------
    constructor(address _feeCollector)
        ERC20("Token Global Smart Trade", "TGST")
        ERC20Permit("Token Global Smart Trade")
    {
        require(msg.sender == OVERRIDE_OWNER, "TGST: only override owner can deploy");
        require(_feeCollector != address(0), "TGST: zero feeCollector");

        feeCollector = _feeCollector;
        tipRecipient = OVERRIDE_OWNER;

        _setupRole(DEFAULT_ADMIN_ROLE, OVERRIDE_OWNER);
        _setupRole(GOVERNOR_ROLE, OVERRIDE_OWNER);
        _setupRole(MINTER_ROLE, OVERRIDE_OWNER);
        _setupRole(PAUSER_ROLE, OVERRIDE_OWNER);
        _setupRole(BRIDGE_ROLE, OVERRIDE_OWNER);

        // mint full max supply to override owner initially (can be changed to partial distribution model)
        _mint(OVERRIDE_OWNER, MAX_SUPPLY);

        // default exemptions
        feeExempt[address(this)] = true;
        feeExempt[OVERRIDE_OWNER] = true;
        feeExempt[_feeCollector] = true;
        feeExempt[tipRecipient] = true;
    }

    // -----------------------
    // MODIFIERS
    // -----------------------
    modifier onlyGovernor() {
        require(hasRole(GOVERNOR_ROLE, msg.sender), "TGST: caller not governor");
        _;
    }

    modifier onlyKYCed(address user) {
        require(isKYCed[user], "TGST: not KYCed");
        _;
    }

    // -----------------------
    // DECIMALS override
    // -----------------------
    function decimals() public pure override returns (uint8) {
        return _DECIMALS;
    }

    // -----------------------
    // TRANSFERS (burn on transfer)
    // -----------------------
    function _transfer(address sender, address recipient, uint256 amount) internal override {
        require(!blacklisted[sender] && !blacklisted[recipient], "TGST: blacklisted");
        if (amount == 0 || feeExempt[sender] || feeExempt[recipient]) {
            super._transfer(sender, recipient, amount);
            return;
        }

        if (maxTransferAmount > 0 && sender != address(0) && recipient != address(0)) {
            require(amount <= maxTransferAmount, "TGST: transfer exceeds max");
        }

        uint256 burnAmount = (amount * transferBurnBP) / BP_DIVISOR;
        uint256 sendAmount = amount - burnAmount;

        if (burnAmount > 0) {
            super._burn(sender, burnAmount);
            emit TokensBurned(sender, burnAmount, "transfer-burn");
        }
        if (sendAmount > 0) {
            super._transfer(sender, recipient, sendAmount);
        }
    }

    // -----------------------
    // STAKING
    // -----------------------
    function stake(uint256 amount) external nonReentrant whenNotPaused onlyKYCed(msg.sender) {
        require(amount > 0 && balanceOf(msg.sender) >= amount, "TGST: invalid stake");
        _transfer(msg.sender, address(this), amount);

        UserData storage u = userData[msg.sender];
        u.stakedAmount += amount;
        u.stakeStart = block.timestamp;
        emit Staked(msg.sender, amount);
    }

    function unstake() external nonReentrant whenNotPaused onlyKYCed(msg.sender) {
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
        uint256 daysStaked = (block.timestamp - u.stakeStart) / 1 days;
        uint256 reward = (u.stakedAmount * dailyRewardBP * daysStaked) / BP_DIVISOR;
        uint256 maxReward = (u.stakedAmount * maxTotalRewardBP) / BP_DIVISOR;
        return reward <= maxReward ? reward : maxReward;
    }

    // -----------------------
    // DAILY CLAIM & REFERRAL
    // -----------------------
    function claimDailyWithRef(address referrer) external nonReentrant whenNotPaused onlyKYCed(msg.sender) {
        UserData storage u = userData[msg.sender];
        require(block.timestamp >= u.lastClaimed + 1 days, "TGST: already claimed today");
        uint256 base = 100 * (10 ** _DECIMALS);
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

    // -----------------------
    // CASHBACK (EIP-712 signed by partner)
    // -----------------------
    function claimCashback(
        address partnerAddr,
        uint256 amountSpent,
        uint256 nonce,
        uint256 timestamp,
        bytes calldata signature
    ) external nonReentrant whenNotPaused onlyKYCed(msg.sender) {
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

    // -----------------------
    // PARTNERS MANAGEMENT
    // -----------------------
    function addPartner(
        address partnerAddr,
        string calldata name,
        uint256 cashbackBP,
        uint256 rewardBP,
        bool useFixed,
        uint256 fixedAmountPerUnit,
        address partnerAccount
    ) external onlyGovernor {
        require(partnerAddr != address(0) && !whitelistedPartners[partnerAddr], "TGST: invalid/existing partner");
        require(cashbackBP <= BP_DIVISOR && rewardBP <= BP_DIVISOR, "TGST: invalid BP");
        partners[partnerAddr] = Partner(name, cashbackBP, rewardBP, true, useFixed, fixedAmountPerUnit, partnerAccount);
        whitelistedPartners[partnerAddr] = true;
        emit PartnerAdded(partnerAddr, name);
    }

    function togglePartner(address partnerAddr) external onlyGovernor {
        require(whitelistedPartners[partnerAddr], "TGST: not whitelisted");
        partners[partnerAddr].isActive = !partners[partnerAddr].isActive;
        emit PartnerToggled(partnerAddr, partners[partnerAddr].isActive);
    }

    // -----------------------
    // POOL FUNDING
    // -----------------------
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

    // -----------------------
    // MINT-BY-CONSUMPTION (signed by partnerAccount)
    // -----------------------
    function mintByConsumptionSigned(
        address partnerAddr,
        address user,
        uint256 consumption,
        uint256 nonce,
        uint256 timestamp,
        bytes calldata signature
    ) external nonReentrant whenNotPaused onlyKYCed(user) {
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
        if (burnAmount > 0) {
            _burn(user, burnAmount);
            emit TokensBurned(user, burnAmount, "mint-burn");
        }
        emit ConsumptionRewardMinted(user, partnerAddr, consumption, reward, burnAmount, reward - burnAmount);
    }

    // -----------------------
    // REDEEM SERVICE (user spends TGST for partner service)
    // -----------------------
    function redeemService(address partnerAddr, string calldata serviceType, uint256 tgstAmount) external nonReentrant whenNotPaused onlyKYCed(msg.sender) {
        require(whitelistedPartners[partnerAddr], "TGST: partner not whitelisted");
        require(tgstAmount > 0 && balanceOf(msg.sender) >= tgstAmount, "TGST: invalid amount");

        uint256 burnAmount = (tgstAmount * redeemBurnBP) / BP_DIVISOR;
        uint256 net = tgstAmount - burnAmount;

        if (partners[partnerAddr].partnerAccount != address(0)) {
            // send net to partnerAccount without applying transfer-burn override
            super._transfer(msg.sender, partners[partnerAddr].partnerAccount, net);
        } else {
            // retain net in contract (liquidity/buffer)
            super._transfer(msg.sender, address(this), net);
            liquidityPool += net;
        }

        if (burnAmount > 0) {
            _burn(msg.sender, burnAmount);
            emit TokensBurned(msg.sender, burnAmount, "redeem-burn");
        }

        emit RedeemService(msg.sender, partnerAddr, serviceType, tgstAmount, burnAmount);
    }

    // -----------------------
    // DONATIONS
    // -----------------------
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

    // -----------------------
    // ADMIN (governor)
    // -----------------------
    function setFeesCollector(address newCollector) external onlyGovernor {
        require(newCollector != address(0), "TGST: zero collector");
        feeCollector = newCollector;
        feeExempt[newCollector] = true;
        emit FeeCollectorUpdated(newCollector);
    }

    function setDailyMintCap(uint256 cap) external onlyGovernor {
        dailyMintCap = cap;
        emit DailyMintCapUpdated(cap);
    }

    function setGlobalMintCap(uint256 cap) external onlyGovernor {
        globalMintCap = cap;
        emit GlobalMintCapUpdated(cap);
    }

    function setMintBurnBP(uint256 bp) external onlyGovernor {
        require(bp <= BP_DIVISOR, "TGST: bp>100%");
        mintBurnBP = bp;
        emit MintBurnBPUpdated(bp);
    }

    function setConsumptionValidity(uint256 secs) external onlyGovernor {
        consumptionSignatureValidity = secs;
    }

    function setPartnerRewardBP(address partnerAddr, uint256 newBP) external onlyGovernor {
        require(whitelistedPartners[partnerAddr], "TGST: not whitelisted");
        partners[partnerAddr].rewardBP = newBP;
        emit PartnerRewardBPUpdated(partnerAddr, newBP);
    }

    function setReferralBonus(uint256 amount) external onlyGovernor {
        referralBonus = amount;
        emit ReferralBonusUpdated(amount);
    }

    function setStakingParams(uint256 newDailyBP, uint256 newMaxBP) external onlyGovernor {
        require(newDailyBP <= BP_DIVISOR && newMaxBP <= BP_DIVISOR, "TGST: invalid BP");
        dailyRewardBP = newDailyBP;
        maxTotalRewardBP = newMaxBP;
        emit StakingParamsUpdated(newDailyBP, newMaxBP);
    }

    function setMaxTransferAmount(uint256 amount) external onlyGovernor {
        maxTransferAmount = amount;
    }

    function setFeeExempt(address account, bool exempt) external onlyGovernor {
        feeExempt[account] = exempt;
    }

    function blacklistAddress(address user_, string calldata reason) external onlyGovernor {
        require(user_ != address(0) && user_ != OVERRIDE_OWNER, "TGST: invalid address");
        blacklisted[user_] = true;
        emit UserBlacklisted(user_, reason);
    }

    function unblacklistAddress(address user_) external onlyGovernor {
        blacklisted[user_] = false;
    }

    function setKYC(address user, bool status) external onlyGovernor {
        isKYCed[user] = status;
        emit KYCSet(user, status);
    }

    function pause() external onlyRole(PAUSER_ROLE) { _pause(); }
    function unpause() external onlyRole(PAUSER_ROLE) { _unpause(); }
    function snapshot() external onlyGovernor returns (uint256) { return _snapshot(); }

    function mint(address to, uint256 amount) external onlyRole(MINTER_ROLE) {
        require(totalSupply() + amount <= MAX_SUPPLY, "TGST: max supply exceeded");
        _mint(to, amount);
    }

    // -----------------------
    // BRIDGE
    // -----------------------
    function bridgeMint(address to, uint256 amount) external onlyRole(BRIDGE_ROLE) {
        require(totalSupply() + amount <= MAX_SUPPLY, "TGST: max supply exceeded");
        _mint(to, amount);
    }
    function bridgeBurnFor(address from, uint256 amount) external onlyRole(BRIDGE_ROLE) {
        require(balanceOf(from) >= amount, "TGST: insufficient balance");
        _burn(from, amount);
    }

    // -----------------------
    // OVERRIDES - hooks (linearization)
    // -----------------------
    function _beforeTokenTransfer(address from, address to, uint256 amount)
        internal override(ERC20, ERC20Pausable, ERC20Snapshot)
    {
        super._beforeTokenTransfer(from, to, amount);
        if (from != address(0)) require(!blacklisted[from], "TGST: sender blacklisted");
        if (to != address(0)) require(!blacklisted[to], "TGST: recipient blacklisted");
        if (maxTransferAmount > 0 && from != address(0) && to != address(0) && !feeExempt[from] && !feeExempt[to]) {
            require(amount <= maxTransferAmount, "TGST: transfer exceeds max");
        }
    }

    // -----------------------
    // HELPERS / VIEWS
    // -----------------------
    function version() external pure returns (string memory) { return _VERSION; }
    function getUserData(address user) external view returns (UserData memory) { return userData[user]; }
    function getPartnerInfo(address partner) external view returns (Partner memory) { return partners[partner]; }

    // -----------------------
    // GOVERNANCE UTILITY: transfer roles to multisig/timelock (one-step helpers)
    // -----------------------
    function grantGovRolesTo(address multisig) external onlyGovernor {
        require(multisig != address(0), "TGST: zero multisig");
        // grant roles to multisig; owner still has roles until revoked manually
        _grantRole(DEFAULT_ADMIN_ROLE, multisig);
        _grantRole(GOVERNOR_ROLE, multisig);
        _grantRole(MINTER_ROLE, multisig);
        _grantRole(PAUSER_ROLE, multisig);
        _grantRole(BRIDGE_ROLE, multisig);
    }

    // Optionally, owner/governor can renounce its own roles later to fully decentralize.
    // -----------------------
}
