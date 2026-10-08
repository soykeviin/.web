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
| 09:30 | Validación | Busca la **acumulación**: el bloque de velas **consecutivas** que termina en la vela de 09:25. Cada vela debe solapar su **cuerpo** (apertura/cierre, sin mechas) con la zona que forman las siguientes, y el rango total no puede superar `MaxAccumulationPoints`. Es válida si: (1) tiene al menos `MinAccumCandles` velas (4); (2) al menos `MinTouches` velas tocan el techo y otras tantas el suelo (mecha incluida, dentro de la franja `TouchZonePercent`); y (3) el precio **rebota** de un borde al otro al menos `MinRebounds` veces. Una tendencia toca ambos bordes, pero solo cambia de lado una vez. Motivos de rechazo: `INVALID_RANGE`, `ACCUMULATION_TOO_SHORT`, `NOT_ENOUGH_REBOUNDS` o, si falta alguna vela, `ACCUMULATION_INCOMPLETE`. |
| 09:30 → `End` | `WAITING BREAKOUT` | **Tick a tick, sin esperar el cierre de la vela:** en cuanto el precio supera el máximo (al menos 1 tick) → LONG; en cuanto perfora el mínimo → SHORT. Puede ocurrir ya dentro de la vela de 09:30. |
| Ruptura | Ejecución | En ese mismo tick pasa los 10 filtros de seguridad y abre a mercado con SL y TP en la misma orden. Después verifica la posición y ajusta el TP al precio real de ejecución. |
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
3. Rango ≤ máximo y rebotes suficientes → si no, `INVALID_RANGE` / `NOT_ENOUGH_REBOUNDS`
4. Ninguna operación hoy y límite diario sin alcanzar → si no, `ALREADY_TRADED` / `DAILY_LIMIT_REACHED`
5. Ninguna posición del EA abierta (en cuentas *netting*, ninguna posición en el símbolo) → si no, `POSITION_EXISTS`
6. Spread ≤ `MaxSpreadPoints` → si no, `SPREAD_TOO_HIGH`
7. SL y TP válidos (lado correcto y *stops level* del broker) → si no, `INVALID_SL` / `INVALID_TP`
8. Lotaje válido → si no, `INVALID_LOT_SIZE`
9. Margen suficiente (`OrderCalcMargin` + `OrderCheck`) → si no, `INSUFFICIENT_MARGIN` / `ORDER_CHECK_FAILED`
10. El precio sigue fuera de la zona en la dirección de la orden → si no, `PRICE_BACK_INSIDE`

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
| `MaxAccumulationPoints` | 120 | Rango máximo de la acumulación. Si se supera, no se opera ese día. (Subido de 40 a 120: con el NASDAQ en ~30 000, 40 puntos invalidaba casi todos los días.) |
| `UseCandleBodies` | true | `true`: la zona se mide con los **cuerpos** de las velas (apertura/cierre), sin mechas. `false`: con máximos y mínimos completos. |
| `MinAccumCandles` | 4 | Mínimo de velas consecutivas que forman la acumulación (máximo 6 con la ventana 09:00–09:30 en M5). |
| `MinTouches` | 2 | Mínimo de velas que tocan el techo **y** mínimo que tocan el suelo. `0` desactiva el filtro. |
| `MinRebounds` | 2 | Mínimo de veces que el precio pasa de un borde al otro (p. ej. techo → suelo → techo = 2). Una vela que toca ambos bordes cuenta en el orden de su dirección. `0` desactiva el filtro. |
| `TouchZonePercent` | 20 | Franja de toque: una vela toca el techo si su máximo (mecha incluida) llega a menos del X% del rango del borde superior; igual para el suelo. |
| `SL_Buffer_Points` | 1.0 | Distancia extra del SL por fuera del extremo de la acumulación. |
| `RiskReward` | 2.0 | Relación beneficio/riesgo del TP (2.0 = 1:2). |
| `RiskPercent` | 10.0 | % del equity arriesgado en la operación (riesgo monetario hasta el SL, no tamaño nominal). |
| `MaxSpreadPoints` | 3.0 | Spread máximo permitido para entrar. |
| `AdjustLotToLimits` | false | `false`: si el lote para arriesgar `RiskPercent` supera el máximo del broker o el margen libre, no opera (regla original). `true`: reduce el lote al máximo que permiten el broker y el margen, y opera con **menos** riesgo del configurado (nunca más). |
| `MagicNumber` | 930900 | Identificador de las operaciones del EA. Usa uno distinto por gráfico o instancia. |
| `Slippage` | 3.0 | Desviación máxima de precio aceptada al ejecutar. |
| `DrawObjects` | true | Dibuja el rectángulo, el máximo y el mínimo, la entrada, el SL, el TP, la señal y el resultado. |
| `ShowPanel` | true | Panel informativo. |
| `KeepPreviousDrawings` | false | `false`: borra los dibujos del día anterior al cambiar de día. Pon `true` para revisar todas las acumulaciones al terminar un backtest visual. |
| `AccumBoxColor` / `InvalidBoxColor` / `AccumBorderColor` | marrón claro / gris / gris oscuro | Colores del **cuadro de acumulación**: relleno si es válida, relleno si no lo es, y borde. |
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
3. Modelado: **"Cada tick basado en ticks reales"**. Es imprescindible, porque la entrada es intravela: el precio exacto de la ruptura y el spread real determinan la entrada y el lotaje. "1 minuto OHLC" solo sirve como aproximación rápida. **No uses "Solo precios de apertura"**: no simula la ruptura dentro de la vela.
4. Fechas: al menos 1–2 años. Depósito y apalancamiento iguales a los de tu cuenta.
5. En *Parámetros*, configura `ServerGMTOffset` y `ServerDSTMode` del broker cuyos datos estás usando.
6. Activa **Visualización** para ver el cuadro de acumulación, los niveles y el panel. **Sin visualización no se dibuja nada**, lo que acelera el test. El cuadro se dibuja sobre las velas que forman la acumulación (de la primera a las 09:30 NY), con una etiqueta que indica el número de velas, el rango y los rebotes.
7. Al terminar:
   - Pestaña **Diario**: líneas `[NAE] … TRADE_OPEN / TRADE_CLOSE / NO_TRADE` con el motivo de cada día.
   - CSV en `…\Terminal\Common\Files\NasdaqAccumulationEA_log.csv` (separador `;`). Borra el CSV entre tests si quieres un registro limpio, porque el EA añade al final del archivo.
