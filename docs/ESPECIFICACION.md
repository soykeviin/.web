# Especificación técnica definitiva — GG_LondonSweepFVG v1.10

Fuente: `estrategia_gerard_garcia_apex.md` (resumen del vídeo de Gerard García, "Retirar $75.000 de Apex en 1 mes").
Estado: **aprobada** por el usuario (Q1–Q15 y P1–P9).

Etiquetas: **[EXP]** explícito en el documento · **[AUT]** propuesta del autor del resumen (§11) · **[APR]** decisión aprobada por el usuario · **[DED]** deducción técnica aprobada.

---

## 1. Resumen del análisis (Etapa A)

- El documento resume una estrategia **discrecional**; la única versión mecánica (§11) es una propuesta del autor del resumen, aceptada como base (Q15).
- El vídeo opera **MNQ** (futuro CME) en TopstepX con copia a cuentas Apex. El usuario decide implementarla en **MT5 con un CFD del Nasdaq-100 en VT Markets** (Q1-b). Esto **cambia el instrumento**: el riesgo se fija en dinero (no en contratos), por lo que la equivalencia es directa en USD.
- Elementos fuera de alcance (aprobado): copiador a 20 cuentas (§7), "días mínimos" discrecionales (§9), calibración manual del riesgo según la racha (§6, solo se registra).

## 2. Decisiones aprobadas

| ID | Decisión | Origen |
|---|---|---|
| D01 | MT5 con CFD del Nasdaq-100 (símbolo del gráfico) | Q1 |
| D02 | Una sola cuenta | Q2 |
| D03 | Solo la ventana de Londres | Q3 |
| D04 | Sesgo en M15: cierre de la última vela cerrada > EMA20 → compras; < EMA20 → ventas; se reevalúa en cada vela M15 | Q4 |
| D05 | FVG de M15, situado más allá del swing (encima del máximo para ventas, debajo del mínimo para compras), formado en las últimas 3 horas; ninguna otra condición | Q5 |
| D06 | Las limits se colocan en cuanto existe el setup | Q6 |
| D07 | Las pendientes solo se cancelan en la llegada de NY sin activarse | Q7 |
| D08 | El volumen se adapta a un riesgo máximo total de 800 USD | Q8 |
| D09 | L1 en el borde cercano del FVG; L2 más allá del FVG | Q9 |
| D10 | Cerrar todas las operaciones al acabar la sesión | Q10 |
| D11 | SL −800 USD, TP +500 USD (totales) | Q11 |
| D12 | SL/TP reales en el servidor | Q12-B |
| D13 | Se adopta §11 como base (swing M15 K=3, 1 setup/día, sin martingala ni grid) | Q15 |
| P1 | Ventana desde 09:00 Madrid; setups solo hasta 11:00 Madrid; llegada de NY = 09:30 hora de NY (con su DST); fin de sesión = llegada de NY | P1 |
| P2 | Bróker VT Markets: servidor GMT+2 en invierno / GMT+3 en verano con DST de EE. UU. (**a verificar**, ver README) | P2 |
| P3 | FVG de cualquier dirección (alcista o bajista); el límite de 3 h aplica al FVG; el swing es el último pivote confirmado | P3 |
| P4 | SL a 66,7 puntos del precio medio de L1/L2 (equivalente al ejemplo del §11: 6 MNQ × 2 $/pt, −800 $) | P4 |
| P5 | Volumen 50 % / 50 % entre L1 y L2 | P5 |
| P6 | ~~L2 exactamente en el borde lejano del FVG~~ → sustituido por D15 | P6 |
| P7 | La comisión entra en el cálculo del volumen (por defecto 0) | P7 |
| P8 | Filtro de spread máximo disponible, desactivado por defecto | P8 |
| P9 | Racha de días en pérdida y consistencia 50 %: solo registro, sin bloqueo | P9 |
| D14 | **(v1.10)** El sesgo exige además la pendiente de la EMA20: compras solo si la EMA de la última vela cerrada es mayor que la de hace N velas M15 (ventas: menor). N = 3 por defecto (`InpEmaSlopeBars`). Motivo: el sesgo solo por posición frente a la EMA producía compras en retrocesos de un escenario bajista | Revisión del usuario tras el simulador |
| D15 | **(v1.10)** L2 se coloca más allá del borde lejano del FVG a un 50 % de su altura (`InpLimit2FvgPct`); sustituye a P6 | Revisión del usuario tras el simulador |

Deducciones técnicas aprobadas: T1 FVG entero más allá del swing · T2 FVG más cercano al precio · T3 se descarta un FVG si la limit sería inválida · T4 solo velas cerradas · T5 recuperación por número mágico/historial · T6 netting y hedging · T7 si el servidor rechaza una orden, se cancela la otra y el día termina.

## 3. Reglas lógicas

