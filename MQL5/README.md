# NASDAQ Accumulation EA (MetaTrader 5)

Expert Advisor en MQL5 nativo que opera la ruptura de la **acumulación 09:00–09:30 (hora de Nueva York)** en el NASDAQ 100, timeframe M5, con **una sola operación por día**.

Archivo: [`Experts/NasdaqAccumulationEA.mq5`](Experts/NasdaqAccumulationEA.mq5)

> **Importante:** el código se revisó a mano y la conversión horaria se verificó contra la base de datos de zonas horarias IANA (2015–2026, 0 errores), pero **no se pudo compilar en este entorno** porque MetaEditor no está disponible. Compílalo con F7 en MetaEditor antes de usarlo y comparte cualquier error o warning que aparezca.

---

## 1. Cómo funciona

| Hora NY | Fase | Qué hace el EA |
|---|---|---|
| 00:00 | Nuevo día | Detecta el cambio de fecha **en hora de Nueva York**, reinicia el estado, el contador de operaciones y los dibujos, y guarda el equity inicial del día. |
| 09:00–09:30 | `BUILDING ACCUMULATION` | Dibuja en vivo el rectángulo con el máximo y el mínimo de las velas M5. |
| 09:30 | Validación | Con las 6 velas cerradas (09:00…09:25) calcula `High`, `Low` y `Range`. Si `Range > MaxAccumulationPoints`, registra `INVALID_RANGE` y no opera ese día. Si falta alguna vela, registra `ACCUMULATION_INCOMPLETE`. |
| 09:30 → `End` | `WAITING BREAKOUT` | En cada vela M5 cerrada: si **cierra por encima del máximo** → señal LONG; si **cierra por debajo del mínimo** → señal SHORT. |
| Señal | Ejecución | Pasa los 10 filtros de seguridad y abre a mercado con SL y TP en la misma orden. Después verifica la posición y ajusta el TP al precio real de ejecución. |
| Tras la entrada | `DONE FOR TODAY` | El día queda **bloqueado**: no hay segunda entrada, reentrada tras SL, add-on, grid ni martingala. |
| `End` sin ruptura | `NO TRADE TODAY` | Registra `NO_VALID_BREAKOUT`. |

**Stop Loss:** LONG → `Low − SL_Buffer_Points`; SHORT → `High + SL_Buffer_Points`. Se redondea al tick, alejándose del precio.

**Take Profit:** `entrada ± RiskReward × |entrada − SL|`, usando la distancia real (Ask para LONG, Bid para SHORT, así que incluye el spread). Se redondea de forma que el R:R nunca quede por debajo del configurado. Tras la ejecución se recalcula con el precio de fill.

**Lotaje:**

```
riesgo        = min(equity actual, equity al inicio del día NY) × RiskPercent / 100
pérdidaPorLote = max( distancia / TICK_SIZE × TICK_VALUE_LOSS ,  |OrderCalcProfit(1 lote, entrada → SL)| )
lotes         = floor( riesgo / pérdidaPorLote / VOLUME_STEP ) × VOLUME_STEP
```

- Se toma el **mayor** de los dos métodos de cálculo, así que es conservador. Ambos tienen en cuenta el tamaño del contrato y la conversión de divisa del broker.
- Se redondea **hacia abajo**. Si el resultado queda por debajo del volumen mínimo **no se opera**, porque redondear hacia arriba superaría el riesgo (`INVALID_LOT_SIZE`).
- Si supera `VOLUME_MAX` o `VOLUME_LIMIT`, tampoco se opera (`INVALID_LOT_SIZE`).

### Filtros antes de cada entrada (`CheckRiskConditions`)

1. Hora dentro de `[AccumEnd, End)` → si no, `OUTSIDE_SESSION`
2. Acumulación formada → si no, `ACCUMULATION_NOT_READY` / `ACCUMULATION_INCOMPLETE`
3. Rango ≤ máximo → si no, `INVALID_RANGE`
4. Ninguna operación hoy y límite diario sin alcanzar → si no, `ALREADY_TRADED` / `DAILY_LIMIT_REACHED`
5. Ninguna posición del EA abierta (en cuentas *netting*, ninguna posición en el símbolo) → si no, `POSITION_EXISTS`
6. Spread ≤ `MaxSpreadPoints` → si no, `SPREAD_TOO_HIGH`
7. SL y TP válidos (lado correcto y *stops level* del broker) → si no, `INVALID_SL` / `INVALID_TP`
8. Lotaje válido → si no, `INVALID_LOT_SIZE`
9. Margen suficiente (`OrderCalcMargin` + `OrderCheck`) → si no, `INSUFFICIENT_MARGIN` / `ORDER_CHECK_FAILED`
10. La vela de señal cerró fuera de la zona en la dirección de la orden → si no, `NO_VALID_BREAKOUT`

