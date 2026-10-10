# Pruebas, backtesting y limitaciones — GG_LondonSweepFVG v1.10

## 1. Qué se ha verificado ya (resultados medidos)

| Verificación | Herramienta | Resultado |
|---|---|---|
| Conversión servidor ↔ UTC ↔ Madrid ↔ NY y ventana diaria | `tests/reference_model.py` contra la base IANA (`zoneinfo`) | **1.305 días laborables 2024–2028, 0 discrepancias** (incluye las semanas de desfase de DST EE. UU./UE) |
| Plan de órdenes: riesgo ≤ 800, beneficio ≥ 500 en TP1 y TP2 | `tests/reference_model.py` (ventas y compras; 1, 10 y 0,1 $ por punto y lote) | **6/6 casos OK**; FVG de 140 pts correctamente rechazado |
| Compilación MQL5 | MetaEditor | **No verificado**: este entorno no tiene acceso a MetaTrader/MetaEditor. Debe compilarse en tu equipo (ver README §3) |
| Comportamiento en el Strategy Tester / demo | MT5 | **No verificado** — pendiente de las pruebas TP-xx |

No existen todavía resultados de backtesting: **ninguna cifra de rentabilidad, win rate ni drawdown ha sido medida**.

Ejemplo de referencia calculado a mano (para comparar con el log `SETUP ...`), con 1 USD por punto y lote, paso 0,01:

```
python3 tests/reference_model.py plan SELL 21000 21020 --vpp 1 --step 0.01
→ L1 21000.00 · L2 21030.00 (50 % de 20 puntos sobre el FVG) · SL 21081.70 · 5.99 lotes por orden
  TP1 20916.52 · TP2 20973.26 · riesgo 799.07 · +500.05 (solo L1) · +500.05 (ambas)
```

## 2. Protocolo de pruebas funcionales

Usa el Strategy Tester en **modo visual**, "Cada tick basado en ticks reales", con el gráfico M15 y una EMA(20) añadida a mano para comparar. Cada prueba se valida con las líneas `[GGA ...]` de la pestaña Diario.

| ID | Prueba | Cómo | Criterio de aceptación |
|---|---|---|---|
| TP-01 | Compilación | MetaEditor F7 | 0 errores, 0 advertencias |
| TP-02 | Inicialización y hora del servidor | Arrancar el EA en demo VT Markets | La línea "Hora servidor" coincide con Market Watch; "cierre NY" = 09:30 NY en hora servidor |
| TP-03 | Sesgo | Revisar cada línea "Sesgo" frente al cierre M15, la EMA20 y su valor 3 velas antes | Coincide en el 100 % de las velas revisadas (≥ 20); nunca compras con la EMA bajando ni ventas con la EMA subiendo |
| TP-04 | Swing | Comprobar en el gráfico el pivote K=3 indicado | Es el último pivote confirmado con 3 velas a cada lado |
| TP-05 | FVG válidos | Comprobar zonas y edad ≤ 3 h | Ningún FVG que no esté entero más allá del swing |
| TP-06 | Selección y T3 | Días con varios FVG | Se elige el más cercano al precio con limit válida |
| TP-07 | Precios, volumen y riesgo | Comparar `SETUP` con `reference_model.py plan` usando el valor por punto del log de inicio | L1, L2, SL, TP1, TP2 y lotes idénticos |
| TP-08 | Solo L1 llena → TP1 | Buscar un día así | Cierre en TP1 y L2 cancelada inmediatamente |
| TP-09 | L1 + L2 → TP2 | Buscar un día así | La posición de L1 pasa a TP2 y ambas cierran en TP2 |
| TP-10 | Stop | Día con ambas llenas y SL | Pérdida ≈ −riesgo estimado (± deslizamiento) |
| TP-11 | Llegada de NY | Días sin llenado y con posición abierta; incluir 9–27 mar 2026 y 26–30 oct 2026 | Cancelación y cierre a las 09:30 NY (14:30 Madrid en las semanas de desfase) |
| TP-12 | Un setup por día | Días con cancelación o salida temprana | No se crea un segundo setup |
| TP-13 | Fin de creación 11:00 | Días sin setup antes de las 11:00 Madrid | Ningún setup posterior |
| TP-14 | Filtro de spread | `InpMaxSpread` muy bajo | Log "setup en espera", sin órdenes |
| TP-15 | Reinicio (demo) | Quitar y volver a poner el EA con pendientes y con posición abierta; reiniciar el terminal | Sin duplicados; la gestión TP1→TP2 continúa |
| TP-16 | Restos de día anterior (demo) | Dejar una posición con el EA apagado tras el corte, reactivar | Se cierra al detectarla |
| TP-17 | Rechazo del servidor | `InpRiskMoney` muy alto (margen insuficiente) | Setup descartado con motivo; sin órdenes huérfanas |
| TP-18 | Netting y hedging | Repetir TP-08/09 en ambos tipos de cuenta si el bróker los ofrece | Mismo resultado |

