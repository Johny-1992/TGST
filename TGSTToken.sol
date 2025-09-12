// SPDX-License-Identifier: MIT
pragma solidity ^0.8.21;

import "@openzeppelin/contracts@4.9.3/token/ERC20/ERC20.sol";
import "@openzeppelin/contracts@4.9.3/token/ERC20/extensions/ERC20Burnable.sol";
import "@openzeppelin/contracts@4.9.3/access/AccessControl.sol";
import "@openzeppelin/contracts@4.9.3/security/ReentrancyGuard.sol";
import "@openzeppelin/contracts@4.9.3/security/Pausable.sol";
import "@openzeppelin/contracts@4.9.3/token/ERC20/utils/SafeERC20.sol";
import "@openzeppelin/contracts@4.9.3/utils/cryptography/ECDSA.sol";
import "@openzeppelin/contracts@4.9.3/utils/cryptography/draft-EIP712.sol";
import "@openzeppelin/contracts@4.9.3/utils/math/Math.sol";

interface IPartnerVerifier {
    function verifyConsumption(
        address user,
        uint256 amount,
        uint256 nonce,
        uint256 expiry,
        bytes calldata signature,
        address partner
    ) external view returns (bool);
}

interface IZKVerifier {
    function verifyProof(bytes calldata proof, bytes calldata publicInputs) external view returns (bool);
}

interface ILayerZeroEndpoint {
    function estimateFees(
        uint16 _dstChainId,
        address _userApplication,
        bytes calldata _payload,
        bool _payInZRO,
        bytes calldata _adapterParams
    ) external view returns (uint256 nativeFee, uint256 zroFee);

    function send(
        uint16 _dstChainId,
        bytes calldata _payload,
        address payable _refundAddress,
        address _zroPaymentAddress,
        bytes calldata _adapterParams
    ) external payable;
}