Si **cualquiera** falla, la orden no se envía.

---

## 2. Parámetros

Todas las distancias en "puntos" (`MaxAccumulationPoints`, `SL_Buffer_Points`, `MaxSpreadPoints`, `Slippage`) usan la unidad elegida en `PointUnit`.

| Parámetro | Defecto | Descripción |
|---|---|---|
| `SignalTimeframe` | M5 | Timeframe de las velas de acumulación y de ruptura (no depende del gráfico). |
| `StartHour` / `StartMinute` | 09:00 | Inicio de la acumulación y de la sesión (hora NY). |
| `AccumEndHour` / `AccumEndMinute` | 09:30 | Fin de la acumulación; desde aquí se busca la ruptura. |
| `EndHour` / `EndMinute` | 12:00 | Última hora a la que puede abrirse una operación. **La especificación no lo indicaba: es un valor por defecto elegido por mí, ajústalo.** |
| `ServerGMTOffset` | 2 | Offset GMT del servidor del broker **en invierno**. |
| `ServerDSTMode` | US | Horario de verano que aplica el servidor: Ninguno / EE.UU. / Europa. |
| `PointUnit` | Puntos de índice | `Puntos de índice`: 1 punto = 1.0 de precio (40 pts = 18000 → 18040). `Puntos MT5`: 1 punto = `_Point`. |
| `MaxAccumulationPoints` | 40 | Rango máximo de la acumulación. Si se supera, no se opera ese día. |
| `SL_Buffer_Points` | 1.0 | Distancia extra del SL por fuera del extremo de la acumulación. |
| `RiskReward` | 2.0 | Relación beneficio/riesgo del TP (2.0 = 1:2). |
| `RiskPercent` | 10.0 | % del equity arriesgado en la operación (riesgo monetario hasta el SL, no tamaño nominal). |
| `MaxSpreadPoints` | 3.0 | Spread máximo permitido para entrar. |
| `MagicNumber` | 930900 | Identificador de las operaciones del EA. Usa uno distinto por gráfico o instancia. |
| `Slippage` | 3.0 | Desviación máxima de precio aceptada al ejecutar. |
| `DrawObjects` | true | Dibuja el rectángulo, el máximo y el mínimo, la entrada, el SL, el TP, la señal y el resultado. |
| `ShowPanel` | true | Panel informativo. |
| `KeepPreviousDrawings` | false | `false`: borra los dibujos del día anterior al cambiar de día. |
| `WriteCSVLog` | true | Guarda el registro en `Common\Files\<CSVFileName>`. Se desactiva solo durante la optimización. |
| `CSVFileName` | `NasdaqAccumulationEA_log.csv` | Nombre del CSV. |

`MAX_TRADES_PER_DAY = 1` es una constante en el código, **no un input**, para que no se pueda cambiar por error.

### Cómo saber `ServerGMTOffset` y `ServerDSTMode`

- La mayoría de brokers de CFDs (servidores *"NY close"*) usan **GMT+2 en invierno y GMT+3 en verano siguiendo el DST de EE.UU.** En ellos la hora del servidor es siempre la de NY + 7, y es la configuración por defecto: `2` + `US`.
- Comprobación rápida: en el gráfico M5 la apertura del mercado de contado (09:30 NY), con su pico de volatilidad, debe aparecer a las **16:30** de la hora del servidor.
- En cuenta real o demo, el EA compara la configuración con el offset real (`TimeTradeServer() − TimeGMT()`) y lanza un `Alert` si no coinciden.
- En el Strategy Tester `TimeGMT()` no es fiable, por eso el EA usa siempre la configuración manual.

---

## 3. Instalación

