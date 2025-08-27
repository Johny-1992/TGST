// SPDX-License-Identifier: MIT
pragma solidity ^0.8.21;

import "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/security/ReentrancyGuard.sol";
import "@openzeppelin/contracts/utils/Pausable.sol";
import "@openzeppelin/contracts/governance/TimelockController.sol";
import "@openzeppelin/contracts/utils/math/SafeMath.sol";

/// @title TGSTToken V4 Lunar (Optimisé pour la Lune)
/// @notice Secure Global Smart Trade Token avec burn, claim, referral, staking rewards, et conversion vers services partenaires.
contract TGSTTokenV4Lunar is ERC20, Ownable, ReentrancyGuard, Pausable {
using SafeMath for uint256;

// ----- Constants -----  
uint256 public constant MAX_SUPPLY = 1_000_000_000_000 * 1e18; // 1 trillion TGST (18 decimals)  
uint256 public constant MIN_STAKE_DURATION = 7 days;  
uint256 public constant MAX_BURN_RATE_BP = 1000; // 10%  
uint256 public constant MAX_DAILY_REWARD_BP = 50; // 0.5%  
uint256 public constant MAX_TOTAL_REWARD_BP = 2000; // 20%  

// ----- State Variables -----  
address public feeCollector;  
TimelockController public timelock;  

// Burn rates in basis points (1 BP = 0.01%)  
uint256 public burnOnTransferBP = 500; // 5%  
uint256 public burnOnRedeemBP = 300;  // 3%  
uint256 public burnOnSwapBP = 0;      // 0% by default  

// Optional fee to collect (on top of burn) on transfers, in bp.  
uint256 public feeOnTransferBP = 0;  

mapping(address => bool) public noFee;  
mapping(address => uint256) public lastClaim;  
uint256 public claimAmount = 100 * 1e18;  
uint256 public referralBonus = 50 * 1e18;  

// Staking rewards  
uint256 public dailyRewardBP = 10; // 0.1% per day  
uint256 public maxTotalRewardBP = 1000; // 10% max of staked amount  

// Pools (explicit funding to avoid relying on owner balance)  
uint256 public distributionPool; // used for claim + referral  
uint256 public rewardPool;       // used to pay staking rewards  

// Partners  
struct Partner {  
    string name;  
    uint256 tgstPerUnit; // 1 TGST = x service units (fixed-point with 18 decimals)  
    bool active;  
}  
mapping(address => Partner) public partners;  

// Staking  
mapping(address => uint256) public stakedBalance;  
mapping(address => uint256) public stakeTimestamp;  

// ----- Events -----  
event FeeCollectorUpdated(address indexed oldCollector, address indexed newCollector);  
event BurnRatesUpdated(uint256 transferBP, uint256 redeemBP, uint256 swapBP);  
event TransferFeeUpdated(uint256 feeOnTransferBP);  
event PartnerUpdated(address indexed partner, string name, uint256 tgstPerUnit, bool active);  
event TGSTClaimed(address indexed user, uint256 amount, address indexed referrer, uint256 referralAmount);  
event ReferralReward(address indexed referrer, address indexed referee, uint256 amount);  
event TokensBurned(address indexed user, uint256 amount, uint256 burnAmount, string reason);  
event ServiceConverted(address indexed user, address indexed partner, uint256 tgstAmount, uint256 serviceUnits);  
event Staked(address indexed user, uint256 amount);  
event Unstaked(address indexed user, uint256 staked, uint256 reward);  
event TimelockSet(address indexed timelock);  

// ----- Constructor -----  
constructor(address _feeCollector, address _timelock) ERC20("Token Global Smart Trade", "TGST") {  
    require(_feeCollector != address(0), "TGST: Invalid fee collector");  
    require(_timelock != address(0), "TGST: Invalid timelock");  
    feeCollector = _feeCollector;  
    timelock = TimelockController(_timelock);  
    noFee[msg.sender] = true;  
    noFee[_feeCollector] = true;  
    noFee[_timelock] = true;  
    _mint(msg.sender, MAX_SUPPLY);  
}  

// ----- Modifiers -----  
modifier onlyTimelock() {  
    require(msg.sender == address(timelock), "TGST: Only timelock");  
    _;  
}  

// ----- Administrative Functions -----  
function setFeeCollector(address _newCollector) external onlyTimelock {  
    require(_newCollector != address(0), "TGST: Invalid fee collector");  
    emit FeeCollectorUpdated(feeCollector, _newCollector);  
    feeCollector = _newCollector;  
    noFee[_newCollector] = true;  
}  

function setBurnRates(uint256 transferBP, uint256 redeemBP, uint256 swapBP) external onlyTimelock {  
    require(transferBP <= MAX_BURN_RATE_BP && redeemBP <= MAX_BURN_RATE_BP && swapBP <= MAX_BURN_RATE_BP, "TGST: Max 10%");  
    require(transferBP + feeOnTransferBP <= MAX_BURN_RATE_BP, "TGST: Transfer total too high");  
    burnOnTransferBP = transferBP;  
    burnOnRedeemBP = redeemBP;  
    burnOnSwapBP = swapBP;  
    emit BurnRatesUpdated(transferBP, redeemBP, swapBP);  
}  

function setTransferFeeBP(uint256 _feeOnTransferBP) external onlyTimelock {  
    require(_feeOnTransferBP + burnOnTransferBP <= MAX_BURN_RATE_BP, "TGST: Combined transfer fee too high");  
    feeOnTransferBP = _feeOnTransferBP;  
    emit TransferFeeUpdated(_feeOnTransferBP);  
}  

function addOrUpdatePartner(address partnerAddr, string memory name, uint256 tgstPerUnit, bool active) external onlyTimelock {  
    require(partnerAddr != address(0), "TGST: Invalid partner address");  
    require(tgstPerUnit > 0 && tgstPerUnit < 1e30, "TGST: Invalid tgstPerUnit");  
    partners[partnerAddr] = Partner(name, tgstPerUnit, active);  
    emit PartnerUpdated(partnerAddr, name, tgstPerUnit, active);  
}  

function setNoFee(address account, bool status) external onlyTimelock {  
    noFee[account] = status;  
}  

function setStakingParams(uint256 _dailyRewardBP, uint256 _maxTotalRewardBP) external onlyTimelock {  
    require(_dailyRewardBP <= MAX_DAILY_REWARD_BP, "TGST: Max 0.5% daily reward");  
    require(_maxTotalRewardBP <= MAX_TOTAL_REWARD_BP, "TGST: Max 20% total reward");  
    dailyRewardBP = _dailyRewardBP;  
    maxTotalRewardBP = _maxTotalRewardBP;  
}  

function pause() external onlyOwner {  
    _pause();  
}  

function unpause() external onlyOwner {  
    _unpause();  
}  

function fundDistribution(uint256 amount) external onlyOwner {  
    require(amount > 0, "TGST: Amount > 0");  
    super._transfer(msg.sender, address(this), amount);  
    distributionPool = distributionPool.add(amount);  
}  

function fundRewardPool(uint256 amount) external onlyOwner {  
    require(amount > 0, "TGST: Amount > 0");  
    super._transfer(msg.sender, address(this), amount);  
    rewardPool = rewardPool.add(amount);  
}  

function emergencyWithdraw(address to, uint256 amount) external onlyTimelock {  
    require(to != address(0), "TGST: Invalid to");  
    super._transfer(address(this), to, amount);  
}  

// ----- Claim + Referral -----  
function claimTGST(address referrer) external nonReentrant whenNotPaused {  
    require(block.timestamp.sub(lastClaim[msg.sender]) >= 1 days, "TGST: Claim max 1x/day");  
    uint256 totalRequired = claimAmount.add(referrer != address(0) && referrer != msg.sender ? referralBonus : 0);  
    require(distributionPool >= totalRequired, "TGST: Insufficient distribution pool");  

    super._transfer(address(this), msg.sender, claimAmount);  
    distributionPool = distributionPool.sub(claimAmount);  
    lastClaim[msg.sender] = block.timestamp;  

    uint256 referralAmount = 0;  
    if (referrer != address(0) && referrer != msg.sender) {  
        referralAmount = referralBonus;  
        super._transfer(address(this), referrer, referralAmount);  
        distributionPool = distributionPool.sub(referralAmount);  
        emit ReferralReward(referrer, msg.sender, referralAmount);  
    }  

    emit TGSTClaimed(msg.sender, claimAmount, referrer, referralAmount);  
}  

// ----- Dynamic Burn + Fee on Transfer -----  
function _transfer(address sender, address recipient, uint256 amount) internal override whenNotPaused {  
    if (noFee[sender] || noFee[recipient]) {  
        super._transfer(sender, recipient, amount);  
    } else {  
        uint256 burnAmount = amount.mul(burnOnTransferBP).div(10000);  
        uint256 feeAmount = amount.mul(feeOnTransferBP).div(10000);  
        uint256 sendAmount = amount.sub(burnAmount).sub(feeAmount);  

        if (burnAmount > 0) {  
            super._burn(sender, burnAmount);  
        }  
        if (feeAmount > 0) {  
            super._transfer(sender, feeCollector, feeAmount);  
        }  
        super._transfer(sender, recipient, sendAmount);  
        emit TokensBurned(sender, amount, burnAmount, "transfer");  
    }  
}  

function redeemBurn(uint256 amount) external nonReentrant whenNotPaused {  
    require(balanceOf(msg.sender) >= amount, "TGST: Insufficient balance");  
    uint256 burnAmount = amount.mul(burnOnRedeemBP).div(10000);  
    _burn(msg.sender, burnAmount);  
    emit TokensBurned(msg.sender, amount, burnAmount, "redeem");  
}  

function swapBurn(uint256 amount) external nonReentrant whenNotPaused {  
    require(balanceOf(msg.sender) >= amount, "TGST: Insufficient balance");  
    uint256 burnAmount = amount.mul(burnOnSwapBP).div(10000);  
    _burn(msg.sender, burnAmount);  
    emit TokensBurned(msg.sender, amount, burnAmount, "swap");  
}  

// ----- TGST → Partner Services Conversion -----  
function convertToService(address partnerAddr, uint256 tgstAmount) external nonReentrant whenNotPaused {  
    Partner memory partner = partners[partnerAddr];  
    require(partner.active, "TGST: Partner inactive");  
    require(balanceOf(msg.sender) >= tgstAmount, "TGST: Insufficient balance");  
    uint256 serviceUnits = tgstAmount.mul(partner.tgstPerUnit).div(1e18);  
    require(serviceUnits > 0, "TGST: Conversion too small");  

    _burn(msg.sender, tgstAmount);  
    emit ServiceConverted(msg.sender, partnerAddr, tgstAmount, serviceUnits);  
}  

// ----- Staking with Rewards -----  
function stakeTGST(uint256 amount) external nonReentrant whenNotPaused {  
    require(amount > 0, "TGST: Amount > 0");  
    require(balanceOf(msg.sender) >= amount, "TGST: Insufficient balance");  

    super._transfer(msg.sender, address(this), amount);  
    stakedBalance[msg.sender] = stakedBalance[msg.sender].add(amount);  
    stakeTimestamp[msg.sender] = block.timestamp;  
    emit Staked(msg.sender, amount);  
}  

function unstakeTGST() external nonReentrant whenNotPaused {  
    uint256 staked = stakedBalance[msg.sender];  
    require(staked > 0, "TGST: Nothing staked");  
    require(block.timestamp.sub(stakeTimestamp[msg.sender]) >= MIN_STAKE_DURATION, "TGST: Min stake duration not met");  

    uint256 daysStaked = block.timestamp.sub(stakeTimestamp[msg.sender]).div(1 days);  
    uint256 reward = staked.mul(dailyRewardBP).mul(daysStaked).div(10000);  
    uint256 maxReward = staked.mul(maxTotalRewardBP).div(10000);  
    reward = reward > maxReward ? maxReward : reward;  

    require(rewardPool >= reward, "TGST: Insufficient reward pool");  

    stakedBalance[msg.sender] = 0;  
    rewardPool = rewardPool.sub(reward);  

    super._transfer(address(this), msg.sender, staked.add(reward));  
    emit Unstaked(msg.sender, staked, reward);  
}  

// ----- Utility / Safety -----  
function setTimelock(address _timelock) external onlyTimelock {  
    require(_timelock != address(0), "TGST: Invalid timelock");  
    timelock = TimelockController(_timelock);  
    emit TimelockSet(_timelock);  
}  

receive() external payable {  
    revert("TGST: No ETH accepted");  
}  

fallback() external payable {  
    revert("TGST: No ETH accepted");  
}

}