contract TGSTUltimateV10 is ERC20, ERC20Burnable, AccessControl, ReentrancyGuard, Pausable, EIP712 {
    using ECDSA for bytes32;
    using SafeERC20 for IERC20;
    using Math for uint256;

    // --- Owner wallet
    address public immutable owner;

    // --- Supply params
    uint256 public immutable maxSupply;
    uint256 public immutable initialDeployable;
    uint256 public immutable botDistribution;

    // --- Roles
    bytes32 public constant GOVERNOR_ROLE = keccak256("GOVERNOR_ROLE");
    bytes32 public constant ORACLE_ROLE = keccak256("ORACLE_ROLE");

    // --- Pools
    uint128 public rewardPool;
    uint128 public cashbackPool;
    uint128 public stabilizerPool;

    // --- Economics & price
    uint256 public targetPrice = 1e14; // 0.0001 USDT par TGST par défaut
    uint256 public baseBurnBP = 100;   // 1%
    uint256 public baseMintBP = 50;    // 0.5%
    uint256 public constant k = 1e13;

    // --- Oracle data
    struct OracleData {
        uint128 totalVolume;
        uint128 totalStaked;
        uint128 totalPartnersMint;
        uint40 timestamp;
    }
    OracleData public lastOracleData;

    // --- Staking data
    struct Stake {
        uint128 amount;
        uint40 startTime;
        uint40 unlockTime;
    }
    mapping(address => Stake) public stakes;

    uint256 public constant MIN_STAKE_DURATION = 7 days;
    uint256 public constant MAX_STAKE_DURATION = 30 days;
    uint256 public constant MAX_REWARD_BP = 500;

    // --- Nonces pour EIP-712
    mapping(address => uint256) public nonces;

    // --- Partner verifier & optional modules
    address public immutable partnerVerifier;
    IZKVerifier public zkVerifier;
    ILayerZeroEndpoint public lzEndpoint;
    uint16 public lzChainId;

    // --- Partner daily mint tracking
    mapping(address => uint256) public partnerDailyMint;
    mapping(address => uint256) public partnerLastDay;
    uint256 public dailyPartnerCap;

    // --- Oracle anomaly detection
    uint8 public consecutiveAnomalies;
    uint8 public constant ANOMALY_THRESHOLD = 2;

    // --- Temp storage for hooks
    mapping(address => uint256) private _tempTransferAmounts;

    // --- Events
    event DynamicBurnMint(uint256 burnAmount, uint256 mintAmount, uint256 newSupply);
    event PoolsUpdated(uint256 rewardPool, uint256 cashbackPool, uint256 stabilizerPool);
    event OracleUpdated(uint256 totalVolume, uint256 totalStaked, uint256 totalPartnersMint, uint256 timestamp);
    event AutoPaused(string reason);
    event ConsumptionMint(address indexed user, uint256 amount, address indexed partner);
    event Staked(address indexed user, uint256 amount, uint256 unlockTime);
    event Unstaked(address indexed user, uint256 amount);
    event RewardClaimed(address indexed user, uint256 reward);
    event EmergencyRescue(address indexed token, uint256 amount, address indexed recipient);
    event CentralControlRenounced(address indexed previousOwner);

    bytes32 private constant _CONSUMPTION_TYPEHASH =
        keccak256("ConsumptionMint(address user,uint256 amount,uint256 nonce,uint256 expiry,address partner)");

    constructor(
        string memory name,
        string memory symbol,
        uint256 maxSupply_,
        address partnerVerifier_
    ) ERC20(name, symbol) EIP712(name, "1") {
        require(partnerVerifier_ != address(0), "TGST: zero partner verifier");
        require(maxSupply_ > 0, "TGST: zero max supply");

        owner = msg.sender;
        maxSupply = maxSupply_;
        partnerVerifier = partnerVerifier_;

        initialDeployable = (maxSupply_ * 10) / 100;
        botDistribution = (initialDeployable * 25) / 100;
        dailyPartnerCap = (botDistribution * 10) / 100;

        _grantRole(DEFAULT_ADMIN_ROLE, owner);
        _grantRole(GOVERNOR_ROLE, owner);
        _grantRole(ORACLE_ROLE, owner);

        uint256 ownerInitial = initialDeployable - botDistribution;
        _mint(owner, ownerInitial);
        _mint(address(this), botDistribution);
    }

    // -------------------------
    // Transfer overrides
    // -------------------------
    function transfer(address to, uint256 amount) public override whenNotPaused returns (bool) {
        return super.transfer(to, amount);
    }

    function transferFrom(address from, address to, uint256 amount) public override whenNotPaused returns (bool) {
        return super.transferFrom(from, to, amount);
    }

    // -------------------------
    // Hooks
    // -------------------------
    function _beforeTokenTransfer(address from, address to, uint256 amount) internal override {
        if (from != address(this) && to != address(this)) {
            (uint256 burnAmount, ) = _dynamicBurnMint(amount);
            if (burnAmount > 0) {
                _burn(from, burnAmount);
                _tempTransferAmounts[msg.sender] = amount - burnAmount;
            }
        }
    }

    function _afterTokenTransfer(address from, address to, uint256 amount) internal override {
        if (from != address(this) && to != address(this)) {
            uint256 actualAmount = _tempTransferAmounts[msg.sender] > 0 ? _tempTransferAmounts[msg.sender] : amount;
            (, uint256 mintAmount) = _dynamicBurnMint(actualAmount);

            if (mintAmount > 0) {
                require(totalSupply() + mintAmount <= maxSupply, "TGST: max supply reached");
                _mint(to, mintAmount);
                stabilizerPool += uint128(mintAmount);
                emit DynamicBurnMint(actualAmount - actualAmount, mintAmount, totalSupply());
            }
            delete _tempTransferAmounts[msg.sender];
        }
    }

    // -------------------------
    // Dynamic burn/mint calculation
    // -------------------------
    function _dynamicBurnMint(uint256 amount) private view returns (uint256 burnAmount, uint256 mintAmount) {
        uint256 price = currentPrice();
        uint256 supplyEffective = totalSupply() - stabilizerPool;
        require(supplyEffective > 0, "TGST: zero effective supply");

        uint256 burnBP = (baseBurnBP * price) / targetPrice;
        uint256 activityRatio = (uint256(lastOracleData.totalVolume) * 1e18) / supplyEffective;
        uint256 mintBP = (baseMintBP * activityRatio) / 1e18;

        burnAmount = (amount * burnBP) / 10000;
        mintAmount = (amount * mintBP) / 10000;
    }

    // -------------------------
    // Price calculation
    // -------------------------
    function currentPrice() public view returns (uint256) {
        uint256 supplyEffective = totalSupply() - stabilizerPool;
        if (supplyEffective == 0) return targetPrice;
        uint256 adjustment = (k * uint256(lastOracleData.totalVolume)) / supplyEffective;
        return targetPrice + adjustment;
    }

    // -------------------------
    // Oracle update
    // -------------------------
    function updateOracle(uint128 totalVolume, uint128 totalStaked, uint128 totalPartnersMint) external onlyRole(ORACLE_ROLE) {
        require(totalStaked <= totalSupply(), "TGST: invalid totalStaked");

        lastOracleData = OracleData({
            totalVolume: totalVolume,
            totalStaked: totalStaked,
            totalPartnersMint: totalPartnersMint,
            timestamp: uint40(block.timestamp)
        });

        bool anomalous = (totalVolume > 1e12 * 1e18 || totalPartnersMint > maxSupply / 2);
        if (anomalous) {
            consecutiveAnomalies += 1;
        } else {
            consecutiveAnomalies = 0;
        }

        if (consecutiveAnomalies >= ANOMALY_THRESHOLD) {
            _pause();
            emit AutoPaused("Oracle anomaly detected (consecutive)");
        }

        emit OracleUpdated(totalVolume, totalStaked, totalPartnersMint, block.timestamp);
    }

    // -------------------------
    // Partner consumption mint (EIP-712)
    // -------------------------
    function mintOnConsumption(uint256 amount, uint256 nonce, uint256 expiry, bytes calldata signature, address partner) external nonReentrant whenNotPaused {
        require(block.timestamp <= expiry, "TGST: expired");
        require(nonce == nonces[msg.sender], "TGST: invalid nonce");

        bytes32 digest = _hashConsumptionData(msg.sender, amount, nonce, expiry, partner);
        address signer = digest.recover(signature);
        require(signer == partner, "TGST: invalid signature");

        require(
            IPartnerVerifier(partnerVerifier).verifyConsumption(msg.sender, amount, nonce, expiry, signature, partner),
            "TGST: partner verification failed"
        );

        uint256 mintAmount = _calculateMintAmount(amount);
        require(totalSupply() + mintAmount <= maxSupply, "TGST: max supply reached");

        uint256 day = block.timestamp / 1 days;
        if (partnerLastDay[partner] < day) {
            partnerDailyMint[partner] = 0;
            partnerLastDay[partner] = day;
        }
        require(partnerDailyMint[partner] + mintAmount <= dailyPartnerCap, "TGST: partner daily cap reached");
        partnerDailyMint[partner] += mintAmount;

        _mint(address(this), mintAmount);
        stabilizerPool += uint128(mintAmount);

        nonces[msg.sender] += 1;

        emit ConsumptionMint(msg.sender, mintAmount, partner);
    }

    function _hashConsumptionData(address user, uint256 amount, uint256 nonce, uint256 expiry, address partner) private view returns (bytes32) {
        return _hashTypedDataV4(keccak256(abi.encode(
            _CONSUMPTION_TYPEHASH,
            user,
            amount,
            nonce,
            expiry,
            partner
        )));
    }

    function _calculateMintAmount(uint256 amountInUSDT) private view returns (uint256) {
        uint256 price = currentPrice();
        return (amountInUSDT * 1e18) / price;
    }

    // -------------------------
    // Fund pools
    // -------------------------
    function fundPools(uint256 rewardAmt, uint256 cashbackAmt, uint256 stabilizerAmt) external onlyRole(GOVERNOR_ROLE) nonReentrant {
        uint256 total = rewardAmt + cashbackAmt + stabilizerAmt;
        require(balanceOf(msg.sender) >= total, "TGST: insufficient balance");

        _transfer(msg.sender, address(this), total);

        rewardPool += uint128(rewardAmt);
        cashbackPool += uint128(cashbackAmt);
        stabilizerPool += uint128(stabilizerAmt);

        emit PoolsUpdated(rewardPool, cashbackPool, stabilizerPool);
    }

    // -------------------------
    // Staking
    // -------------------------
    function stake(uint128 amount, uint40 duration) external nonReentrant whenNotPaused {
        require(duration >= MIN_STAKE_DURATION && duration <= MAX_STAKE_DURATION, "TGST: invalid duration");
        require(amount > 0, "TGST: zero amount");
        require(balanceOf(msg.sender) >= amount, "TGST: insufficient balance");

        _transfer(msg.sender, address(this), amount);

        stakes[msg.sender] = Stake({
            amount: amount,
            startTime: uint40(block.timestamp),
            unlockTime: uint40(block.timestamp + duration)
        });

        emit Staked(msg.sender, amount, block.timestamp + duration);
    }

    function unstake() external nonReentrant whenNotPaused {
        Stake storage s = stakes[msg.sender];
        require(s.amount > 0, "TGST: nothing staked");
        require(block.timestamp >= s.unlockTime, "TGST: stake locked");

        uint256 amount = s.amount;
        delete stakes[msg.sender];

        _transfer(address(this), msg.sender, amount);
        emit Unstaked(msg.sender, amount);
    }

    function claimRewards() external nonReentrant whenNotPaused {
        Stake storage s = stakes[msg.sender];
        require(s.amount > 0, "TGST: nothing staked");
        require(block.timestamp >= s.unlockTime, "TGST: stake locked");

        uint256 supplyEffective = totalSupply() - stabilizerPool;
        uint256 rewardBP = Math.min(MAX_REWARD_BP, (MAX_REWARD_BP * uint256(lastOracleData.totalVolume)) / supplyEffective);

        uint256 reward = (uint256(s.amount) * rewardBP) / 10000;
        if (reward > rewardPool) reward = rewardPool;

        if (reward > 0) {
            rewardPool -= uint128(reward);
            _mint(msg.sender, reward);
            emit RewardClaimed(msg.sender, reward);
        }
    }

    // -------------------------
    // Governance setters
    // -------------------------
    function setZKVerifier(address newVerifier) external onlyRole(GOVERNOR_ROLE) { zkVerifier = IZKVerifier(newVerifier); }
    function setLayerZeroEndpoint(address endpoint, uint16 chainId) external onlyRole(GOVERNOR_ROLE) { lzEndpoint = ILayerZeroEndpoint(endpoint); lzChainId = chainId; }
    function setDailyPartnerCap(uint256 newCap) external onlyRole(GOVERNOR_ROLE) { dailyPartnerCap = newCap; }

    // -------------------------
    // Rescue ERC20
    // -------------------------
    function rescueERC20(address token, uint256 amount, address recipient) external onlyRole(GOVERNOR_ROLE) nonReentrant {
        require(token != address(this), "TGST: cannot rescue native token");
        IERC20(token).safeTransfer(recipient, amount);
        emit EmergencyRescue(token, amount, recipient);
    }

    // -------------------------
    // Renounce central control
    // -------------------------
    function renounceCentralControl() external {
        require(msg.sender == owner, "TGST: only owner can renounce");
        _revokeRole(DEFAULT_ADMIN_ROLE, owner);
        emit CentralControlRenounced(owner);
    }

    // -------------------------
    // Pause / unpause
    // -------------------------
    function pause() external onlyRole(GOVERNOR_ROLE) { _pause(); }
    function unpause() external onlyRole(GOVERNOR_ROLE) { _unpause(); consecutiveAnomalies = 0; }
}