1. En MT5: **Archivo → Abrir carpeta de datos**.
2. Copia `NasdaqAccumulationEA.mq5` en `MQL5\Experts\`.
3. Abre MetaEditor (F4), abre el archivo y compílalo (**F7**). Debe terminar con `0 errors`.
4. En MT5, en el Navegador, pulsa clic derecho en *Asesores Expertos* → **Actualizar**.
5. Abre un gráfico **M5** del NASDAQ 100 de tu broker (`NAS100`, `US100`, `USTEC`, `NDX`…).
6. Arrastra el EA, revisa los inputs (sobre todo la zona horaria y `PointUnit`) y activa **Trading algorítmico**.
7. Revisa la pestaña **Expertos**. El EA imprime las especificaciones del símbolo, la conversión servidor → NY y cualquier advertencia.

---

## 4. Backtest en el Strategy Tester

1. **Ver → Probador de estrategias** (Ctrl+R).
2. Experto: `NasdaqAccumulationEA`. Símbolo: el NASDAQ de tu broker. Periodo: **M5**.
3. Modelado: **"Cada tick basado en ticks reales"** (recomendado; usa el spread real para el filtro). "1 minuto OHLC" sirve para pruebas rápidas.
4. Fechas: al menos 1–2 años. Depósito y apalancamiento iguales a los de tu cuenta.
5. En *Parámetros*, configura `ServerGMTOffset` y `ServerDSTMode` del broker cuyos datos estás usando.
6. Activa **Visualización** para ver el rectángulo, los niveles y el panel. Sin visualización no se dibuja nada, lo que acelera el test.
7. Al terminar:
   - Pestaña **Diario**: líneas `[NAE] … TRADE_OPEN / TRADE_CLOSE / NO_TRADE` con el motivo de cada día.
   - CSV en `…\Terminal\Common\Files\NasdaqAccumulationEA_log.csv` (separador `;`). Borra el CSV entre tests si quieres un registro limpio, porque el EA añade al final del archivo.
8. Optimización: se pueden optimizar `MaxAccumulationPoints`, `SL_Buffer_Points`, `RiskReward`, `MaxSpreadPoints`, `EndHour` y `RiskPercent`. Los parámetros incoherentes devuelven `INIT_PARAMETERS_INCORRECT` y esa pasada se descarta.

**Formato del registro (CSV/Journal):** `Date; TimeNY; ServerTime; Symbol; Event; Direction; Entry; StopLoss; TakeProfit; RangePts; Lots; RiskMoney; Result; PnL; Reason`

---

## 5. Casos extremos contemplados

| Caso | Comportamiento |
|---|---|
| Cambio de horario de verano (EE.UU., Europa y las semanas en que no coinciden) | La conversión servidor → UTC → NY se calcula para cada fecha con las reglas oficiales. |
| Fines de semana (las ticks del domingo por la tarde en NY) | El día se marca `WEEKEND`, sin registro ni operación. |
| Festivos o huecos de datos dentro de 09:00–09:30 | `ACCUMULATION_INCOMPLETE` (se exigen todas las velas). |
| Historial M5 aún sincronizando a las 09:30 | Reintenta durante la primera vela; después bloquea el día. |
| Spread alto en la vela de ruptura | Reintenta tick a tick **solo durante la vela siguiente**. Si no se normaliza, `SPREAD_TOO_HIGH` y el día se bloquea. |
| Reinicio del EA o de MT5 a mitad del día | Reconstruye la acumulación desde el historial y cuenta las operaciones del día desde los *deals* del magic. Si la ruptura ocurrió mientras el EA estaba apagado → `BREAKOUT_MISSED` (no entra tarde). |
| Respuesta de `OrderSend` perdida o timeout | Antes de reintentar comprueba posiciones e historial, así que no hay orden duplicada. Además `OnTradeTransaction` bloquea el día en cuanto llega el *deal* de entrada. |
| Requote o cambio de precio | Hasta 3 intentos dentro de la vela; los errores no transitorios (stops inválidos, volumen, sin dinero) bloquean el día. |
| Broker que no acepta SL/TP en la orden | Se colocan con `PositionModify`. Si el SL no puede colocarse tras 3 intentos, **la posición se cierra** por seguridad. |
| Deslizamiento al ejecutar | El TP se recalcula con el precio real. El riesgo real se registra y está acotado por `Slippage`. |
| Cuenta *netting* con otra posición en el símbolo | No opera (`POSITION_EXISTS`), para no fusionar posiciones. |
| Posición del día anterior todavía abierta | Bloquea la nueva entrada (`POSITION_EXISTS`). |
| Lotaje por debajo del mínimo (cuenta pequeña o SL muy amplio) | No opera; nunca redondea hacia arriba. |
| Símbolo con `TICK_VALUE` 0 en el tester | Usa `OrderCalcProfit` como alternativa (y siempre el mayor de los dos). |
| Ruptura en la última vela (cierra a la hora `End`) | `OUTSIDE_SESSION`. |
| Varias instancias del EA | Los objetos y registros se separan por `MagicNumber`. |
| Cierre manual de la posición | Se detecta por ID de posición; se registra el resultado y no se reabre. |

---

## 6. Revisión final

**Conversión horaria.** Se portó 1:1 a Python y se comparó con `zoneinfo` (`America/New_York`, `Europe/Athens`) en 2015–2026 para los modos US, EU y sin DST: 0 discrepancias. Con GMT+2/US, 09:00 NY = 16:00 del servidor todo el año.

**Riesgo y lotaje.**
- El riesgo se calcula con la distancia entrada → SL e incluye el spread.
- El lote se redondea siempre hacia abajo, así que el riesgo monetario es ≤ `RiskPercent`.
- La base es `min(equity actual, equity del inicio del día)`, de modo que nunca se aumenta el riesgo tras una pérdida.
- No hay ninguna lógica que dependa del resultado anterior (sin martingala).

**SL/TP.** El SL está siempre al otro lado de la zona más el buffer. Se valida que el SL esté en el lado correcto y respete el *stops level*. El TP es exactamente `RiskReward` × riesgo, recalculado tras el fill.

**Ruptura.** Solo cuentan velas **cerradas** con apertura ≥ 09:30 NY. Cada vela se evalúa una sola vez (`g_lastCheckedBar`) y solo la primera ruptura del día es válida.

**Una operación diaria y sin duplicados.** Hay cinco barreras independientes:
1. `g_dayLocked` se activa en cuanto se envía la orden.
2. `g_tradesToday` se reconstruye desde el historial.
3. `OnTradeTransaction` bloquea el día al recibir el `DEAL_ENTRY_IN`.
4. Se comprueba la posición abierta antes de cada envío.
5. Se verifica el historial tras cualquier error de envío.

`MAX_TRADES_PER_DAY` no es configurable.

**Reinicio diario.** Se basa en la fecha de NY, no en la del servidor. Reinicia todas las variables de estado y recalcula las horas del servidor de la nueva fecha (cambian con el DST).

**Especificaciones del símbolo.** Usa `TICK_SIZE`, `TICK_VALUE_LOSS`, `VOLUME_MIN`, `VOLUME_MAX`, `VOLUME_STEP`, `VOLUME_LIMIT`, `STOPS_LEVEL`, el modo de *filling* y el modo hedging/netting. Al iniciar imprime todos estos valores en el Journal para que puedas comprobarlos.

**Limitaciones conocidas:**
- El EA no se compiló en este entorno.
- `EndHour = 12:00` es una suposición mía.
- Las posiciones **no se cierran** al final de la sesión (no estaba en las reglas): una operación puede quedar abierta durante la noche hasta tocar el SL o el TP.
- Con `RiskPercent = 10` y la base en equity, un deslizamiento adverso puede hacer que el riesgo real supere el 10% por una fracción pequeña (la desviación máxima es `Slippage`).

---

## 7. Mejoras propuestas (no implementadas; serían opciones independientes)

1. **Cierre forzado por hora** (`CloseAtHour`), para no mantener posiciones overnight ni pagar swap ni sufrir gaps.
2. **Riesgo con deslizamiento incluido**: calcular el lote con `entrada ± Slippage` para garantizar que el riesgo nunca supere el 10%.
3. **Filtro de festivos de EE.UU.** y de medias sesiones (por ejemplo, el día después de Acción de Gracias).
4. **Filtro de días con noticias** de alto impacto (CPI, FOMC, NFP).
5. **Rango mínimo de acumulación**: con rangos muy pequeños, el lote para un 10% de riesgo es enorme y el ruido puede activar el SL.
6. **Riesgo más bajo**: un 10% por operación implica que 5 pérdidas seguidas reducen la cuenta un ~41%. Conviene probar 0.5–2% en el backtest.
