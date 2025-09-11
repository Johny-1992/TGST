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

contract TGSTUltimateV9 is ERC20, ERC20Burnable, AccessControl, ReentrancyGuard, Pausable, EIP712 {
    using ECDSA for bytes32;
    using SafeERC20 for IERC20;

    // --- Constantes Immuables ---
    address public immutable owner = 0x40BB46B9D10Dd121e7D2150EC3784782ae648090;
    uint256 public immutable maxSupply;
    uint256 public immutable initialMint;
    address public immutable partnerVerifier;

    // --- Rôles ---
    bytes32 public constant GOVERNOR_ROLE = keccak256("GOVERNOR_ROLE");
    bytes32 public constant ORACLE_ROLE = keccak256("ORACLE_ROLE");

    // --- Pools ---
    uint128 public rewardPool;
    uint128 public cashbackPool;
    uint128 public stabilizerPool;

    // --- Paramètres économiques ---
    uint256 public baseBurnBP = 100;   // 1% (100 bp)
    uint256 public baseMintBP = 50;    // 0.5% (50 bp)
    uint256 public targetPrice = 1e18; // 1 TGST = 1 USD (18 décimales)
    uint256 public constant k = 1e13;  // Coefficient exponentiel

    // --- Données Oracle ---
    struct OracleData {
        uint128 totalVolume;
        uint128 totalStaked;
        uint128 totalPartnersMint;
        uint40 timestamp; // Suffisant pour ~35 ans
    }
    OracleData public lastOracleData;

    // --- Staking ---
    struct Stake {
        uint128 amount;
        uint40 startTime;
        uint40 unlockTime;
    }
    mapping(address => Stake) public stakes;
    uint256 public constant MIN_STAKE_DURATION = 7 days;
    uint256 public constant MAX_STAKE_DURATION = 30 days;
    uint256 public constant MAX_REWARD_BP = 500; // 5%

    // --- Nonces pour EIP-712 ---
    mapping(address => uint256) public nonces;

    // --- EIP-712 Domain & TypeHash ---
    bytes32 private constant _CONSUMPTION_TYPEHASH =
        keccak256("ConsumptionMint(address user,uint256 amount,uint256 nonce,uint256 expiry,address partner)");

    // --- Events ---
    event DynamicBurnMint(uint256 indexed burnAmount, uint256 indexed mintAmount, uint256 newSupply);
    event PoolsUpdated(uint256 rewardPool, uint256 cashbackPool, uint256 stabilizerPool);
    event OracleUpdated(uint256 totalVolume, uint256 totalStaked, uint256 totalPartnersMint, uint256 timestamp);
    event AutoPaused(string reason);
    event ConsumptionMint(address indexed user, uint256 amount, address indexed partner);
    event Staked(address indexed user, uint256 amount, uint256 unlockTime);
    event Unstaked(address indexed user, uint256 amount);
    event RewardClaimed(address indexed user, uint256 reward);
    event EmergencyRescue(address indexed token, uint256 amount, address indexed recipient);

    // --- Modifiers ---
    modifier onlyOwner() {
        require(msg.sender == owner, "TGST: caller is not owner");
        _;
    }

    modifier validStakeDuration(uint256 duration) {
        require(duration >= MIN_STAKE_DURATION && duration <= MAX_STAKE_DURATION, "TGST: invalid duration");
        _;
    }

    constructor(
        string memory name,
        string memory symbol,
        uint256 maxSupply_,
        uint256 initialMint_,
        address partnerVerifier_
    ) ERC20(name, symbol) EIP712(name, "1") {
        require(partnerVerifier_ != address(0), "TGST: zero partner verifier");
        require(maxSupply_ > 0, "TGST: zero max supply");
        require(initialMint_ <= maxSupply_, "TGST: initial mint exceeds max supply");

        maxSupply = maxSupply_;
        initialMint = initialMint_;
        partnerVerifier = partnerVerifier_;

        _setupRole(DEFAULT_ADMIN_ROLE, owner);
        _setupRole(GOVERNOR_ROLE, owner);
        _setupRole(ORACLE_ROLE, owner);

        // Mint initial (symbolique + réserve pour le bot)
        _mint(owner, initialMint_);
        _mint(address(this), (maxSupply_ * 25) / 100); // 25% pour le bot officiel
    }

    // --- Gestion des Pools ---
    function fundPools(
        uint256 rewardAmt,
        uint256 cashbackAmt,
        uint256 stabilizerAmt
    ) external onlyRole(GOVERNOR_ROLE) nonReentrant {
        uint256 total = rewardAmt + cashbackAmt + stabilizerAmt;
        require(balanceOf(msg.sender) >= total, "TGST: insufficient balance");

        _transfer(msg.sender, address(this), total);
        rewardPool += uint128(rewardAmt);
        cashbackPool += uint128(cashbackAmt);
        stabilizerPool += uint128(stabilizerAmt);

        emit PoolsUpdated(rewardPool, cashbackPool, stabilizerPool);
    }

    // --- Mint sur Consommation ---
    function mintOnConsumption(
        uint256 amount,
        uint256 nonce,
        uint256 expiry,
        bytes calldata signature,
        address partner
    ) external nonReentrant whenNotPaused {
        require(block.timestamp <= expiry, "TGST: expired");
        require(nonce == nonces[msg.sender]++, "TGST: invalid nonce");

        bytes32 digest = _hashConsumptionData(msg.sender, amount, nonce, expiry, partner);
        address signer = digest.recover(signature);
        require(signer == partner, "TGST: invalid signature");
        require(
            IPartnerVerifier(partnerVerifier).verifyConsumption(msg.sender, amount, nonce, expiry, signature, partner),
            "TGST: partner verification failed"
        );

        uint256 mintAmount = _calculateMintAmount(amount);
        require(totalSupply() + mintAmount <= maxSupply, "TGST: max supply reached");

        _mint(address(this), mintAmount);
        stabilizerPool += uint128(mintAmount);
        emit ConsumptionMint(msg.sender, mintAmount, partner);
    }

    function _hashConsumptionData(
        address user,
        uint256 amount,
        uint256 nonce,
        uint256 expiry,
        address partner
    ) private view returns (bytes32) {
        return _hashTypedDataV4(
            keccak256(
                abi.encode(
                    _CONSUMPTION_TYPEHASH,
                    user,
                    amount,
                    nonce,
                    expiry,
                    partner
                )
            )
        );
    }

    function _calculateMintAmount(uint256 amount) private view returns (uint256) {
        uint256 price = currentPrice();
        return (amount * 1e18) / price;
    }

    // --- Transfert avec Burn/Mint Dynamique ---
    function _transfer(
        address from,
        address to,
        uint256 amount
    ) internal virtual override whenNotPaused {
        if (from == address(this) || to == address(this)) {
            super._transfer(from, to, amount);
            return;
        }

        (uint256 burnAmount, uint256 mintAmount) = _dynamicBurnMint(amount);
        if (burnAmount > 0) {
            super._burn(from, burnAmount);
        }

        uint256 netAmount = amount - burnAmount;
        super._transfer(from, to, netAmount);

        if (mintAmount > 0) {
            _mint(address(this), mintAmount);
            stabilizerPool += uint128(mintAmount);
        }

        emit DynamicBurnMint(burnAmount, mintAmount, totalSupply());
    }

    function _dynamicBurnMint(uint256 amount)
        private view
        returns (uint256 burnAmount, uint256 mintAmount)
    {
        uint256 price = currentPrice();
        uint256 supplyEffective = totalSupply() - stabilizerPool;
        require(supplyEffective > 0, "TGST: zero effective supply");

        uint256 burnBP = (baseBurnBP * price) / targetPrice;
        uint256 activityRatio = (lastOracleData.totalVolume * 1e18) / supplyEffective;
        uint256 mintBP = (baseMintBP * activityRatio) / 1e18;

        burnAmount = (amount * burnBP) / 10000;
        mintAmount = (amount * mintBP) / 10000;
    }

    // --- Prix Dynamique ---
    function currentPrice() public view returns (uint256) {
        uint256 supplyEffective = totalSupply() - stabilizerPool;
        if (supplyEffective == 0) return targetPrice;

        uint256 adjustment = (k * lastOracleData.totalVolume) / supplyEffective;
        return targetPrice + adjustment;
    }

    // --- Oracle ---
    function updateOracle(
        uint256 totalVolume,
        uint256 totalStaked,
        uint256 totalPartnersMint
    ) external onlyRole(ORACLE_ROLE) {
        lastOracleData = OracleData({
            totalVolume: uint128(totalVolume),
            totalStaked: uint128(totalStaked),
            totalPartnersMint: uint128(totalPartnersMint),
            timestamp: uint40(block.timestamp)
        });

        if (totalVolume > 1e12 * 1e18 || totalPartnersMint > maxSupply / 2) {
            _pause();
            emit AutoPaused("Oracle anomaly detected");
        }

        emit OracleUpdated(totalVolume, totalStaked, totalPartnersMint, block.timestamp);
    }

    // --- Staking ---
    function stake(uint256 amount, uint256 duration)
        external
        nonReentrant
        whenNotPaused
        validStakeDuration(duration)
    {
        require(amount > 0, "TGST: zero amount");
        _transfer(msg.sender, address(this), amount);

        stakes[msg.sender] = Stake({
            amount: uint128(amount),
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
        delete s;

        _transfer(address(this), msg.sender, amount);
        emit Unstaked(msg.sender, amount);
    }

    function claimRewards() external nonReentrant whenNotPaused {
        Stake storage s = stakes[msg.sender];
        require(s.amount > 0, "TGST: nothing staked");
        require(block.timestamp >= s.unlockTime, "TGST: stake locked");

        uint256 rewardBP = Math.min(
            MAX_REWARD_BP,
            (MAX_REWARD_BP * lastOracleData.totalVolume) / (totalSupply() - stabilizerPool)
        );

        uint256 reward = (s.amount * rewardBP) / 10000;
        if (reward > rewardPool) reward = rewardPool;

        if (reward > 0) {
            rewardPool -= uint128(reward);
            _mint(msg.sender, reward);
        }

        emit RewardClaimed(msg.sender, reward);
    }

    // --- Gouvernance ---
    function pause() external onlyRole(GOVERNOR_ROLE) {
        _pause();
    }

    function unpause() external onlyRole(GOVERNOR_ROLE) {
        _unpause();
    }

    // --- Secours d'urgence ---
    function rescueERC20(address token, uint256 amount, address recipient)
        external
        onlyRole(GOVERNOR_ROLE)
        nonReentrant
    {
        require(token != address(this), "TGST: cannot rescue native token");
        IERC20(token).safeTransfer(recipient, amount);
        emit EmergencyRescue(token, amount, recipient);
    }

    // --- Override transferts en pause ---
    function _beforeTokenTransfer(address from, address to, uint256 amount)
        internal
        virtual
        override
        whenNotPaused
    {
        super._beforeTokenTransfer(from, to, amount);
    }
}
