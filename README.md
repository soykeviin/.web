# Kronos en el navegador

Ejecuta [Kronos](https://github.com/shiyu-coder/Kronos) — el modelo fundacional para velas
financieras (K-lines) — directamente en el navegador, sin servidor ni Python.

- **`kronos.js`**: port a JavaScript puro (sin dependencias) de `KronosTokenizer`, `Kronos` y
  `KronosPredictor`: tokenizador BSQ jerárquico, transformer con RoPE, capa de dependencia s1→s2,
  muestreo top-k/top-p y la inferencia autoregresiva con ventana deslizante. Usa caché KV y
  reutiliza el prefill entre muestras.
- **`worker.js`**: descarga `config.json` + `model.safetensors` desde Hugging Face
  (`NeoQuasar/Kronos-*`), los guarda en la Cache API y ejecuta la inferencia en un Web Worker.
- **`index.html` / `app.js`**: interfaz con datos de Binance o CSV propio, gráfico de velas,
  modo backtest y exportación a CSV.

## Uso

Sirve la carpeta con cualquier servidor estático (los módulos ES no funcionan desde `file://`):

```bash
python3 -m http.server 8000
# abre http://localhost:8000
```

O activa GitHub Pages en el repositorio (Settings → Pages → rama y carpeta raíz).

| Modelo        | Tokenizador           | Contexto | Descarga aprox. |
|---------------|-----------------------|----------|-----------------|
| Kronos-mini   | Kronos-Tokenizer-2k   | 2048     | ~20 MB          |
| Kronos-small  | Kronos-Tokenizer-base | 512      | ~110 MB         |
| Kronos-base   | Kronos-Tokenizer-base | 512      | ~420 MB         |

Kronos-small con 400 velas de historia y 60 de horizonte tarda ~10 s en un portátil (un hilo).

### CSV

Columnas: `timestamps` (o `date`/`time`), `open`, `high`, `low`, `close` y opcionalmente
`volume`, `amount`. Igual que en el original, si falta `amount` se calcula como
`volume × media(OHLC)`. Las fechas se interpretan como hora local "naive" (como pandas).

## Verificación

`tests/` compara la implementación JS con el código PyTorch original usando pesos aleatorios:

```bash
pip install torch einops safetensors huggingface_hub pandas tqdm
git clone https://github.com/shiyu-coder/Kronos /tmp/Kronos
python tests/ref.py /tmp/Kronos out 0 && node tests/compare.mjs ../kronos.js out
python tests/pred.py /tmp/Kronos out && node tests/compare_predict.mjs ../kronos.js out
```

Diferencias máximas observadas ≈ 1e-7 (tokens idénticos, logits, inferencia autoregresiva con y
sin ventana deslizante, y `predict()` completo).

Las predicciones no son consejo financiero.
