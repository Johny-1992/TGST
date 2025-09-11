// SPDX-License-Identifier: MIT
pragma solidity ^0.8.21;

import "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import "@openzeppelin/contracts/token/ERC20/extensions/ERC20Burnable.sol";
import "@openzeppelin/contracts/access/AccessControl.sol";
import "@openzeppelin/contracts/security/ReentrancyGuard.sol";
import "@openzeppelin/contracts/security/Pausable.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "@openzeppelin/contracts/utils/cryptography/ECDSA.sol";
import "@openzeppelin/contracts/utils/cryptography/draft-EIP712.sol";
import "@openzeppelin/contracts/utils/math/Math.sol";

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

contract TGSTUltimateV10 is
    ERC20,
    ERC20Burnable,
    AccessControl,
    ReentrancyGuard,
    Pausable,
    EIP712
{
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

        owner = msg.sender; // <-- Initialisation correcte du wallet owner

        maxSupply = maxSupply_;
        partnerVerifier = partnerVerifier_;

        // initial deployable = 10% du maxSupply
        initialDeployable = (maxSupply_ * 10) / 100;
        // botDistribution = 25% de initialDeployable
        botDistribution = (initialDeployable * 25) / 100;
        // daily partner cap = 10% de botDistribution
        dailyPartnerCap = (botDistribution * 10) / 100;

        // Attribution des rôles
        _grantRole(DEFAULT_ADMIN_ROLE, owner);
        _grantRole(GOVERNOR_ROLE, owner);
        _grantRole(ORACLE_ROLE, owner);

        // Mint initial
        uint256 ownerInitial = initialDeployable - botDistribution;
        _mint(owner, ownerInitial);
        _mint(address(this), botDistribution);
    }

    // --- Fonctions principales ---
    function _today() internal view returns (uint256) {
        return block.timestamp / 1 days;
    }

    function fundPools(uint256 rewardAmt, uint256 cashbackAmt, uint256 stabilizerAmt)
        external onlyRole(GOVERNOR_ROLE) nonReentrant
    {
        uint256 total = rewardAmt + cashbackAmt + stabilizerAmt;
        require(balanceOf(msg.sender) >= total, "TGST: insufficient balance");

        _transfer(msg.sender, address(this), total);

        rewardPool += uint128(rewardAmt);
        cashbackPool += uint128(cashbackAmt);
        stabilizerPool += uint128(stabilizerAmt);

        emit PoolsUpdated(rewardPool, cashbackPool, stabilizerPool);
    }

    function mintOnConsumption(
        uint256 amount,
        uint256 nonce,
        uint256 expiry,
        bytes calldata signature,
        address partner
    ) external nonReentrant whenNotPaused {
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

        uint256 day = _today();
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

    function _hashConsumptionData(
        address user,
        uint256 amount,
        uint256 nonce,
        uint256 expiry,
        address partner
    ) private view returns (bytes32) {
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

    function _transfer(address from, address to, uint256 amount) internal override whenNotPaused {
        if (from == address(this) || to == address(this)) {
            super._transfer(from, to, amount);
            return;
        }

        (uint256 burnAmount, uint256 mintAmount) = _dynamicBurnMint(amount);

        if (burnAmount > 0) _burn(from, burnAmount);

        uint256 netAmount = amount - burnAmount;
        super._transfer(from, to, netAmount);

        if (mintAmount > 0) {
            require(mintAmount <= type
