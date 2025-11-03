# kipu_bankV2-sol
º Tabla de Contenidos
- [Resumen Ejecutivo]
- [Mejoras Implementadas]
- [Arquitectura y Diseño
- [Requisitos Previos]
- [Instalación]
- [Despliegue]
- [Guía de Interacción]
- [Decisiones de Diseño]
- [Trade-offs y Consideraciones]
- [Seguridad]
- [Testing]
- [Gas Optimization]

 Resumen Ejecutivo

KipuBank V2 es una evolución completa del contrato bancario original, transformándolo de un prototipo educativo a un sistema de producción empresarial. La versión 2 introduce capacidades multi-token, límites denominados en USD usando oráculos de Chainlink, control de acceso basado en roles, y múltiples capas de seguridad.

 Características Principales

Soporte Multi-Token: ETH nativo + cualquier token ERC-20  
Límites en USD: Bank cap y withdrawal threshold controlados por precio real  
Control de Acceso: Sistema de roles jerárquico (Admin/Operator)  
Contabilidad Normalizada: Sistema unificado de 6 decimales  
Integración Chainlink: Price feeds para conversión ETH/Token ↔ USD  
Seguridad Robusta: ReentrancyGuard, pausabilidad, validación de oráculos  
Gas Optimizado: Variables immutable, custom errors, packed storage  

 Mejoras Implementadas

 1. Control de Acceso Basado en Roles

Problema Original: El contrato V1 no tenía ningún mecanismo de control administrativo. Una vez desplegado, no se podían agregar nuevas funcionalidades ni gestionar el sistema.

Solución Implementada:
```solidity
import "@openzeppelin/contracts/access/AccessControl.sol";

bytes32 public constant ADMIN_ROLE = keccak256("ADMIN_ROLE");
bytes32 public constant OPERATOR_ROLE = keccak256("OPERATOR_ROLE");
```

Beneficios:
- **Administración Segura**: Solo cuentas autorizadas pueden modificar parámetros críticos
- **Separación de Privilegios**: Admins para cambios estructurales, Operators para operaciones diarias
- **Auditabilidad**: Todos los cambios de roles emiten eventos
- **Revocabilidad**: Permisos pueden ser otorgados y revocados dinámicamente

Funciones Protegidas:
- `addToken()`: Agregar nuevos tokens soportados
- `removeToken()`: Deshabilitar tokens
- `pause()/unpause()`: Control de emergencia

---

 2. Soporte Multi-Token (ETH + ERC-20)

Problema Original: Solo soportaba ETH nativo, limitando severamente su utilidad en el ecosistema DeFi moderno.
Solución Implementada:
```solidity
using SafeERC20 for IERC20;

address public constant NATIVE_TOKEN = address(0);

// Vaults multi-dimensionales
mapping(address => mapping(address => uint256)) private s_vaults;
```

Beneficio:
-Flexibilidad: Usuarios pueden depositar USDC, DAI, WETH, o cualquier ERC-20
- Diversificación : Portfolios multi-asset dentro del mismo contrato
- SafeERC20: Maneja tokens no-estándar (sin return values) de forma segura
- Segregación Limpia: ETH representado como `address(0)` para consistencia

Ejemplo de Uso:
```solidity
// Depositar ETH
bank.depositNative{value: 1 ether}();

// Depositar USDC
IERC20(usdcAddress).approve(address(bank), 1000e6);
bank.depositToken(usdcAddress, 1000e6);
```

3. Contabilidad Interna Normalizada

Problema Origina: No consideraba diferentes decimales entre tokens, lo que hubiera causado problemas al expandir a ERC-20s.

Solución Implementada:
```solidity
uint8 public constant ACCOUNTING_DECIMALS = 6; // USDC standard

function _normalizeAmount(uint256 amount, uint8 tokenDecimals) 
    private pure returns (uint256) 
{
    if (tokenDecimals == ACCOUNTING_DECIMALS) {
        return amount;
    } else if (tokenDecimals > ACCOUNTING_DECIMALS) {
        return amount / (10 ** (tokenDecimals - ACCOUNTING_DECIMALS));
    } else {
        return amount * (10 ** (ACCOUNTING_DECIMALS - tokenDecimals));
    }
}
```
Beneficios:
- **Consistencia: Todos los balances internos usan la misma base (6 decimales)
- Comparabilidad: Fácil sumar valores de diferentes tokens
- Prevención de Errores**: Evita confusiones entre 18 decimales (ETH) y 6 (USDC)
 - Estándar DeFi: 6 decimales es el estándar de facto (USDC, USDT)

Ejemplo:
```
Input: 1 ETH (18 decimales) = 1_000000000000000000
Normalizado: 1_000000 (6 decimales)

Input: 1000 USDC (6 decimales) = 1000_000000
Normalizado: 1000_000000 (sin cambios)
```

---

 4. Integración con Oráculos Chainlink

Problema Original: Los límites estaban en unidades de token (ETH), lo que causa problemas con volatilidad. Un bank cap de 10 ETH podría valer $20k un día y $30k al siguiente.

Solución Implementada:
```solidity
import "@chainlink/contracts/src/v0.8/shared/interfaces/AggregatorV3Interface.sol";

function getTokenPriceUSD(address token) 
    public view returns (uint256) 
{
    AggregatorV3Interface priceFeed = AggregatorV3Interface(
        s_supportedTokens[token].priceFeed
    );
    
    (uint80 roundId, int256 price, , uint256 updatedAt, uint80 answeredInRound) 
        = priceFeed.latestRoundData();
    
    // Validaciones de seguridad
    if (price <= 0) revert KipuBank__InvalidPrice();
    if (answeredInRound < roundId) revert KipuBank__StalePrice();
    if (block.timestamp - updatedAt > PRICE_STALENESS_THRESHOLD) {
        revert KipuBank__StalePrice();
    }
    
    return uint256(price);
}
```

Beneficios:
- Estabilidad: Bank cap de $1M USD permanece constante independientemente del precio de ETH
- Previsibilidad: Los usuarios saben exactamente cuánto pueden retirar en términos de valor real
- Seguridad: Validación robusta contra precios obsoletos o manipulados
  Flexibilidad: Permite agregar cualquier token con price feed disponible

Validaciones de Seguridad:
1. Precio válido: `price > 0`
2. Round completado: `answeredInRound >= roundId`
3. Datos recientes: `updatedAt` dentro de 1 hora
4. Staleness threshol: Protección contra oráculos dormidos
-----
 5. Manejo de Conversión de Decimales

Problema Original: No existía manejo de decimales, limitándose a ETH.

Solución Implementad:
```solidity
struct TokenInfo {
    bool isSupported;
    uint8 decimals;           // Decimales del token original
    address priceFeed;
    uint256 depositCount;
    uint256 withdrawalCount;
}

// Conversión multi-paso
Amount (token decimals) 
  → Normalized (6 decimals) 
  → USD Value (6 decimals)
```
Flujo de Conversión:
```
Ejemplo: Depositar 1 WBTC (8 decimales) cuando BTC = $50,000

1. Input: 1_00000000 (8 decimales)
2. Normalizar: 1_000000 (6 decimales)
3. Precio Chainlink: 5000000000000 (8 decimales = $50k)
4. Valor USD: (1_000000 * 5000000000000) / 10^8 = 50000_000000 ($50k con 6 decimales)
```

---

 6. Eventos Mejorados y Errores Personalizados
Problema Original: Eventos básicos, uso de `require` con strings (alto consumo de gas).

Solución Implementada:
```solidity
// Errores custom (gas-efficient)
error KipuBank__DepositExceedsBankCap();
error KipuBank__WithdrawalExceedsThreshold();
error KipuBank__StalePrice();

// Eventos enriquecidos
event Deposit(
    address indexed user,
    address indexed token,
    uint256 amount,              // Cantidad original
    uint256 normalizedAmount,    // Cantidad normalizada
    uint256 newBalance           // Balance post-operación
);
```

Beneficios:
- Gas Savings: Custom errors ahorran ~50% vs `require` con string
- Mejor Debugging: Eventos con más contexto facilitan análisis off-chain
- Indexación*: Campos `indexed` permiten búsquedas eficientes en exploradores

---
 7. Seguridad Multi-Capa

Implementaciones:

A. ReentrancyGuard
```solidity
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

function withdraw(...) external nonReentrant {
    // Protegido contra ataques de reentrada
}
```

 B. Checks-Effects-Interactions Pattern
```solidity
function _withdraw(address token, uint256 amount) private {
    // 1. CHECKS
    if (s_vaults[msg.sender][token] < normalizedAmount) {
        revert KipuBank__InsufficientBalance();
    }
    
    // 2. EFFECTS
    s_vaults[msg.sender][token] -= normalizedAmount;
    s_totalDepositsNormalized -= valueInUSD;
    
    // 3. INTERACTIONS
    IERC20(token).safeTransfer(msg.sender, amount);
}
```
 C. Pausabilidad
```solidity
modifier whenNotPaused() {
    if (s_paused) revert KipuBank__ContractPaused();
    _;
}

function pause() external onlyRole(ADMIN_ROLE) {
    s_paused = true;
    emit Paused(msg.sender);
}
```
 D. Validación de Inputs
```solidity
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
```

---

 Arquitectura y Diseño

* Estructura de Datos

```
Usuario
  └─ Vaults (mapping)
       ├─ ETH (address(0)) → Balance normalizado
       ├─ USDC → Balance normalizado
       ├─ DAI → Balance normalizado
       └─ WBTC → Balance normalizado

Tokens Soportados
  └─ TokenInfo
       ├─ isSupported: bool
       ├─ decimals: uint8
       ├─ priceFeed: address (Chainlink)
       ├─ depositCount: uint256
       └─ withdrawalCount: uint256
```
 Flujo de Depósito

```
1. Usuario llama depositToken(USDC, 1000e6)
2. Contrato valida: amount > 0, token soportado, no pausado
3. SafeERC20 transfiere USDC del usuario al contrato
4. Se normaliza: 1000_000000 → 1000_000000 (ya es 6 decimales)
5. Se obtiene precio USDC: ~$1.00
6. Se calcula valor USD: ~1000_000000 ($1000)
7. Se verifica: totalDeposits + $1000 <= bankCap
8. Se actualiza estado:
   - s_vaults[user][USDC] += 1000_000000
   - s_totalDepositsNormalized += 1000_000000
9. Se emite evento Deposit
```
 Flujo de Retiro

```
1. Usuario llama withdrawToken(USDC, 500e6)
2. Contrato valida: amount > 0, token soportado, no pausado
3. Se normaliza: 500_000000
4. Se verifica balance: s_vaults[user][USDC] >= 500_000000
5. Se calcula valor USD: ~$500
6. Se verifica límite: $500 <= withdrawalThresholdUSD
7. Se actualiza estado ANTES de transferir:
   - s_vaults[user][USDC] -= 500_000000
   - s_totalDepositsNormalized -= 500_000000
8. SafeERC20 transfiere 500 USDC al usuario
9. Se emite evento Withdrawal
```

---
 Requisitos Previos

 Software Necesario

```bash
# Node.js v18+
node --version

# Foundry (recomendado)
curl -L https://foundry.paradigm.xyz | bash
foundryup

# O Hardhat
npm install --save-dev hardhat
```

# Dependencias

```bash
# OpenZeppelin Contracts
npm install @openzeppelin/contracts

# Chainlink Contracts
npm install @chainlink/contracts
```

---

# Instalación

Foundry 

```bash
# Crear proyecto
forge init kipubank-v2
cd kipubank-v2

# Instalar dependencias
forge install OpenZeppelin/openzeppelin-contracts
forge install smartcontractkit/chainlink

# Configurar remappings en foundry.toml
echo '@openzeppelin/=lib/openzeppelin-contracts/' >> remappings.txt
echo '@chainlink/=lib/chainlink/' >> remappings.txt

# Copiar contrato
# Guardar KipuBankV2.sol en src/

# Compilar
forge build
```
 Despliegue

-Parámetros de Constructor

```solidity
constructor(
    uint256 withdrawalThresholdUSD,  // Límite de retiro en USD (6 decimales)
    uint256 bankCapUSD,              // Capacidad total en USD (6 decimales)
    address ethPriceFeed             // Chainlink ETH/USD price feed
)
```

 Chainlink Price Feeds por Red

-- Ethereum Mainnet
- **ETH/USD**: `0x5f4eC3Df9cbd43714FE2740f5E3616155c5b8419`
- **BTC/USD**: `0xF4030086522a5bEEa4988F8cA5B36dbC97BeE88c`
- **USDC/USD**: `0x8fFfFfd4AfB6115b954Bd326cbe7B4BA576818f6`

-- Sepolia Testnet
- **ETH/USD**: `0x694AA1769357215DE4FAC081bf1f309aDC325306`
- **BTC/USD**: `0x1b44F3514812d835EB1BDB0acB33d3fA3351Ee43`

-- Arbitrum One
- **ETH/USD**: `0x639Fe6ab55C921f74e7fac1ee960C0B6293ba612`

-- Script de Despliegue (Foundry)

```solidity
// script/DeployKipuBankV2.s.sol
pragma solidity ^0.8.20;

import "forge-std/Script.sol";
import "../src/KipuBankV2.sol";

contract DeployKipuBankV2 is Script {
    function run() external {
        uint256 deployerPrivateKey = vm.envUint("PRIVATE_KEY");
        
        vm.startBroadcast(deployerPrivateKey);
        
        // Parámetros
        uint256 withdrawalThreshold = 10_000_000000;  // $10,000 USD
        uint256 bankCap = 1_000_000_000000;           // $1,000,000 USD
        address ethPriceFeed = 0x5f4eC3Df9cbd43714FE2740f5E3616155c5b8419; // Mainnet
        
        KipuBankV2 bank = new KipuBankV2(
            withdrawalThreshold,
            bankCap,
            ethPriceFeed
        );
        
        console.log("KipuBank V2 deployed at:", address(bank));
        
        vm.stopBroadcast();
    }
}
```

-- Ejecutar Despliegue

```bash
# Configurar variables de entorno
export PRIVATE_KEY="tu_private_key"
export ETHERSCAN_API_KEY="tu_etherscan_key"

# Desplegar en Sepolia
forge script script/DeployKipuBankV2.s.sol:DeployKipuBankV2 \
    --rpc-url https://sepolia.infura.io/v3/YOUR_KEY \
    --broadcast \
    --verify

# Desplegar en Mainnet (con más verificaciones)
forge script script/DeployKipuBankV2.s.sol:DeployKipuBankV2 \
    --rpc-url https://mainnet.infura.io/v3/YOUR_KEY \
    --broadcast \
    --verify \
    --slow
```

 Script de Despliegue (Hardhat)

```javascript
// scripts/deploy.js
const hre = require("hardhat");

async function main() {
  // Parámetros
  const withdrawalThreshold = ethers.parseUnits("10000", 6);  // $10k
  const bankCap = ethers.parseUnits("1000000", 6);            // $1M
  const ethPriceFeed = "0x694AA1769357215DE4FAC081bf1f309aDC325306"; // Sepolia
  
  // Desplegar
  const KipuBankV2 = await hre.ethers.getContractFactory("KipuBankV2");
  const bank = await KipuBankV2.deploy(
    withdrawalThreshold,
    bankCap,
    ethPriceFeed
  );
  
  await bank.waitForDeployment();
  
  console.log("KipuBank V2 deployed to:", await bank.getAddress());
}

main().catch((error) => {
  console.error(error);
  process.exitCode = 1;
});
```

```bash
npx hardhat run scripts/deploy.js --network sepolia
```

---

 Guía de Interacción

 1. Configuración Inicial (Solo Admin)

```javascript
const bank = await ethers.getContractAt("KipuBankV2", BANK_ADDRESS);

// Agregar USDC como token soportado
const USDC_ADDRESS = "0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48";
const USDC_PRICE_FEED = "0x8fFfFfd4AfB6115b954Bd326cbe7B4BA576818f6";
const USDC_DECIMALS = 6;

await bank.addToken(USDC_ADDRESS, USDC_PRICE_FEED, USDC_DECIMALS);

// Agregar WBTC
const WBTC_ADDRESS = "0x2260FAC5E5542a773Aa44fBCfeDf7C193bc2C599";
const WBTC_PRICE_FEED = "0xF4030086522a5bEEa4988F8cA5B36dbC97BeE88c";
const WBTC_DECIMALS = 8;

await bank.addToken(WBTC_ADDRESS, WBTC_PRICE_FEED, WBTC_DECIMALS);

console.log("Tokens configurados correctamente");
```

 2. Depositar ETH

```javascript
// Depositar 1 ETH
const depositAmount = ethers.parseEther("1");

const tx = await bank.depositNative({ value: depositAmount });
await tx.wait();

console.log("1 ETH depositado exitosamente");

// Verificar balance
const balance = await bank.getMyVaultBalance(
  "0x0000000000000000000000000000000000000000" // NATIVE_TOKEN
);
console.log("Balance normalizado:", ethers.formatUnits(balance, 6));
```

 3. Depositar Tokens ERC-20

```javascript
const USDC = await ethers.getContractAt("IERC20", USDC_ADDRESS);

// Aprobar gasto
const depositAmount = ethers.parseUnits("1000", 6); // 1000 USDC
await USDC.approve(BANK_ADDRESS, depositAmount);

// Depositar
await bank.depositToken(USDC_ADDRESS, depositAmount);

console.log("1000 USDC depositados");

// Ver balance
const balance = await bank.getMyVaultBalance(USDC_ADDRESS);
console.log("Balance USDC:", ethers.formatUnits(balance, 6));
```

 4. Retirar Fondos

```javascript
// Retirar 0.5 ETH
const withdrawAmount = ethers.parseEther("0.5");

const tx = await bank.withdrawNative(withdrawAmount);
await tx.wait();

console.log("0.5 ETH retirados");

// Retirar 500 USDC
const usdcWithdraw = ethers.parseUnits("500", 6);
await bank.withdrawToken(USDC_ADDRESS, usdcWithdraw);

console.log("500 USDC retirados");
```

 5. Consultar Información

```javascript
// Valor total en USD del usuario
const totalValue = await bank.getUserTotalValueUSD(USER_ADDRESS);
console.log("Valor total USD:", ethers.formatUnits(totalValue, 6));

// Total depositado en el banco
const totalDeposits = await bank.getTotalDepositsUSD();
console.log("Total en banco:", ethers.formatUnits(totalDeposits, 6));

// Capacidad disponible
const available = await bank.getAvailableCapacityUSD();
console.log("Capacidad disponible:", ethers.formatUnits(available, 6));

// Precio actual de ETH
const ethPrice = await bank.getTokenPriceUSD(NATIVE_TOKEN);
console.log("Precio ETH:", ethers.formatUnits(ethPrice, 8));

// Tokens soportados
const tokens = await bank.getSupportedTokens();
console.log("Tokens disponibles:", tokens);

// Info de un token específico
const tokenInfo = await bank.getTokenInfo(USDC_ADDRESS);
console.log("USDC Info:", {
  supported: tokenInfo.isSupported,
  decimals: tokenInfo.decimals,
  priceFeed: tokenInfo.priceFeed,
  deposits: tokenInfo.depositCount.toString(),
  withdrawals: tokenInfo.withdrawalCount.toString()
});
```

 6. Funciones Administrativas

```javascript
// Pausar en emergencia
await bank.pause();
console.log("Contrato pausado");

// Reanudar operaciones
await bank.unpause();
console.log("Contrato reanudado");

// Remover token (deshabilitar)
await bank.removeToken(SOME_TOKEN_ADDRESS);

// Otorgar rol de operador
await bank.grantRole(
  ethers.keccak256(ethers.toUtf8Bytes("OPERATOR_ROLE")),
  OPERATOR_ADDRESS
);
```

7. Escuchar Eventos

```javascript
// Escuchar depósitos
bank.on("Deposit", (user, token, amount, normalizedAmount, newBalance) => {
  console.log(`Depósito detectado:
    Usuario: ${user}
    Token: ${token}
    Cantidad: ${ethers.formatUnits(amount, 18)}
    Balance nuevo: ${ethers.formatUnits(newBalance, 6)}
  `);
});

// Escuchar retiros
bank.on("Withdrawal", (user, token, amount, normalizedAmount, remaining) => {
  console.log(`Retiro detectado:
    Usuario: ${user}
    Token: ${token}
    Cantidad: ${ethers.formatUnits(amount, 18)}
    Balance restante: ${ethers.formatUnits(remaining, 6)}
  `);
});

// Escuchar cambios de tokens
bank.on("TokenAdded", (token, priceFeed, decimals) => {
  console.log(`Nuevo token agregado:
    Token: ${token}
    Price Feed: ${priceFeed}
    Decimales: ${decimals}
  `);
});
```

---

 Decisiones de Diseño

 1. ¿Por qué 6 decimales para contabilidad interna?

Decisión: Normalizar todos los balances a 6 decimales.

Razones:
- Estándar DeFi: USDC y USDT (las stablecoins más grandes) usan 6 decimales
- Balance: Suficiente precisión para valores monetarios sin desperdiciar gas
- Compatibilidad: Facilita integración con otros protocolos
- Prevención de errores: Un estándar claro evita confusiones

Alternativas Consideradas:
-  18 decimales: Desperdicio de gas para stablecoins
-  8 decimales: No alineado con principales stablecoins
-  Sin normalización: Complejidad innecesaria y propenso a errores

 2. ¿Por qué usar `address(0)` para ETH?

Decisión: Representar ETH nativo como `address(0)` en vez de crear un WETH wrapper interno.

Razones:
- Simplicidad: Los usuarios no necesitan wrap/unwrap
- Gas: Ahorra gas en cada transacción
- Convención: Patrón común en DeFi (Uniswap, Curve)
- UX: Más intuitivo para usuarios finales

Trade-offs:
- Necesita funciones separadas (`depositNative` vs `depositToken`)
- Lógica condicional en `_withdraw()`

3. ¿Por qué límites en USD en vez de tokens?

Decisión: `bankCapUSD` y `withdrawalThresholdUSD` denominados en dólares.

Razones:
- Previsibilidad: Los límites son estables independiente de volatilidad
- Compliance: Regulaciones financieras piensan en USD
- Comparabilidad: Fácil comparar diferentes tokens
- Reporting: Simplifica contabilidad y auditoría

Ejemplo del Problema:
```
Límite: 100 ETH

Día 1: ETH = $2,000 → Capacidad = $200,000
Día 2: ETH = $3,000 → Capacidad = $300,000 (¡50% más!)
Día 3: ETH = $1,500 → Capacidad = $150,000 (crash)

Límite: $200,000 USD

Día 1: ETH = $2,000 → Capacidad = 100 ETH
Día 2: ETH = $3,000 → Capacidad = 66.67 ETH (ajustado automáticamente)
Día 3: ETH = $1,500 → Capacidad = 133.33 ETH (ajustado automáticamente)
```

 4. ¿Por qué OpenZeppelin AccessControl vs Ownable?

Decisión: Usar `AccessControl` en vez de `Ownable2Step`.
Razones**:
- Multi-usuario: Varios admins/operadores simultáneos
- Granularidad: Permisos específicos por función
- Escalabilidad: Fácil agregar nuevos roles
- Auditabilidad: Eventos de cambios de roles

Trade-off:
- Más gas en deployment (~50k gas adicional)
- Mayor complejidad inicial

 5. ¿Por qué validar staleness de Chainlink?

Decisión: Rechazar precios con más de 1 hora de antigüedad.

Razones:
-Seguridad: Previene uso de precios obsoletos
- Protección de usuarios: Evita liquidaciones injustas
- Best practic: Recomendado por Chainlink

Validaciones Implementadas:
```solidity
// 1. Precio positivo
if (price <= 0) revert KipuBank__InvalidPrice();

// 2. Round completado
if (answeredInRound < roundId) revert KipuBank__StalePrice();

// 3. Actualización reciente
if (block.timestamp - updatedAt > 3600) revert KipuBank__StalePrice();
```
Casos de Borde:
- Oráculo pausado: Se revierte la transacción 
- Precio manipulado: Validación de round lo detecta 
- Network downtime: Staleness check protege 

 6. ¿Por qué ReentrancyGuard en todas las funciones críticas?

Decisión: Aplicar `nonReentrant` a `deposit` y `withdraw`.

Razones:
- Defense in depth: Aunque usamos CEI, agregamos capa extra
-Protección ERC-20: Algunos tokens pueden tener callbacks
- Costo bajo: ~2.3k gas, insignificante comparado con beneficio
