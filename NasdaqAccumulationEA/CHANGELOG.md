# Historial de cambios

| Versión | Cambios |
|---|---|
| 1.30 | La acumulación debe tener **al menos 4 velas consecutivas** (`MinAccumCandles`) con cuerpos solapados y el precio debe **rebotar** entre techo y suelo (`MinRebounds`); una tendencia ya no cuenta como acumulación. **Cuadro de acumulación** visible sobre esas velas (relleno, borde y etiqueta), con colores configurables. |
| 1.20 | La zona se mide con los **cuerpos** de las velas (`UseCandleBodies`) y exige toques en techo y suelo (`MinTouches`, `TouchZonePercent`). |
| 1.11 | Rango máximo de acumulación por defecto: **120 puntos** (antes 40). |
| 1.10 | Diagnóstico de entradas rechazadas con números, resumen por motivo al final del backtest y opción `AdjustLotToLimits`. |
| 1.00 (2ª entrega) | Entrada **intravela**: entra en cuanto el precio rompe la zona, sin esperar el cierre de la vela M5. |
| 1.00 | Primera versión: ruptura de la acumulación 09:00–09:30 NY, 1 operación por día, SL al otro lado, TP 1:2, riesgo por % de equity. |