```text
VENTANA (hora de Madrid, lunes–viernes)
  activa      ⇔ 09:00 Madrid ≤ t < 09:30 Nueva York
  crear setup ⇔ 09:00 Madrid ≤ t < 11:00 Madrid (y antes de 09:30 NY)

SESGO (M15, vela cerrada shift 1)
  +1 ⇔ Close > EMA20[1] ∧ EMA20[1] > EMA20[1+N]
  −1 ⇔ Close < EMA20[1] ∧ EMA20[1] < EMA20[1+N]      (N = 3)
   0 en otro caso → no operar

SWING (M15, velas cerradas, K = 3)
  ventas : último High[i] > High[i±1..K]
  compras: último Low[i]  < Low[i±1..K]

FVG (M15; velas a = i+2, c = i; formado al cierre de c; edad ≤ 3 h)
  bajista: Low[a] > High[c] → zona [High[c], Low[a]]
  alcista: High[a] < Low[c] → zona [High[a], Low[c]]
  válido para ventas : zona.low  > swing high
  válido para compras: zona.high < swing low

SELECCIÓN (cada tick hasta colocar)
  ventas : FVG con L1 = zona.low  > Bid + stops level, el de L1 mínimo
  compras: FVG con L1 = zona.high < Ask − stops level, el de L1 máximo

PLAN (ventas; compras simétrico)
  L1 = zona.low ; L2 = zona.high + 50 % · (zona.high − zona.low) ; medio = (L1+L2)/2
  SL = medio + 66,7  (mismo SL en ambas órdenes; exige SL > L2 → FVG de hasta ~88 puntos)
  v  = 800 / (pérdida_1lote(L1→SL) + pérdida_1lote(L2→SL) + 4·comisión)  → hacia abajo al paso de lote
  TP1 = L1 − 500 / (v · valor_punto)         (TP de L1 mientras L2 está pendiente)
  TP2 = medio − 500 / (2v · valor_punto)     (TP de L2 y, al llenarse L2, también de L1)

SALIDA
  SL o TP en el servidor → al detectar la salida: cerrar resto + cancelar pendientes → día terminado
  09:30 NY → cancelar pendientes + cerrar posiciones → día terminado
  Máximo 1 setup por día de Madrid
```

## 4. Arquitectura del EA (un único archivo `.mq5`)

| Módulo | Funciones | Responsabilidad |
|---|---|---|
| Inicialización y validación | `OnInit`, `ValidateInputs`, `LogConfiguration` | Validar inputs, propiedades del símbolo (limit + SL + TP), crear la EMA, configurar `CTrade` |
| Tiempo | `ComputeSession`, `IsUsDst`, `IsEuDst`, `ServerToUtc`, `UtcToServer` | Servidor ↔ UTC ↔ Madrid / Nueva York sin depender de `TimeGMT()` |
| Señal | `ComputeSignal`, `FindSwingHigh`, `FindSwingLow` | Sesgo EMA20, último swing, FVG válidos (una vez por vela M15 cerrada) |
| Riesgo y plan | `BuildPlan`, `NormalizeVolumeDown`, `RoundToTick`/`FloorToTick`/`CeilToTick`, `MinStopDistance` | Precios y volumen normalizados; `OrderCalcProfit` y `OrderCalcMargin` |
| Envío | `TryPlaceSetup`, `PlaceSetup`, `TradingPermitted` | Selección del FVG, colocación de L1 y L2, verificación de retcodes |
| Gestión | `ManageOpenPositions` | TP1 → TP2 al llenarse L2; reposición de SL/TP; cierre si el nivel ya se superó |
| Salidas y límites | `FlattenAll`, `RequestFlatten`, flujo de `OnTick` | Cierre total, corte de NY, 1 setup/día |
| Estado y recuperación | `RefreshDayState`, `HasStaleItems`, `BlockDay`, variables globales del terminal | Reconstrucción del día desde órdenes, posiciones e historial |
| Registro | `Log`, `LogOncePerBar`, `MaybeLogDailySummary`, `LogConsistency` | Motivo de cada acción, resumen diario, racha y consistencia |
| Finalización | `OnDeinit` | Libera la EMA; no toca órdenes (siguen protegidas en el servidor) |

**Interacción:** `OnTradeTransaction` marca el estado como "sucio" → el siguiente `OnTick` reconstruye el día desde el terminal (`RefreshDayState`) → `OnTick` aplica, en orden de prioridad: fuera de ventana → restos de días anteriores → salida ya ocurrida → gestión de posición → espera de llenado / día usado → búsqueda de setup. Así el comportamiento no depende de variables en memoria y es idéntico tras un reinicio.

**Prioridades cuando coinciden condiciones:** (1) llegada de NY / fuera de ventana, (2) restos de días anteriores, (3) salida SL/TP ya ocurrida, (4) gestión de posición abierta, (5) nuevo setup.

## 5. Parámetros (valores por defecto = especificación aprobada)

| Input | Defecto | Origen |
|---|---|---|
| `InpRiskMoney` | 800 | D08/D11 |
| `InpTakeProfitMoney` | 500 | D11 |
| `InpSlDistance` | 66,7 | P4 |
| `InpCommissionPerLotSide` | 0 | P7 (introducir la comisión real de la cuenta) |
| `InpEmaPeriod` | 20 | R05 |
| `InpEmaSlopeBars` | 3 | D14 |
| `InpPivotK` | 3 | §11 |
| `InpSwingLookbackBars` | 200 | Técnico (límite de búsqueda) |
| `InpFvgMaxAgeHours` | 3 | D05 |
| `InpLimit2FvgPct` | 50 | D15 |
| `InpStartHourMadrid:Minute` | 09:00 | P1 |
| `InpSetupEndHourMadrid:Minute` | 11:00 | P1/§11 |
| `InpNyCutoffHour:Minute` | 09:30 (NY) | P1 |
| `InpServerGmtOffsetWinter` | 2 | P2 (verificar) |
| `InpServerDst` | EE. UU. | P2 (verificar) |
| `InpMaxSpread` | 0 (desactivado) | P8 |
| `InpDeviationPoints` | 50 | Técnico (cierres a mercado) |
| `InpMagic` | 20261010 | Técnico |
