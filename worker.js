// Web Worker: downloads Kronos weights from Hugging Face and runs inference off the UI thread.
import { parseSafetensors, KronosTokenizer, KronosModel, KronosPredictor } from './kronos.js';

const CACHE_NAME = 'kronos-weights-v1';
let current = null; // { key, predictor }

async function fetchWithProgress(url, label, onProgress) {
  let cache = null;
  try { cache = await caches.open(CACHE_NAME); } catch { /* Cache API unavailable */ }
  if (cache) {
    const hit = await cache.match(url);
    if (hit) {
      onProgress(label, 1, 1, true);
      return hit.arrayBuffer();
    }
  }
  const res = await fetch(url);
  if (!res.ok) throw new Error(`HTTP ${res.status} al descargar ${url}`);
  const total = Number(res.headers.get('content-length')) || 0;
  let buf;
  if (res.body && res.body.getReader) {
    const reader = res.body.getReader();
    const chunks = [];
    let loaded = 0;
    for (;;) {
      const { done, value } = await reader.read();
      if (done) break;
      chunks.push(value);
      loaded += value.length;
      onProgress(label, loaded, total, false);
    }
    const out = new Uint8Array(loaded);
    let o = 0;
    for (const c of chunks) { out.set(c, o); o += c.length; }
    buf = out.buffer;
  } else {
    buf = await res.arrayBuffer();
  }
  if (cache) {
    try { await cache.put(url, new Response(buf.slice(0))); } catch { /* quota exceeded: ignore */ }
  }
  return buf;
}

async function fetchJson(url) {
  const res = await fetch(url);
  if (!res.ok) throw new Error(`HTTP ${res.status} al descargar ${url}`);
  return res.json();
}

async function load({ hub, modelRepo, tokenizerRepo, maxContext }) {
  const key = `${hub}|${modelRepo}|${tokenizerRepo}`;
  if (current && current.key === key) {
    current.predictor.maxContext = maxContext;
    return;
  }
  current = null;
  const url = (repo, file) => `${hub.replace(/\/$/, '')}/${repo}/resolve/main/${file}`;
  const progress = (label, loaded, total, cached) => postMessage({ type: 'download', label, loaded, total, cached });

  const [tokCfg, mdlCfg] = await Promise.all([
    fetchJson(url(tokenizerRepo, 'config.json')),
    fetchJson(url(modelRepo, 'config.json')),
  ]);
  const tokBuf = await fetchWithProgress(url(tokenizerRepo, 'model.safetensors'), tokenizerRepo, progress);
  const mdlBuf = await fetchWithProgress(url(modelRepo, 'model.safetensors'), modelRepo, progress);
  postMessage({ type: 'status', text: 'Inicializando modelo…' });
  const tokenizer = new KronosTokenizer(tokCfg, parseSafetensors(tokBuf));
  const model = new KronosModel(mdlCfg, parseSafetensors(mdlBuf));
  current = { key, predictor: new KronosPredictor(model, tokenizer, { maxContext }) };
}

onmessage = async (e) => {
  const msg = e.data;
  try {
    if (msg.type === 'run') {
      await load(msg.model);
      postMessage({ type: 'status', text: 'Generando predicción…' });
      const t0 = performance.now();
      const xTimes = msg.xTimes.map((t) => new Date(t));
      const yTimes = msg.yTimes.map((t) => new Date(t));
      const preds = await current.predictor.predict(msg.rows, xTimes, yTimes, {
        ...msg.opts,
        onProgress: (p) => postMessage({ type: 'progress', value: p }),
      });
      postMessage({
        type: 'result',
        preds: preds.map((p) => ({ ...p, time: p.time.getTime() })),
        seconds: (performance.now() - t0) / 1000,
      });
    }
  } catch (err) {
    postMessage({ type: 'error', message: err && err.message ? err.message : String(err) });
  }
};