## 3. Procedimiento de backtesting

1. **Datos:** historial de ticks reales de VT Markets para el símbolo (Ver > Símbolos > Ticks). Usa al menos 2 años.
2. **Configuración del tester:** EA `GG_LondonSweepFVG`, símbolo del CFD Nasdaq, periodo M15, modelado "Cada tick basado en ticks reales", depósito y divisa de tu cuenta real (USD), apalancamiento real, retraso de ejecución activado ("Retraso aleatorio") en una segunda pasada.
3. **Muestras:**
   - Dentro de muestra: por ejemplo, 2024-01-01 → 2025-06-30.
   - Fuera de muestra: 2025-07-01 → fecha actual, **con los mismos parámetros** y sin reajustarlos.
4. **No optimizar** para maximizar el beneficio. Si se estudia la sensibilidad, varía un parámetro cada vez (`InpSlDistance` ±20 %, `InpFvgMaxAgeHours` 2–4, `InpPivotK` 2–4) y acepta solo zonas estables, no picos.
5. **Costes:**
   - Introduce la comisión real en `InpCommissionPerLotSide` y, si la cuenta la cobra, en la especificación del símbolo personalizado.
   - Repite la prueba con `InpMaxSpread` activado y con un retraso de ejecución mayor.
6. **Métricas a recoger** (del informe del tester; ninguna está medida aún): beneficio neto, número de operaciones, % ganadoras, profit factor, drawdown máximo absoluto y %, pago esperado por operación, ganancia media y pérdida media, máxima racha de pérdidas, resultados por día de la semana (exportar a Excel), racha de días en pérdida y consistencia (líneas `Resumen` y `Consistencia` del Diario).
7. **Referencia de viabilidad:** con SL 800 / TP 500 el win rate de equilibrio antes de costes es 61,5 %. Un resultado por debajo de ese valor fuera de muestra indica que la versión mecánica no funciona en este instrumento.
8. **Demo:** como mínimo 4 semanas en cuenta demo antes de cualquier uso real, comparando cada operación con el backtest del mismo periodo.

## 4. Limitaciones conocidas

1. **No compilado aquí.** El código usa solo MQL5 estándar y `Trade\Trade.mqh`, pero debe compilarse en MetaEditor (TP-01).
2. **Instrumento distinto al del vídeo.** CFD Nasdaq-100 en VT Markets en lugar de MNQ: spread, horario y datos del bróker difieren del futuro.
3. **Deslizamiento y huecos.** El SL en el servidor puede ejecutarse peor que el precio; la pérdida real puede superar 800 USD.
4. **Spread en el SL.** En ventas, el SL se dispara con el Ask; un ensanchamiento del spread puede activar el stop sin que el Bid llegue.
5. **Cambio de sesgo con pendientes (D07).** Las pendientes siguen activas aunque el sesgo cambie después de colocarlas.
6. **Festivos y cierres anticipados** de EE. UU. y Reino Unido no se gestionan: el EA se rige solo por el reloj.
7. **Hora del servidor.** El valor por defecto (GMT+2/+3 con DST de EE. UU.) es lo habitual en este tipo de brókeres, pero debe confirmarse en VT Markets (TP-02). Un offset incorrecto desplaza toda la ventana.
8. **Pivotes con máximos iguales** no cuentan como swing (comparación estricta).
9. **El TP de +500 es bruto**: la comisión solo entra en el cálculo del volumen (P7).
10. **Rechazo transitorio (T7):** si el servidor rechaza una orden por un movimiento rápido, el día termina sin reintentar (conservador).
11. **Cuenta netting:** no operes el mismo símbolo manualmente ni con otro EA; las posiciones se agregarían.
12. **Ventana corta:** con 09:00–11:00 Madrid para crear setups habrá días sin operación; es el comportamiento especificado.

## 5. Lista de verificación antes de demo o fondeo

- [ ] TP-01 compilación sin errores ni advertencias.
- [ ] TP-02: hora del servidor confirmada; ventana y corte de NY correctos en el log de inicio.
- [ ] Nombre del símbolo, tamaño de contrato, lote mínimo, paso y stops level revisados en la especificación del símbolo.
- [ ] `InpCommissionPerLotSide` con la comisión real de la cuenta.
- [ ] TP-03 a TP-14 superadas en el Strategy Tester.
- [ ] Backtest dentro y fuera de muestra documentado, sin reoptimizar.
- [ ] TP-15 y TP-16 (reinicio) superadas en demo.
- [ ] 4 semanas de demo con operaciones coherentes con el backtest.
- [ ] Reglas de la cuenta de fondeo revisadas: si permite EAs, pérdida diaria y máxima frente a los 800 USD por día, consistencia y horario.
- [ ] Trading algorítmico activado y VPS o equipo encendido durante toda la ventana (el corte de NY lo ejecuta el EA).
