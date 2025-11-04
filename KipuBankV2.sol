// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "@openzeppelin/contracts/access/AccessControl.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import "@chainlink/contracts/src/v0.8/shared/interfaces/AggregatorV3Interface.sol";

/**
 * @title KipuBank V2
 * @author Kipu Protocol Team
 * @notice Banco multi-token con control de acceso, límites en USD y soporte ERC-20
 * @dev Implementa:
 *      - Control de acceso basado en roles (OpenZeppelin AccessControl)
 *      - Soporte multi-token (ETH + ERC-20)
 *      - Límites en USD usando Chainlink Price Feeds
 *      - Contabilidad normalizada a 6 decimales (USDC standard)
 *      - Protección contra reentrancy
 *      - Pausabilidad para emergencias
 */
contract KipuBankV2 is AccessControl, ReentrancyGuard {
    using SafeERC20 for IERC20;

// CONSTANTS
 

    /// @notice Rol de administrador con permisos completos
    bytes32 public constant ADMIN_ROLE = keccak256("ADMIN_ROLE");
    
    /// @notice Rol de operador para funciones administrativas diarias
    bytes32 public constant OPERATOR_ROLE = keccak256("OPERATOR_ROLE");
    
    /// @notice Dirección especial para representar ETH nativo
    address public constant NATIVE_TOKEN = address(0);
    
    /// @notice Decimales estándar para contabilidad interna (USDC = 6 decimales)
    uint8 public constant ACCOUNTING_DECIMALS = 6;
    
    /// @notice Decimales del precio de Chainlink (8 decimales)
    uint8 private constant CHAINLINK_DECIMALS = 8;

    /*  CUSTOM ERRORS*/

    error KipuBank__AmountMustBeGreaterThanZero();
    error KipuBank__DepositExceedsBankCap();
    error KipuBank__InsufficientBalance();
    error KipuBank__WithdrawalExceedsThreshold();
    error KipuBank__TransferFailed();
    error KipuBank__TokenNotSupported();
    error KipuBank__InvalidPriceFeed();
    error KipuBank__ContractPaused();
    error KipuBank__InvalidDecimals();
    error KipuBank__StalePrice();
    error KipuBank__InvalidPrice();

    /* STRUCTS*/

    /// @notice Información de un token soportado
    struct TokenInfo {
        bool isSupported;           // Si el token está habilitado
        uint8 decimals;             // Decimales del token
        address priceFeed;          // Chainlink price feed (token/USD)
        uint256 depositCount;       // Total de depósitos de este token
        uint256 withdrawalCount;    // Total de retiros de este token
    }

    /*
              STATE VARIABLES
    */

    /// @notice Límite de retiro máximo por transacción en USD (6 decimales)
    uint256 public immutable i_withdrawalThresholdUSD;

    /// @notice Límite global del banco en USD (6 decimales)
    uint256 public immutable i_bankCapUSD;

    /// @notice Total depositado en el banco (normalizado a 6 decimales)
    uint256 private s_totalDepositsNormalized;

    /// @notice Si el contrato está pausado
    bool private s_paused;

    /// @notice Información de tokens soportados: token address => TokenInfo
    mapping(address => TokenInfo) private s_supportedTokens;

    /// @notice Balance de bóveda: usuario => token => balance normalizado (6 decimales)
    mapping(address => mapping(address => uint256)) private s_vaults;

    /// @notice Lista de tokens soportados (para iteración)
    address[] private s_tokenList;

    /// @notice Tolerancia de tiempo para precios de Chainlink (1 hora)
    uint256 private constant PRICE_STALENESS_THRESHOLD = 3600;

    /*     EVENTS */

    event Deposit(
        address indexed user,
        address indexed token,
        uint256 amount,
        uint256 normalizedAmount,
        uint256 newBalance
    );

    event Withdrawal(
        address indexed user,
        address indexed token,
        uint256 amount,
        uint256 normalizedAmount,
        uint256 remainingBalance
    );

    event TokenAdded(
        address indexed token,
        address indexed priceFeed,
        uint8 decimals
    );

    event TokenRemoved(address indexed token);

    event Paused(address indexed admin);
    event Unpaused(address indexed admin);

    /*
                                    MODIFIERS
    */

    modifier nonZeroAmount(uint256 amount) {
        if (amount == 0) revert KipuBank__AmountMustBeGreaterThanZero();
        _;
    }

    modifier tokenSupported(address token) {
        if (!s_supportedTokens[token].isSupported) {
            revert KipuBank__TokenNotSupported();
        }
        _;
    }

    modifier whenNotPaused() {
        if (s_paused) revert KipuBank__ContractPaused();
        _;
    }

    /*
                                    CONSTRUCTOR
   */

    /**
     * @notice Inicializa KipuBank V2
     * @param withdrawalThresholdUSD Límite de retiro en USD (6 decimales, ej: 1000_000000 = $1,000)
     * @param bankCapUSD Límite total del banco en USD (6 decimales)
     * @param ethPriceFeed Dirección del Chainlink ETH/USD price feed
     */
    constructor(
        uint256 withdrawalThresholdUSD,
        uint256 bankCapUSD,
        address ethPriceFeed
    ) {
        i_withdrawalThresholdUSD = withdrawalThresholdUSD;
        i_bankCapUSD = bankCapUSD;

        // Configurar roles
        _grantRole(DEFAULT_ADMIN_ROLE, msg.sender);
        _grantRole(ADMIN_ROLE, msg.sender);
        _grantRole(OPERATOR_ROLE, msg.sender);

        // Agregar ETH nativo como token soportado
        _addToken(NATIVE_TOKEN, ethPriceFeed, 18);
    }

    /*  DEPOSIT FUNCTIONS
    */

    /**
     * @notice Deposita ETH nativo en la bóveda del usuario
     */
    function depositNative()
        external
        payable
        nonZeroAmount(msg.value)
        tokenSupported(NATIVE_TOKEN)
        whenNotPaused
        nonReentrant
    {
        _deposit(NATIVE_TOKEN, msg.value);
    }

    /**
     * @notice Deposita tokens ERC-20 en la bóveda del usuario
     * @param token Dirección del token ERC-20
     * @param amount Cantidad de tokens a depositar
     */
    function depositToken(address token, uint256 amount)
        external
        nonZeroAmount(amount)
        tokenSupported(token)
        whenNotPaused
        nonReentrant
    {
        if (token == NATIVE_TOKEN) revert KipuBank__TokenNotSupported();

        // Transferir tokens del usuario al contrato
        IERC20(token).safeTransferFrom(msg.sender, address(this), amount);

        _deposit(token, amount);
    }

    /**
     * @notice Lógica interna de depósito
     * @param token Dirección del token
     * @param amount Cantidad depositada (en decimales originales del token)
     */
    function _deposit(address token, uint256 amount) private {
        // Normalizar cantidad a 6 decimales
        uint256 normalizedAmount = _normalizeAmount(
            amount,
            s_supportedTokens[token].decimals
        );

        // Obtener valor en USD
        uint256 valueInUSD = _getValueInUSD(token, normalizedAmount);

        // Verificar límite del banco
        if (s_totalDepositsNormalized + valueInUSD > i_bankCapUSD) {
            revert KipuBank__DepositExceedsBankCap();
        }

        // Actualizar estado
        s_vaults[msg.sender][token] += normalizedAmount;
        s_totalDepositsNormalized += valueInUSD;
        s_supportedTokens[token].depositCount++;

        emit Deposit(
            msg.sender,
            token,
            amount,
            normalizedAmount,
            s_vaults[msg.sender][token]
        );
    }

    /*        WITHDRAWAL FUNCTIONS
  */

    /**
     * @notice Retira ETH nativo de la bóveda del usuario
     * @param amount Cantidad de ETH a retirar (en wei)
     */
    function withdrawNative(uint256 amount)
        external
        nonZeroAmount(amount)
        tokenSupported(NATIVE_TOKEN)
        whenNotPaused
        nonReentrant
    {
        _withdraw(NATIVE_TOKEN, amount);
    }

    /**
     * @notice Retira tokens ERC-20 de la bóveda del usuario
     * @param token Dirección del token ERC-20
     * @param amount Cantidad de tokens a retirar
     */
    function withdrawToken(address token, uint256 amount)
        external
        nonZeroAmount(amount)
        tokenSupported(token)
        whenNotPaused
        nonReentrant
    {
        if (token == NATIVE_TOKEN) revert KipuBank__TokenNotSupported();
        _withdraw(token, amount);
    }

    /**
     * @notice Lógica interna de retiro
     * @param token Dirección del token
     * @param amount Cantidad a retirar (en decimales originales del token)
     */
    function _withdraw(address token, uint256 amount) private {
        // Normalizar cantidad
        uint256 normalizedAmount = _normalizeAmount(
            amount,
            s_supportedTokens[token].decimals
        );

        // Verificar balance suficiente
        if (s_vaults[msg.sender][token] < normalizedAmount) {
            revert KipuBank__InsufficientBalance();
        }

        // Verificar límite de retiro en USD
        uint256 valueInUSD = _getValueInUSD(token, normalizedAmount);
        if (valueInUSD > i_withdrawalThresholdUSD) {
            revert KipuBank__WithdrawalExceedsThreshold();
        }

        // Actualizar estado ANTES de transferir
        s_vaults[msg.sender][token] -= normalizedAmount;
        s_totalDepositsNormalized -= valueInUSD;
        s_supportedTokens[token].withdrawalCount++;

        uint256 remainingBalance = s_vaults[msg.sender][token];

        // Transferir tokens
        if (token == NATIVE_TOKEN) {
            (bool success, ) = payable(msg.sender).call{value: amount}("");
            if (!success) revert KipuBank__TransferFailed();
        } else {
            IERC20(token).safeTransfer(msg.sender, amount);
        }

        emit Withdrawal(
            msg.sender,
            token,
            amount,
            normalizedAmount,
            remainingBalance
        );
    }

    /*      ADMIN FUNCTIONS
    */

    /**
     * @notice Agrega un nuevo token soportado
     * @param token Dirección del token (address(0) para ETH)
     * @param priceFeed Chainlink price feed para token/USD
     * @param decimals Decimales del token
     */
    function addToken(address token, address priceFeed, uint8 decimals)
        external
        onlyRole(ADMIN_ROLE)
    {
        _addToken(token, priceFeed, decimals);
    }

    function _addToken(address token, address priceFeed, uint8 decimals) private {
        if (priceFeed == address(0)) revert KipuBank__InvalidPriceFeed();
        if (decimals > 18) revert KipuBank__InvalidDecimals();

        if (!s_supportedTokens[token].isSupported) {
            s_tokenList.push(token);
        }

        s_supportedTokens[token] = TokenInfo({
            isSupported: true,
            decimals: decimals,
            priceFeed: priceFeed,
            depositCount: s_supportedTokens[token].depositCount,
            withdrawalCount: s_supportedTokens[token].withdrawalCount
        });

        emit TokenAdded(token, priceFeed, decimals);
    }

    /**
     * @notice Remueve un token soportado
     * @param token Dirección del token a remover
     */
    function removeToken(address token) external onlyRole(ADMIN_ROLE) {
        if (token == NATIVE_TOKEN) revert KipuBank__TokenNotSupported();
        
        s_supportedTokens[token].isSupported = false;
        emit TokenRemoved(token);
    }

    /**
     * @notice Pausa el contrato (emergencias)
     */
    function pause() external onlyRole(ADMIN_ROLE) {
        s_paused = true;
        emit Paused(msg.sender);
    }

    /**
     * @notice Despausa el contrato
     */
    function unpause() external onlyRole(ADMIN_ROLE) {
        s_paused = false;
        emit Unpaused(msg.sender);
    }

    /*    PRICE FUNCTIONS
 */

    /**
     * @notice Obtiene el precio actual de un token en USD desde Chainlink
     * @param token Dirección del token
     * @return Precio en USD (8 decimales)
     */
    function getTokenPriceUSD(address token)
        public
        view
        tokenSupported(token)
        returns (uint256)
    {
        AggregatorV3Interface priceFeed = AggregatorV3Interface(
            s_supportedTokens[token].priceFeed
        );

        (
            uint80 roundId,
            int256 price,
            ,
            uint256 updatedAt,
            uint80 answeredInRound
        ) = priceFeed.latestRoundData();

        // Validar datos del oráculo
        if (price <= 0) revert KipuBank__InvalidPrice();
        if (answeredInRound < roundId) revert KipuBank__StalePrice();
        if (block.timestamp - updatedAt > PRICE_STALENESS_THRESHOLD) {
            revert KipuBank__StalePrice();
        }

        return uint256(price);
    }

    /**
     * @notice Calcula el valor en USD de una cantidad normalizada de tokens
     * @param token Dirección del token
     * @param normalizedAmount Cantidad en 6 decimales
     * @return Valor en USD (6 decimales)
     */
    function _getValueInUSD(address token, uint256 normalizedAmount)
        private
        view
        returns (uint256)
    {
        uint256 priceUSD = getTokenPriceUSD(token); // 8 decimales
        
        // Convertir: (amount * price) / 10^8 = USD con 6 decimales
        return (normalizedAmount * priceUSD) / (10 ** CHAINLINK_DECIMALS);
    }

    /**
     * @notice Normaliza una cantidad de tokens a 6 decimales (USDC standard)
     * @param amount Cantidad en decimales originales
     * @param tokenDecimals Decimales del token original
     * @return Cantidad normalizada a 6 decimales
     */
    function _normalizeAmount(uint256 amount, uint8 tokenDecimals)
        private
        pure
        returns (uint256)
    {
        if (tokenDecimals == ACCOUNTING_DECIMALS) {
            return amount;
        } else if (tokenDecimals > ACCOUNTING_DECIMALS) {
            return amount / (10 ** (tokenDecimals - ACCOUNTING_DECIMALS));
        } else {
            return amount * (10 ** (ACCOUNTING_DECIMALS - tokenDecimals));
        }
    }

    /*   VIEW FUNCTIONS*/

    /**
     * @notice Obtiene el balance normalizado de un usuario para un token
     * @param user Dirección del usuario
     * @param token Dirección del token
     * @return Balance normalizado (6 decimales)
     */
    function getVaultBalance(address user, address token)
        external
        view
        returns (uint256)
    {
        return s_vaults[user][token];
    }

    /**
     * @notice Obtiene el balance del llamador para un token
     * @param token Dirección del token
     * @return Balance normalizado (6 decimales)
     */
    function getMyVaultBalance(address token) external view returns (uint256) {
        return s_vaults[msg.sender][token];
    }

    /**
     * @notice Obtiene el valor total en USD de un usuario
     * @param user Dirección del usuario
     * @return Valor total en USD (6 decimales)
     */
    function getUserTotalValueUSD(address user)
        external
        view
        returns (uint256)
    {
        uint256 totalValue = 0;
        
        for (uint256 i = 0; i < s_tokenList.length; i++) {
            address token = s_tokenList[i];
            if (s_supportedTokens[token].isSupported) {
                uint256 balance = s_vaults[user][token];
                if (balance > 0) {
                    totalValue += _getValueInUSD(token, balance);
                }
            }
        }
        
        return totalValue;
    }

    /**
     * @notice Obtiene el total de depósitos del banco en USD
     * @return Total en USD (6 decimales)
     */
    function getTotalDepositsUSD() external view returns (uint256) {
        return s_totalDepositsNormalized;
    }

    /**
     * @notice Obtiene la capacidad disponible del banco en USD
     * @return Espacio disponible en USD (6 decimales)
     */
    function getAvailableCapacityUSD() external view returns (uint256) {
        return i_bankCapUSD - s_totalDepositsNormalized;
    }

    /**
     * @notice Obtiene información de un token
     * @param token Dirección del token
     * @return TokenInfo struct con información del token
     */
    function getTokenInfo(address token)
        external
        view
        returns (TokenInfo memory)
    {
        return s_supportedTokens[token];
    }

    /**
     * @notice Obtiene la lista de tokens soportados
     * @return Array de direcciones de tokens
     */
    function getSupportedTokens() external view returns (address[] memory) {
        return s_tokenList;
    }

    /**
     * @notice Verifica si el contrato está pausado
     * @return true si está pausado
     */
    function isPaused() external view returns (bool) {
        return s_paused;
    }
}
