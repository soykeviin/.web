# GG_LondonSweepFVG — Expert Advisor MT5

Versión mecánica aprobada de la estrategia de Gerard García (barrida de máximos/mínimos + FVG, dos limits, SL/TP en dinero), adaptada a un **CFD del Nasdaq-100 en VT Markets (MT5)**.

> Aviso: el código **no se ha compilado ni probado en MetaTrader** (el entorno de desarrollo no tenía acceso a MetaEditor). No existen resultados de backtesting. Úsalo solo en demo hasta completar `docs/PRUEBAS_Y_VALIDACION.md`.

## 1. Contenido

| Ruta | Qué es |
|---|---|
| `MQL5/Experts/GG_LondonSweepFVG/GG_LondonSweepFVG.mq5` | Código fuente completo del EA (un único archivo) |
| `docs/ESPECIFICACION.md` | Análisis, decisiones aprobadas, reglas lógicas, arquitectura y parámetros |
| `docs/TRAZABILIDAD.md` | Matriz requisito → código → prueba → estado |
| `docs/PRUEBAS_Y_VALIDACION.md` | Verificaciones hechas, protocolo de pruebas, backtesting, limitaciones y lista de verificación |
| `tests/reference_model.py` | Modelo de referencia en Python (horarios y cálculo de órdenes) |
| `tools/simulador/index.html` | Simulador visual de replay (réplica de la lógica del EA en el navegador; carga barras M1 exportadas de MT5) |

## 2. Qué hace

- **Ventana:** de lunes a viernes, desde las 09:00 de Madrid. Crea setups solo hasta las 11:00 de Madrid. A las 09:30 de Nueva York (llegada de NY) cancela las pendientes y cierra todo.
- **Sesgo:** cierre de la última vela M15 cerrada frente a la EMA20 de M15.
- **Setup:** FVG de M15 de las últimas 3 horas, situado entero por encima del último swing high (ventas) o por debajo del último swing low (compras). Se usa el más cercano al precio.
- **Órdenes:**
  - L1 en el borde cercano del FVG y L2 en el borde lejano, con el mismo volumen.
  - El SL es único, a 66,7 puntos del precio medio.
  - El volumen se calcula para perder como máximo 800 USD con ambas llenas.
  - TP de +500 USD: TP1 si solo entra L1; TP2 combinado si entran las dos.
- **Límites:** un setup por día. Si se toca el SL o el TP, se cierra el resto y se cancelan las pendientes.

## 3. Instalación y compilación

1. En MT5 (VT Markets): **Archivo → Abrir carpeta de datos**.
2. Copia `GG_LondonSweepFVG.mq5` en `MQL5/Experts/GG_LondonSweepFVG/`.
3. Abre MetaEditor (F4), abre el archivo y pulsa **Compilar (F7)**. Deben salir 0 errores y 0 advertencias. Se genera `GG_LondonSweepFVG.ex5`.
4. En MT5, en el Navegador, pulsa clic derecho en *Asesores Expertos* → **Actualizar**.
5. Abre el gráfico del CFD Nasdaq-100. En VT Markets suele llamarse `NAS100` o similar: comprueba el nombre exacto en Observación de Mercado. Se recomienda M15.
6. Arrastra el EA al gráfico. En *Común*, marca **Permitir trading algorítmico**. Activa el botón **Trading algorítmico** de la barra.
7. Revisa en la pestaña **Expertos** las líneas `[GGA ...]` de inicio: especificación del símbolo, valor por punto y lote, hora del servidor y horario de la ventana.

### Errores de compilación frecuentes

| Mensaje | Causa probable | Solución |
|---|---|---|
| `'Trade.mqh' - can't open` | Instalación de MT5 incompleta | Reinstala MT5; el archivo está en `MQL5/Include/Trade/Trade.mqh` |
| `'input group' - unexpected token` | Terminal muy antiguo | Actualiza MT5 a una build reciente |
| `undeclared identifier` con `DEAL_FEE` o `SYMBOL_EXPIRATION_*` | Build antigua | Actualiza MT5 |
| Texto con tildes ilegible en el log | Codificación | El archivo es UTF-8 con BOM; no lo guardes en ANSI |

Si aparece cualquier otro error, copia la línea completa de la pestaña *Errores* de MetaEditor para corregirlo.

## 4. Verificar la hora del servidor (obligatorio)

El EA no usa `TimeGMT()`, porque en el Strategy Tester no es fiable. Calcula la hora con:
- `InpServerGmtOffsetWinter` (por defecto 2).
- `InpServerDst` (por defecto EE. UU.).

Para comprobarlo:
1. Compara la hora de *Observación de Mercado* con la hora UTC real.
2. En invierno debe ser UTC+2 y en verano de EE. UU., UTC+3. Si no coincide, ajusta los dos inputs.
3. La línea de inicio "cierre NY" debe corresponder a las 09:30 de Nueva York.

## 5. Parámetros recomendados

Los valores por defecto son los de la especificación aprobada (`docs/ESPECIFICACION.md` §5). Antes de operar, solo debes ajustar:
- `InpCommissionPerLotSide`: la comisión real por lote y lado de tu cuenta (0 si es una cuenta solo con spread).
- `InpServerGmtOffsetWinter` / `InpServerDst`: si la verificación de la §4 lo requiere.

No cambies el riesgo, la distancia del SL, el TP ni el horario sin volver a aprobar la especificación.

## 6. Backtesting

Sigue `docs/PRUEBAS_Y_VALIDACION.md` §3. En resumen:
- Strategy Tester con "Cada tick basado en ticks reales", M15.
- Un periodo dentro de muestra y otro fuera de muestra, sin reoptimizar.
- Comisión real y retraso de ejecución.

Compara la línea `SETUP` del log con:

```
python3 tests/reference_model.py plan SELL <fvg_low> <fvg_high> --vpp <valor por punto y lote> --step <paso de lote>
```

## 7. Simulador visual de replay

`tools/simulador/index.html` reproduce vela a vela la lógica del EA en el navegador: sesgo, swing, FVG, colocación de L1/L2, llenados, paso de TP1 a TP2, SL/TP y cierre en la llegada de NY, con estadísticas y diario.
- Abre con datos sintéticos de demostración, que no representan el mercado.
- Para datos reales: en MT5, ve a **Ver → Símbolos → Barras**, elige el símbolo y **M1**, pulsa **Exportar barras** y carga el CSV con el botón *Cargar CSV de MT5*.
- Ejecuta en modo "1 minuto OHLC". No sustituye al Strategy Tester con el EA real (modo visual + ticks reales).

## 8. Advertencias

- R:R ≈ 0,6 (riesgo 800 / objetivo 500). La estrategia necesita un win rate superior al 61,5 % antes de costes.
- Los resultados mostrados en el vídeo no están verificados y no garantizan nada.
- Revisa las reglas de tu cuenta de fondeo (uso de EAs, pérdida diaria, consistencia) antes de usarlo.