8. Optimización: se pueden optimizar `MaxAccumulationPoints`, `SL_Buffer_Points`, `RiskReward`, `MaxSpreadPoints`, `EndHour` y `RiskPercent`. Los parámetros incoherentes devuelven `INIT_PARAMETERS_INCORRECT` y esa pasada se descarta.

**Formato del registro (CSV/Journal):** `Date; TimeNY; ServerTime; Symbol; Event; Direction; Entry; StopLoss; TakeProfit; RangePts; Lots; RiskMoney; Result; PnL; Reason`

---

## Si el EA no abre operaciones

Cada día que no opera, el EA escribe el motivo en el Journal (pestaña **Diario** del probador o **Expertos** en el terminal). En el modo visual también aparece en la línea `Reason:` del panel. Al terminar el backtest imprime un resumen:

```
[NAE] ===== RESUMEN: 250 días hábiles evaluados | 0 operaciones abiertas =====
[NAE]   Días sin operar por INSUFFICIENT_MARGIN: 130
[NAE]   Días sin operar por INVALID_RANGE: 120
```

Cuando rechaza una entrada imprime una línea `Entrada LONG/SHORT RECHAZADA: <motivo> | <detalle con los números>`.

| Motivo | Causa habitual | Solución |
|---|---|---|
| `INSUFFICIENT_MARGIN` | Con `RiskPercent = 10` y un SL de unos 40 puntos, la posición necesaria vale unas **50 veces el equity**. Muchos brokers apalancan el NASDAQ a 1:20–1:50, así que el margen no alcanza. | Baja `RiskPercent` (p. ej. 1–2%), sube el apalancamiento del test o activa `AdjustLotToLimits`. |
| `INVALID_LOT_SIZE` | El lote supera el máximo del broker o queda por debajo del mínimo (cuenta pequeña). | Activa `AdjustLotToLimits` (máximo) o aumenta el depósito (mínimo). |
| `INVALID_RANGE` | La acumulación de 09:00–09:30 supera `MaxAccumulationPoints`. Con el NASDAQ por encima de 20 000, rangos de más de 40 puntos son frecuentes. | Confirma que es el comportamiento deseado o sube `MaxAccumulationPoints`. |
| `NOT_ENOUGH_REBOUNDS` | El precio no tocó o no rebotó suficientes veces entre techo y suelo: fue una tendencia, no una acumulación. | Comportamiento esperado. Para ser más o menos exigente, ajusta `MinTouches`, `MinRebounds` o `TouchZonePercent`. |
| `ACCUMULATION_TOO_SHORT` | Menos de `MinAccumCandles` velas consecutivas antes de las 09:30 forman la zona. | Comportamiento esperado, o baja `MinAccumCandles`. |
| `SPREAD_TOO_HIGH` | Spread por encima de `MaxSpreadPoints` en el momento de la ruptura. | Revisa el spread del símbolo o del test y sube `MaxSpreadPoints`. |
| `TRADING_DISABLED` | Trading algorítmico desactivado en el terminal o en las propiedades del EA (solo en cuenta real o demo). | Activa ambos. |
| `BREAKOUT_MISSED` | El EA se inició o reinició después de que el precio ya hubiera roto la zona. | Normal: no entra tarde. |
| `ACCUMULATION_INCOMPLETE` | Faltan velas entre 09:00 y 09:30, o la zona horaria está mal configurada. | Revisa `ServerGMTOffset` y `ServerDSTMode`. |

