// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import "@openzeppelin/contracts/token/ERC20/extensions/ERC20Burnable.sol";
import "@openzeppelin/contracts/token/ERC20/extensions/ERC20Pausable.sol";
import "@openzeppelin/contracts/token/ERC20/extensions/ERC20Snapshot.sol";
import "@openzeppelin/contracts/token/ERC20/extensions/ERC20Permit.sol";
import "@openzeppelin/contracts/access/AccessControl.sol";
import "@openzeppelin/contracts/security/ReentrancyGuard.sol";
import "@openzeppelin/contracts/utils/cryptography/EIP712.sol";

contract TokenGlobalSmartTrade is
    ERC20,
    ERC20Burnable,
    ERC20Permit,
    ERC20Pausable,
    ERC20Snapshot,
    AccessControl,
    ReentrancyGuard,
    EIP712
{
    // --- Rôles ---
    bytes32 public constant MINTER_ROLE = keccak256("MINTER_ROLE");
    bytes32 public constant PAUSER_ROLE = keccak256("PAUSER_ROLE");
    bytes32 public constant SNAPSHOT_ROLE = keccak256("SNAPSHOT_ROLE");
    bytes32 public constant BURNER_ROLE = keccak256("BURNER_ROLE");

    // --- État ---
    uint256 private _taxRate = 5; // 5%
    uint256 private _liquidityRate = 3; // 3%
    address public marketingWallet;
    address public liquidityWallet;
    bool private _tradingEnabled = false;
    bool private _taxesEnabled = true;
    bool private _autoLiquidityEnabled = true;
    uint256 public swapThreshold = 0.1% * 1e18; // 0.1% du total supply
    uint256 public lastSwapBlock;
    mapping(address => bool) private _excludedFromTaxes;
    mapping(address => bool) private _excludedFromAutoLiquidity;

    // Adresse fixe de l'owner (votre wallet)
    address public constant OWNER = 0x40BB46B9D10Dd121e7D2150EC3784782ae648090;

    // --- Événements ---
    event TaxesUpdated(uint256 taxRate, uint256 liquidityRate);
    event TradingEnabled(bool enabled);
    event AutoLiquidityEnabled(bool enabled);
    event ExcludedFromTaxes(address indexed account, bool excluded);
    event ExcludedFromAutoLiquidity(address indexed account, bool excluded);
    event SwapAndLiquify(uint256 tokensSwapped, uint256 ethReceived, uint256 tokensIntoLiquidity);

    // --- Constructeur ---
    constructor()
        ERC20("Token Global Smart Trade", "TGST")
        EIP712("Token Global Smart Trade", "1")
    {
        // Attribution des rôles à l'owner fixe
        _grantRole(DEFAULT_ADMIN_ROLE, OWNER);
        _grantRole(MINTER_ROLE, OWNER);
        _grantRole(PAUSER_ROLE, OWNER);
        _grantRole(SNAPSHOT_ROLE, OWNER);
        _grantRole(BURNER_ROLE, OWNER);

        marketingWallet = OWNER;
        liquidityWallet = OWNER;

        // Mint initial de 1 million de tokens (1M * 10^decimals)
        _mint(OWNER, 1_000_000 * 10**decimals());
    }

    // --- Modifiers ---
    modifier onlyOwner() {
        require(msg.sender == OWNER, "Not owner");
        _;
    }

    modifier onlyWhenTradingEnabled() {
        require(_tradingEnabled, "Trading is not enabled yet");
        _;
    }

    modifier onlyWhenNotPaused() {
        require(!paused(), "Pausable: paused");
        _;
    }

    // --- Fonctions de Taxes ---
    function setTaxes(uint256 taxRate, uint256 liquidityRate) external onlyOwner {
        require(taxRate < 20 && liquidityRate < 20, "Rates too high");
        _taxRate = taxRate;
        _liquidityRate = liquidityRate;
        emit TaxesUpdated(taxRate, liquidityRate);
    }

    function setTaxesEnabled(bool enabled) external onlyOwner {
        _taxesEnabled = enabled;
    }

    function setExcludedFromTaxes(address account, bool excluded) external onlyOwner {
        _excludedFromTaxes[account] = excluded;
        emit ExcludedFromTaxes(account, excluded);
    }

    function isExcludedFromTaxes(address account) public view returns (bool) {
        return _excludedFromTaxes[account];
    }

    // --- Fonctions de Liquidity ---
    function setAutoLiquidityEnabled(bool enabled) external onlyOwner {
        _autoLiquidityEnabled = enabled;
        emit AutoLiquidityEnabled(enabled);
    }

    function setExcludedFromAutoLiquidity(address account, bool excluded) external onlyOwner {
        _excludedFromAutoLiquidity[account] = excluded;
        emit ExcludedFromAutoLiquidity(account, excluded);
    }

    function isExcludedFromAutoLiquidity(address account) public view returns (bool) {
        return _excludedFromAutoLiquidity[account];
    }

    function setWallets(address _marketingWallet, address _liquidityWallet) external onlyOwner {
        marketingWallet = _marketingWallet;
        liquidityWallet = _liquidityWallet;
    }

    // --- Trading ---
    function setTradingEnabled(bool enabled) external onlyOwner {
        _tradingEnabled = enabled;
        emit TradingEnabled(enabled);
    }

    // --- Overrides ERC20 ---
    function _transfer(
        address sender,
        address recipient,
        uint256 amount
    ) internal virtual override onlyWhenNotPaused {
        if (!_tradingEnabled && sender != OWNER && recipient != OWNER) {
            revert("Trading not enabled");
        }

        if (_taxesEnabled && !_excludedFromTaxes[sender] && !_excludedFromTaxes[recipient]) {
            uint256 taxAmount = (amount * _taxRate) / 100;
            uint256 liquidityAmount = (amount * _liquidityRate) / 100;
            uint256 transferAmount = amount - taxAmount - liquidityAmount;

            super._transfer(sender, recipient, transferAmount);
            super._transfer(sender, marketingWallet, taxAmount);

            if (_autoLiquidityEnabled && !_excludedFromAutoLiquidity[sender]) {
                super._transfer(sender, liquidityWallet, liquidityAmount);
                if (balanceOf(liquidityWallet) >= swapThreshold && block.number > lastSwapBlock + 30) {
                    swapAndLiquify(liquidityAmount);
                }
            }
        } else {
            super._transfer(sender, recipient, amount);
        }
    }

    // --- Swap & Liquify (exemple pour Uniswap - à adapter) ---
    function swapAndLiquify(uint256 amount) internal nonReentrant {
        // EXEMPLE POUR UNISWAP (à décommenter et adapter)
        /*
        IUniswapV2Router router = IUniswapV2Router(0x7a250d5630B4cF539739dF2C5dAcb4c659F2488D); // Mainnet
        address[] memory path = new address[](2);
        path[0] = address(this);
        path[1] = router.WETH();

        _approve(address(this), address(router), amount);
        uint256[] memory amounts = router.getAmountsOut
        // --- Suite de swapAndLiquify (implémentation complète) ---
        require(amount > 0, "Amount must be > 0");

        // 1. Approuver le router pour dépenser les tokens
        _approve(address(this), address(router), amount);

        // 2. Définir le chemin de swap (TGST -> WETH)
        address[] memory path = new address[](2);
        path[0] = address(this); // TGST
        path[1] = router.WETH(); // WETH

        // 3. Récupérer le montant minimal d'ETH attendu (avec slippage de 1%)
        uint256[] memory amounts = router.getAmountsOut(amount, path);
        uint256 amountETHMin = amounts[1] * 99 / 100; // 1% de slippage

        // 4. Effectuer le swap (TGST -> ETH)
        router.swapExactTokensForETHSupportingFeeOnTransferTokens(
            amount,
            amountETHMin,
            path,
            address(this),
            block.timestamp + 300 // 5 minutes de deadline
        );

        // 5. Récupérer l'ETH reçu par le contrat
        uint256 ethBalanceBefore = address(this).balance;
        uint256 ethReceived = address(this).balance - ethBalanceBefore;

        // 6. Ajouter de la liquidité (50% de l'ETH reçu est utilisé pour ajouter de la liquidité TGST/ETH)
        uint256 ethForLiquidity = ethReceived / 2;
        uint256 tgstForLiquidity = (amount * ethForLiquidity) / amounts[1]; // Ratio approximatif

        // Approuver le router pour dépenser les TGST pour la liquidité
        _approve(address(this), address(router), tgstForLiquidity);

        // Ajouter la liquidité (avec deadline)
        router.addLiquidityETH{value: ethForLiquidity}(
            address(this),
            tgstForLiquidity,
            0, // Min TGST (pas de slippage pour simplifier)
            0, // Min ETH (pas de slippage pour simplifier)
            address(this), // LP tokens envoyés au contrat
            block.timestamp + 300
        );

        // 7. Mettre à jour le dernier bloc de swap
        lastSwapBlock = block.number;

        // 8. Émettre l'événement avec les montants réels
        emit SwapAndLiquify(amount, ethReceived, tgstForLiquidity);
    }

    // --- Override _beforeTokenTransfer (résolution finale des conflits) ---
    function _beforeTokenTransfer(
        address from,
        address to,
        uint256 amount
    ) internal virtual override(ERC20, ERC20Pausable, ERC20Snapshot) {
        super._beforeTokenTransfer(from, to, amount);
    }

    // --- Override _afterTokenTransfer (pour les snapshots) ---
    function _afterTokenTransfer(
        address from,
        address to,
        uint256 amount
    ) internal virtual override(ERC20, ERC20Snapshot) {
        super._afterTokenTransfer(from, to, amount);
    }

    // --- Fonctions de Pause ---
    function pause() external onlyOwner {
        _pause();
    }

    function unpause() external onlyOwner {
        _unpause();
    }

    // --- Fonctions de Mint/Burn ---
    function mint(address to, uint256 amount) external onlyOwner {
        _mint(to, amount);
    }

    function burn(uint256 amount) public override onlyOwner {
        super.burn(amount);
    }

    function burnFrom(address account, uint256 amount) public override onlyOwner {
        super.burnFrom(account, amount);
    }

    // --- Récupération d'ETH (pour le contrat) ---
    function recoverETH(uint256 amount) external onlyOwner nonReentrant {
        payable(OWNER).transfer(amount);
    }

    // --- Getters ---
    function getTaxRate() external view returns (uint256) {
        return _taxRate;
    }

    function getLiquidityRate() external view returns (uint256) {
        return _liquidityRate;
    }

    function isTradingEnabled() external view returns (bool) {
        return _tradingEnabled;
    }

    function isAutoLiquidityEnabled() external view returns (bool) {
        return _autoLiquidityEnabled;
    }

    function getOwner() external view returns (address) {
        return OWNER;
    }

    // --- Fonction pour mettre à jour le swapThreshold ---
    function setSwapThreshold(uint256 threshold) external onlyOwner {
        require(threshold > 0, "Threshold must be > 0");
        swapThreshold = threshold;
    }

    // --- Vérification des exclusions ---
    function isExcluded(address account, bool checkTaxes, bool checkAutoLiquidity)
        external
        view
        returns (bool, bool)
    {
        return (
            checkTaxes ? _excludedFromTaxes[account] : false,
            checkAutoLiquidity ? _excludedFromAutoLiquidity[account] : false
        );
    }
}

// --- Interface Uniswap (à ajouter pour la compatibilité) ---
interface IUniswapV2Router {
    function WETH() external pure returns (address);

    function getAmountsOut(uint256 amountIn, address[] memory path)
        external
        view
        returns (uint256[] memory amounts);

    function swapExactTokensForETHSupportingFeeOnTransferTokens(
        uint256 amountIn,
        uint256 amountOutMin,
        address[] calldata path,
        address to,
        uint256 deadline
    ) external returns (uint256[] memory amounts);

    function addLiquidityETH(
        address token,
        uint256 amountTokenDesired,
        uint256 amountTokenMin,
        uint256 amountETHMin,
        address to,
        uint256 deadline
    ) external payable returns (uint256 amountToken, uint256 amountETH, uint256 liquidity);
}
