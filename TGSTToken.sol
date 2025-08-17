
// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import "@openzeppelin/contracts/access/Ownable.sol";

contract TGSTToken is ERC20, Ownable {
    // 1 trillion supply with 18 decimals
    uint256 public constant MAX_SUPPLY = 1_000_000_000_000 * 10 ** 18;

    address public feeCollector;
    uint256 public burnOnTransferBP = 500; // 5% (basis points)
    uint256 public burnOnRedeemBP = 300;   // 3%
    uint256 public burnOnSwapBP = 0;       // 0%

    mapping(address => bool) public noFee;

    event FeeCollectorUpdated(address indexed to);
    event BurnRatesUpdated(uint256 transferBP, uint256 redeemBP, uint256 swapBP);

    constructor(address _feeCollector) ERC20("Token Global Smart Trade", "TGST") Ownable(msg.sender) {
        require(_feeCollector != address(0), "feeCollector zero");
        feeCollector = _feeCollector;
        _mint(msg.sender, MAX_SUPPLY);
        noFee[msg.sender] = true;
        noFee[_feeCollector] = true;
    }

    function setFeeCollector(address _to) external onlyOwner {
        require(_to != address(0), "zero");
        feeCollector = _to;
        emit FeeCollectorUpdated(_to);
    }

    function setBurnRates(uint256 _transferBP, uint256 _redeemBP, uint256 _swapBP) external onlyOwner {
        require(_transferBP <= 1000 && _redeemBP <= 1000 && _swapBP <= 1000, "max 10%");
        burnOnTransferBP = _transferBP;
        burnOnRedeemBP = _redeemBP;
        burnOnSwapBP = _swapBP;
        emit BurnRatesUpdated(_transferBP, _redeemBP, _swapBP);
    }

    function setNoFee(address who, bool enabled) external onlyOwner {
        noFee[who] = enabled;
    }

    function _transfer(address from, address to, uint256 amount) internal override {
        if (noFee[from] || noFee[to]) {
            super._transfer(from, to, amount);
            return;
        }
        uint256 burnAmt = amount * burnOnTransferBP / 10000;
        uint256 feeAmt = 0; // optional collector route later
        uint256 sendAmt = amount - burnAmt - feeAmt;
        if (burnAmt > 0) _burn(from, burnAmt);
        if (feeAmt > 0) super._transfer(from, feeCollector, feeAmt);
        super._transfer(from, to, sendAmt);
    }

    // simulated redeem burn hook
    function redeemBurn(uint256 amount) external {
        uint256 burnAmt = amount * burnOnRedeemBP / 10000;
        _burn(msg.sender, burnAmt);
        // remaining could be handled off-chain with partner services
    }

    function swapBurn(uint256 amount) external {
        uint256 burnAmt = amount * burnOnSwapBP / 10000;
        _burn(msg.sender, burnAmt);
    }
}
