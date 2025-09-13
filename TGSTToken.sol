// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

/*
  TGST Laptop final - Pure TGST flow (USDT only for reference in "amountInUSDT" signed vouchers)
  - Name: Token Global Smart Trade (TGST)
  - Symbol: TGST
  - Owner: 0x40BB46B9D10Dd121e7D2150EC3784782ae648090 (pre-set)
  - Max supply: 1_000_000_000_000 * 1e18 (1 trillion)
  - Initial deployable: 10% of max supply; bot reserve = 25% of that; owner gets rest
  - Consumption mint is partner-signed (EIP-712) — no USDT transfer required
  - Dynamic burn on transfers, stabilizer pool, staking, airdrop, anti-bot, pause, reentrancy guard
*/

import "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import "@openzeppelin/contracts/token/ERC20/extensions/ERC20Pausable.sol";
import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/security/ReentrancyGuard.sol";

contract TGSTLaptopFinal is ERC20, ERC20Pausable, Ownable, ReentrancyGuard {
    // ---------- Constants ----------
    uint256 public constant MAX_SUPPLY = 1_000_000_000_000 * 1e18;
    uint256 public constant BP_DENOM = 10000;
    uint256 public constant MIN_STAKE = 7 days;
    uint256 public constant MAX_STAKE = 30 days;
    uint16  public constant MAX_REWARD_BP = 500; // 5%

    // ---------- Tokenomics initial ----------
    uint256 public immutable initialDeployable; // 10% of MAX_SUPPLY
    uint256 public immutable botDistribution;   // 25% of initialDeployable

    // ---------- Airdrop / Bot ----------
    uint256 public constant AIRDROP_POOL = 25_000_000_000 * 1e18; // optional reserve (kept compat)
    uint256 public airdropAmount = AIRDROP_POOL / 1000; // claim size
    uint256 public maxAirdropClaims = 1000;
    uint256 public airdropClaims;
    mapping(address => bool) public airdropClaimed;

    // ---------- Staking ----------
    struct StakeInfo { uint128 amount; uint40 start; uint40 duration; }
    mapping(address => StakeInfo) public stakes;

    // ---------- Burn & stabilizer ----------
    uint16 public baseBurnBP = 100; // 1% default
    uint16 public maxBurnBP  = 1000; // 10% cap
    address public stabilizerPool;

    // ---------- Anti-bot ----------
    bool   public antiBotActive = true;
    uint32 public cooldown = 30;    // seconds
    uint16 public maxTxBP = 50;     // 0.5% of max supply
    uint16 public maxWalletBP = 200;// 2% of max supply
    mapping(address => uint256) public lastTxAt;

    // ---------- Consumption mint (EIP-712) ----------
    address public partnerVerifier; // address that signs vouchers (can be partner or aggregator)
    bytes32 private constant _CONSUME_TYPEHASH = keccak256("Consume(address user,uint256 amountInUSDT,uint256 nonce,uint256 expiry,address partner)");
    mapping(address => uint256) public nonces;

    // ---------- Price settings ----------
    // initial price: 1 TGST = 0.00001 USDT -> targetPrice = 1e13 (USDT scaled 1e18)
    uint256 public targetPrice = 1e13;
    uint256 public constant K = 1e13; // coefficient for price adjustment (oracle)

    // Optional oracle (external) to provide totalVolume/totalStaked if desired
    interface IOracle { function totalVolume() external view returns (uint256); function totalStaked() external view returns (uint256); }
    IOracle public oracle;

    // ---------- Events ----------
    event BotAirdrop(address indexed user, uint256 amount);
    event Staked(address indexed user, uint256 amount, uint256 unlock);
    event Unstaked(address indexed user, uint256 amount, uint256 reward);
    event ConsumptionMinted(address indexed user, uint256 amountInUSDT, uint256 minted);
    event Burned(address indexed from, uint256 amount, uint16 bp);
    event AntiBotToggled(bool active);
    event BurnParamsUpdated(uint16 baseBP, uint16 maxBP);
    event StabilizerPoolUpdated(address pool);
    event PartnerVerifierSet(address pv);
    event OracleSet(address oracleAddr);

    // ---------- Constructor ----------
    constructor(address initialOwner, address partnerVerifier_) ERC20("Token Global Smart Trade", "TGST") Ownable(initialOwner) {
        require(initialOwner != address(0), "zero owner");
        require(MAX_SUPPLY > 0, "zero supply");

        // tokenomics
        initialDeployable = MAX_SUPPLY / 10; // 10%
        botDistribution = (initialDeployable * 25) / 100; // 25% of initialDeployable

        // mint ownerInitial and bot reserve to contract
        uint256 ownerInitial = initialDeployable - botDistribution;
        if (ownerInitial > 0) _mint(initialOwner, ownerInitial);
        if (botDistribution > 0) {
            _mint(address(this), botDistribution);
            // keep botDistribution in contract for airdrops/stabilizer
        }

        // set partner verifier
        partnerVerifier = partnerVerifier_;
        emit PartnerVerifierSet(partnerVerifier_);
    }

    // ---------- Helpers ----------
    function _today() internal view returns (uint256) { return block.timestamp / 1 days; }

    // ---------- Airdrop ----------
    function claimAirdrop() external nonReentrant whenNotPaused {
        require(!airdropClaimed[msg.sender], "claimed");
        require(airdropClaims < maxAirdropClaims, "finished");
        uint256 amt = airdropAmount;
        require(balanceOf(address(this)) >= amt, "no pool");
        airdropClaimed[msg.sender] = true;
        airdropClaims += 1;
        _transfer(address(this), msg.sender, amt);
        emit BotAirdrop(msg.sender, amt);
    }

    // ---------- Staking ----------
    function stake(uint256 amount, uint256 durationSeconds) external nonReentrant whenNotPaused {
        require(amount > 0, "zero");
        require(durationSeconds >= MIN_STAKE && durationSeconds <= MAX_STAKE, "dur invalid");
        require(balanceOf(msg.sender) >= amount, "no bal");
        _transfer(msg.sender, address(this), amount);
        stakes[msg.sender] = StakeInfo({ amount: uint128(amount), start: uint40(block.timestamp), duration: uint40(durationSeconds) });
        emit Staked(msg.sender, amount, block.timestamp + durationSeconds);
    }

    function unstake() external nonReentrant whenNotPaused {
        StakeInfo memory s = stakes[msg.sender];
        require(s.amount > 0, "none");
        require(block.timestamp >= s.start + s.duration, "locked");
        uint256 rewardBP = MAX_REWARD_BP;
        uint256 reward = (uint256(s.amount) * rewardBP) / BP_DENOM;
        delete stakes[msg.sender];
        _transfer(address(this), msg.sender, uint256(s.amount) + reward);
        emit Unstaked(msg.sender, s.amount, reward);
    }

    // ---------- Consumption mint (partner-signed voucher) ----------
    // amountInUSDT is the USDT-equivalent value (scale 1e18). No USDT transfer required.
    function consumptionMint(
        uint256 amountInUSDT,
        uint256 nonce,
        uint256 expiry,
        bytes calldata signature,
        address partner
    ) external nonReentrant whenNotPaused {
        require(block.timestamp <= expiry, "expired");
        require(nonce == nonces[msg.sender], "bad nonce");
        require(partner != address(0), "zero partner");

        bytes32 structHash = keccak256(abi.encode(_CONSUME_TYPEHASH, msg.sender, amountInUSDT, nonce, expiry, partner));
        bytes32 digest = _hashTypedDataV4(structHash);
        address signer = _recover(digest, signature);
        require(signer == partnerVerifier || signer == partner, "invalid signer");

        // compute mint quantity from price (USDT per TGST scaled 1e18)
        uint256 price = currentPrice();
        require(price > 0, "price zero");
        uint256 mintAmount = (amountInUSDT * 1e18) / price; // mintAmount in TGST (18 decimals)
        require(totalSupply() + mintAmount <= MAX_SUPPLY, "max supply");

        nonces[msg.sender] += 1;
        _mint(msg.sender, mintAmount);
        emit ConsumptionMinted(msg.sender, amountInUSDT, mintAmount);
    }

    // EIP-712 domain helpers (uses ERC20 name)
    function _hashTypedDataV4(bytes32 structHash) internal view returns (bytes32) {
        // domain separator per EIP-712 v4 simplified
        return keccak256(abi.encodePacked("\x19\x01", _domainSeparatorV4(), structHash));
    }
    function _domainSeparatorV4() public view returns (bytes32) {
        // Using simple domain: name + version "1"
        return keccak256(abi.encode(keccak256("EIP712Domain(string name,string version)"), keccak256(bytes(name())), keccak256(bytes("1"))));
    }
    function _recover(bytes32 digest, bytes calldata sig) internal pure returns (address) {
        // simple ecrecover splitter
        require(sig.length == 65, "bad sig");
        bytes32 r; bytes32 s; uint8 v;
        assembly {
            r := calldataload(sig.offset)
            s := calldataload(add(sig.offset,32))
            v := byte(0, calldataload(add(sig.offset,64)))
        }
        if (v < 27) v += 27;
        return ecrecover(digest, v, r, s);
    }

    // ---------- Price (TGST per USDT scaled 1e18) ----------
    function currentPrice() public view returns (uint256) {
        // base targetPrice may be adjusted by oracle volume if available
        uint256 supplyEff = totalSupply();
        if (supplyEff == 0) return targetPrice;
        if (address(oracle) == address(0)) return targetPrice;
        uint256 vol = oracle.totalVolume();
        uint256 adj = (K * vol) / (supplyEff == 0 ? 1 : supplyEff);
        return targetPrice + adj;
    }

    function setOracle(address oracleAddr) external onlyOwner { oracle = IOracle(oracleAddr); emit OracleSet(oracleAddr); }
    function setPartnerVerifier(address pv) external onlyOwner { partnerVerifier = pv; emit PartnerVerifierSet(pv); }

    // ---------- Core transfer hook: anti-bot + burn + stabilizer ----------
    // Override _update (OZ v5 pattern) to apply pre-transfer logic
    function _update(address from, address to, uint256 value) internal override(ERC20, ERC20Pausable) {
        // skip for mint/burn or owner-internal ops
        if (from != address(0) && to != address(0) && from != owner() && to != owner()) {
            // anti-bot
            if (antiBotActive) {
                uint256 last = lastTxAt[from];
                if (last != 0) require(block.timestamp >= last + cooldown, "cooldown");
                uint256 maxTx = (MAX_SUPPLY * maxTxBP) / BP_DENOM;
                if (maxTx > 0) require(value <= maxTx, "tx too large");
                uint256 maxHold = (MAX_SUPPLY * maxWalletBP) / BP_DENOM;
                if (maxHold > 0) require(balanceOf(to) + value <= maxHold, "recipient limit");
                lastTxAt[from] = block.timestamp;
            }

            // dynamic burn scaling with price (simple inverse relation)
            uint16 burnBP = baseBurnBP;
            uint256 price = currentPrice();
            if (price > 0) {
                uint256 scaled = (uint256(baseBurnBP) * 1e18) / price; // higher price -> lower burn; lower price -> higher burn
                if (scaled > maxBurnBP) scaled = maxBurnBP;
                if (scaled > type(uint16).max) scaled = type(uint16).max;
                burnBP = uint16(scaled);
            }

            uint256 burnAmount = (value * burnBP) / BP_DENOM;
            if (burnAmount > 0) {
                uint256 half = burnAmount / 2;
                uint256 toBurn = burnAmount - half;
                if (toBurn > 0) {
                    super._update(from, address(0), toBurn); // burn
                }
                if (half > 0) {
                    if (stabilizerPool != address(0)) {
                        super._update(from, stabilizerPool, half);
                    } else {
                        super._update(from, address(0), half);
                    }
                }
                value = value - burnAmount;
                emit Burned(from, burnAmount, burnBP);
            }
        }

        super._update(from, to, value);
    }

    // ---------- Admin / owner controls ----------
    function setAntiBot(bool active) external onlyOwner { antiBotActive = active; emit AntiBotToggled(active); }
    function setAntiBotParams(uint32 cd, uint16 txBP, uint16 walletBP) external onlyOwner {
        require(txBP <= BP_DENOM && walletBP <= BP_DENOM, "bad BP");
        cooldown = cd; maxTxBP = txBP; maxWalletBP = walletBP;
        emit AntiBotParamsUpdated(cd, txBP, walletBP);
    }
    function setBurnParams(uint16 baseBP, uint16 maxBP) external onlyOwner {
        require(baseBP <= BP_DENOM && maxBP <= BP_DENOM, "bad");
        baseBurnBP = baseBP; maxBurnBP = maxBP; emit BurnParamsUpdated(baseBP, maxBP);
    }
    function setStabilizerPool(address pool) external onlyOwner { stabilizerPool = pool; emit StabilizerPoolUpdated(pool); }

    // ---------- Pause ----------
    function pause() external onlyOwner { _pause(); }
    function unpause() external onlyOwner { _unpause(); }

    // ---------- Prevent ETH receipt ----------
    receive() external payable { revert(); }
    fallback() external payable { revert(); }
}
