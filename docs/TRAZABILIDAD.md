# Matriz de trazabilidad — GG_LondonSweepFVG v1.00

Estados: **Implementado** (código escrito y auditado; pendiente de compilar y probar en MT5) · **Verificado (modelo)** (lógica comprobada con `tests/reference_model.py`) · **Fuera de alcance** (excluido con aprobación) · **Sustituido** (reemplazado por una decisión aprobada).

Las pruebas TP-xx están definidas en `docs/PRUEBAS_Y_VALIDACION.md`.

| ID | Regla original | Implementación | Función / sección | Prueba | Estado |
|---|---|---|---|---|---|
| R01 | Instrumento MNQ | CFD Nasdaq-100 del gráfico (D01) | `_Symbol` | TP-02 | Sustituido (Q1-b) |
| R02 | Sesión Londres (a veces NY) | Solo Londres | `ComputeSession`, `OnTick` | TP-11, TP-13 | Implementado |
| R03 | 08:00–11:00 Madrid (§11) | 09:00–11:00 Madrid para crear setups | `ComputeSession` | TP-13; modelo | Sustituido (P1) / Verificado (modelo) |
| R04 | Tendencia M15 o M30 | M15 | `ComputeSignal` | TP-03 | Implementado |
| R05 | Bajo EMA20 → ventas; sobre EMA20 → compras | Cierre shift 1 vs EMA20 shift 1 | `ComputeSignal` | TP-03 | Implementado |
| R06/R07 | "Diagonal" / pendiente EMA | Sin filtro de pendiente (Q4: solo posición vs EMA) | — | TP-03 | Sustituido (Q4) |
| R08 | Ejecución M5 | FVG y señal en M15 (Q5) | — | — | Sustituido (Q5) |
| R09 | Venta: máximo → barrida → imbalance → sell limit | FVG entero sobre el swing high + sell limit en su borde inferior | `ComputeSignal`, `TryPlaceSetup` | TP-04, TP-05, TP-06 | Implementado |
| R10 | Compra: simétrico | Ídem con swing low y buy limit | `ComputeSignal`, `TryPlaceSetup` | TP-04, TP-05, TP-06 | Implementado |
| R11 | Sin confirmación adicional | Ninguna condición extra | `TryPlaceSetup` | TP-06 | Implementado |
| R12 | Un único patrón | Un único patrón | — | revisión de código | Implementado |
| R13 | Sin nivel claro → no hay trade | Sin swing o sin FVG válido → sin setup (log) | `ComputeSignal`, `TryPlaceSetup` | TP-05 | Implementado |
| R14 | Nivel más cercano | Último swing confirmado + FVG más cercano al precio (T2) | `FindSwing*`, `TryPlaceSetup` | TP-06 | Implementado |
| R15 | Pivote K=3 en M15 | `InpPivotK` = 3, comparación estricta | `FindSwingHigh/Low` | TP-04 | Implementado |
| R16 | Definición FVG | `Low[a] > High[c]` / `High[a] < Low[c]` | `ComputeSignal` | TP-05 | Implementado |
| R17 | L1 en borde del FVG | Borde cercano (D09) | `BuildPlan` | TP-07; modelo | Verificado (modelo) |
| R18/R19 | L2 algo más lejos | Borde lejano + `InpLimit2Buffer` (P6) | `BuildPlan` | TP-07; modelo | Verificado (modelo) |
| R20/R21 | 3 + 3 MNQ | Volumen por riesgo, 50/50 (D08, P5) | `BuildPlan`, `NormalizeVolumeDown` | TP-07; modelo | Sustituido (Q8) / Verificado (modelo) |
| R22 | Una sola promediada | Exactamente 2 órdenes por día | `PlaceSetup`, `OnTick` paso 5 | TP-12 | Implementado |
| R23 | −800 → cerrar todo y cancelar | SL en servidor a riesgo total ≤ 800; tras una salida, `FlattenAll` | `BuildPlan`, `OnTick` paso 3 | TP-10, TP-08 | Implementado / Verificado (modelo) |
| R24 | +500 → cerrar todo y cancelar | TP1/TP2 en servidor; TP1→TP2 al llenar L2 | `BuildPlan`, `ManageOpenPositions` | TP-08, TP-09 | Implementado / Verificado (modelo) |
| R25 | Backtest SL 1000 / TP 400 | Configurable; se usa 800/500 (Q11) | inputs | TP-19 | Sustituido (Q11) |
| R26 | 1 operación por día | 1 setup por día de Madrid | `RefreshDayState`, `OnTick` paso 5 | TP-12 | Implementado |
| R27 | Sin llenado → cancelar al acabar la sesión | Cancelación en la llegada de NY (D07) + expiración en servidor | `OnTick` paso 1, `PlaceSetup` | TP-11 | Implementado |
| R28 | Calibración por racha | Registro de racha de días en pérdida (P9) | `MaybeLogDailySummary` | TP-21 | Implementado (solo registro) |
| R29 | Límite de pérdida propio siempre | SL en servidor en cada orden desde su colocación | `PlaceSetup` | TP-07 | Implementado |
| R30 | Consistencia ~50 % | Registro del mejor día / beneficio total (P9) | `LogConsistency` | TP-21 | Implementado (solo registro) |
| R31 | Copiador 20 cuentas | — | — | — | Fuera de alcance (Q2) |
| R32 | Días mínimos | — | — | — | Fuera de alcance |
| D07 | Cancelar pendientes solo en NY | No se cancelan por cambio de sesgo ni nuevo setup | `OnTick` | TP-11 | Implementado |
| D10/P1 | Cierre total en la llegada de NY (09:30 NY) | `!inWindow` → `RequestFlatten` | `OnTick` paso 1 | TP-11; modelo | Verificado (modelo) |
| P2 | Servidor GMT+2/+3 DST EE. UU. | Inputs `InpServerGmtOffsetWinter`, `InpServerDst` | `ServerToUtc` | TP-02 | Implementado (verificar con el bróker) |
| P7 | Comisión en el volumen | `4 × InpCommissionPerLotSide` por lote | `BuildPlan` | modelo | Verificado (modelo) |
| P8 | Spread máximo | `InpMaxSpread` (0 = off) | `TryPlaceSetup` | TP-14 | Implementado |
| T3 | Limit inválida → descartar FVG | Filtro vs Bid/Ask + stops level | `TryPlaceSetup`, `BuildPlan` | TP-06 | Implementado |
| T4 | Solo velas cerradas | `CopyRates(..., 1, ...)`, `CopyBuffer(..., 1, 1, ...)` | `ComputeSignal` | TP-03 | Implementado |
| T5 | Recuperación tras reinicio | Estado desde órdenes/posiciones/historial + variables globales | `RefreshDayState`, `HasStaleItems` | TP-15, TP-16 | Implementado |
| T6 | Netting y hedging | Gestión por ticket; TP aplicado a todas las posiciones del EA | `ManageOpenPositions` | TP-18 | Implementado |
| T7 | Rechazo → cancelar la otra y terminar el día | `FlattenAll` + `BlockDay` | `PlaceSetup` | TP-17 | Implementado |
| — | SL debe quedar más allá de L2 | FVG demasiado ancho → setup descartado | `BuildPlan` | modelo | Verificado (modelo) |