## 5. Casos extremos contemplados

| Caso | Comportamiento |
|---|---|
| Cambio de horario de verano (EE.UU., Europa y las semanas en que no coinciden) | La conversión servidor → UTC → NY se calcula para cada fecha con las reglas oficiales. |
| Fines de semana (las ticks del domingo por la tarde en NY) | El día se marca `WEEKEND`, sin registro ni operación. |
| Festivos o huecos de datos dentro de 09:00–09:30 | `ACCUMULATION_INCOMPLETE` (se exigen todas las velas). |
| Historial M5 aún sincronizando a las 09:30 | Reintenta durante la primera vela; después bloquea el día. |
| Spread alto en el momento de la ruptura | Reintenta tick a tick **durante 5 minutos (1 vela) desde la ruptura**, siempre que el precio siga fuera de la zona. Si no se normaliza, `SPREAD_TOO_HIGH` y el día se bloquea. |
| Reinicio del EA o de MT5 a mitad del día | Reconstruye la acumulación desde el historial y cuenta las operaciones del día desde los *deals* del magic. Si alguna vela ya cerrada desde las 09:30 superó la zona mientras el EA estaba apagado → `BREAKOUT_MISSED` (no entra tarde). |
| Respuesta de `OrderSend` perdida o timeout | Antes de reintentar comprueba posiciones e historial, así que no hay orden duplicada. Además `OnTradeTransaction` bloquea el día en cuanto llega el *deal* de entrada. |
| Requote o cambio de precio | Hasta 3 intentos dentro de la vela; los errores no transitorios (stops inválidos, volumen, sin dinero) bloquean el día. |
| Broker que no acepta SL/TP en la orden | Se colocan con `PositionModify`. Si el SL no puede colocarse tras 3 intentos, **la posición se cierra** por seguridad. |
| Deslizamiento al ejecutar | El TP se recalcula con el precio real. El riesgo real se registra y está acotado por `Slippage`. |
| Cuenta *netting* con otra posición en el símbolo | No opera (`POSITION_EXISTS`), para no fusionar posiciones. |
| Posición del día anterior todavía abierta | Bloquea la nueva entrada (`POSITION_EXISTS`). |
| Lotaje por debajo del mínimo (cuenta pequeña o SL muy amplio) | No opera; nunca redondea hacia arriba. |
| Símbolo con `TICK_VALUE` 0 en el tester | Usa `OrderCalcProfit` como alternativa (y siempre el mayor de los dos). |
| Ruptura después de la hora `End` | No se busca: `NO_VALID_BREAKOUT`. Una señal pendiente que llega a `End` → `OUTSIDE_SESSION`. |
| Precio por fuera de la zona ya en el primer tick de las 09:30 (gap) | Es una ruptura válida y se entra. |
| Precio por exactamente el máximo o el mínimo | No cuenta: debe superarlo al menos 1 tick. |
| Ruptura que coincide con un pico de spread | El LONG entra al Ask, que puede quedar varios puntos por encima del máximo. El lotaje usa esa distancia real, así que el riesgo sigue siendo el 10%. |
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

**Ruptura (intravela).** Desde las 09:30 NY se compara cada tick con el máximo y el mínimo. Se usa el precio con el que se dibujan las velas: Bid en CFDs, Last en símbolos de bolsa. Así la entrada coincide con lo que ves en el gráfico y con los máximos y mínimos de las velas. La primera ruptura del día es la única válida; después el día queda bloqueado.

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
