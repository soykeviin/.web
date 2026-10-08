import { FEATURES } from './kronos.js';

const MODELS = {
  mini: { modelRepo: 'NeoQuasar/Kronos-mini', tokenizerRepo: 'NeoQuasar/Kronos-Tokenizer-2k', maxContext: 2048 },
  small: { modelRepo: 'NeoQuasar/Kronos-small', tokenizerRepo: 'NeoQuasar/Kronos-Tokenizer-base', maxContext: 512 },
  base: { modelRepo: 'NeoQuasar/Kronos-base', tokenizerRepo: 'NeoQuasar/Kronos-Tokenizer-base', maxContext: 512 },
};

const $ = (id) => document.getElementById(id);
const worker = new Worker(new URL('./worker.js', import.meta.url), { type: 'module' });

let source = 'binance';
let csvData = null;     // [{time, open, high, low, close, volume?, amount?}]
let view = null;        // { history, preds, actual }

// ---------------------------------------------------------------------------
// Data loading
// ---------------------------------------------------------------------------

async function loadBinance(symbol, interval, limit) {
  const rows = [];
  let endTime = null;
  while (rows.length < limit) {
    const n = Math.min(1000, limit - rows.length);
    const url = `https://data-api.binance.vision/api/v3/klines?symbol=${encodeURIComponent(symbol.toUpperCase())}&interval=${interval}&limit=${n}` + (endTime ? `&endTime=${endTime}` : '');
    const res = await fetch(url);
    if (!res.ok) throw new Error(`Binance respondió ${res.status}: ${await res.text()}`);
    const k = await res.json();
    if (!k.length) break;
    rows.unshift(...k.map((c) => ({ time: c[0], open: +c[1], high: +c[2], low: +c[3], close: +c[4], volume: +c[5], amount: +c[7] })));
    endTime = k[0][0] - 1;
    if (k.length < n) break;
  }
  return rows;
}

// Timestamps are treated as naive wall-clock times (stored as UTC), like pandas does.
function parseTime(s) {
  s = String(s).trim().replace(/^"|"$/g, '');
  if (/^\d+(\.\d+)?$/.test(s)) {
    const n = Number(s);
    return n > 1e11 ? n : n * 1000;
  }
  const m = s.match(/^(\d{4})[-/](\d{1,2})[-/](\d{1,2})(?:[ T](\d{1,2}):(\d{2})(?::(\d{2}))?)?/);
  if (m) return Date.UTC(+m[1], +m[2] - 1, +m[3], +(m[4] || 0), +(m[5] || 0), +(m[6] || 0));
  const t = Date.parse(s);
  if (Number.isNaN(t)) throw new Error(`No se pudo interpretar la fecha "${s}"`);
  return t;
}

function parseCsv(text) {
  const lines = text.split(/\r?\n/).filter((l) => l.trim());
  const sep = (lines[0].match(/;/g) || []).length > (lines[0].match(/,/g) || []).length ? ';' : ',';
  const header = lines[0].split(sep).map((h) => h.trim().replace(/^"|"$/g, '').toLowerCase());
  const idx = (names) => header.findIndex((h) => names.includes(h));
  const ti = idx(['timestamps', 'timestamp', 'date', 'datetime', 'time', 'fecha']);
  const cols = Object.fromEntries(FEATURES.map((f) => [f, idx([f, f === 'volume' ? 'vol' : f])]));
  if (ti < 0) throw new Error('El CSV necesita una columna de fecha (timestamps/date/time).');
  for (const f of ['open', 'high', 'low', 'close']) if (cols[f] < 0) throw new Error(`Falta la columna "${f}".`);
  const rows = lines.slice(1).map((l) => {
    const c = l.split(sep);
    const r = { time: parseTime(c[ti]) };
    for (const f of FEATURES) if (cols[f] >= 0) r[f] = parseFloat(c[cols[f]]);
    return r;
  }).filter((r) => ['open', 'high', 'low', 'close'].every((f) => Number.isFinite(r[f])));
  rows.sort((a, b) => a.time - b.time);
  return rows;
}

// Future timestamps continue the dominant spacing; weekends are skipped if the
// history never contains them (e.g. stock markets).
function futureTimes(times, n) {
  const diffs = [];
  for (let i = Math.max(1, times.length - 100); i < times.length; i++) diffs.push(times[i] - times[i - 1]);
  diffs.sort((a, b) => a - b);
  const step = diffs[diffs.length >> 1] || 86400000;
  const hasWeekend = times.some((t) => [0, 6].includes(new Date(t).getUTCDay()));
  const out = [];
  let t = times[times.length - 1];
  while (out.length < n) {
    t += step;
    if (!hasWeekend && [0, 6].includes(new Date(t).getUTCDay())) continue;
    out.push(t);
  }
  return out;
}

// ---------------------------------------------------------------------------
// Chart (plain canvas)
// ---------------------------------------------------------------------------

const css = (v) => getComputedStyle(document.documentElement).getPropertyValue(v).trim();
const fmt = (v) => {
  const a = Math.abs(v);
  return a >= 1000 ? v.toFixed(0) : a >= 10 ? v.toFixed(2) : a >= 1 ? v.toFixed(3) : v.toPrecision(4);
};
const fmtTime = (t) => new Date(t).toISOString().replace('T', ' ').slice(0, 16);

let layout = null;

function drawChart() {
  const canvas = $('chart');
  const dpr = window.devicePixelRatio || 1;
  const W = canvas.clientWidth, H = canvas.clientHeight;
  canvas.width = W * dpr; canvas.height = H * dpr;
  const ctx = canvas.getContext('2d');
  ctx.setTransform(dpr, 0, 0, dpr, 0, 0);
  ctx.clearRect(0, 0, W, H);
  if (!view) {
    ctx.fillStyle = css('--muted');
    ctx.font = '14px system-ui';
    ctx.textAlign = 'center';
    ctx.fillText('Carga datos y pulsa «Predecir»', W / 2, H / 2);
    return;
  }
  const { history, preds, actual } = view;
  const showHist = history.slice(-Math.max(60, Math.min(history.length, preds.length * 3)));
  const bars = [...showHist.map((r) => ({ ...r, kind: 'hist' })), ...preds.map((r, i) => ({ ...r, kind: 'pred', actual: actual ? actual[i] : null }))];
  const padL = 8, padR = 64, padT = 10, padB = 24;
  const volH = Math.round((H - padT - padB) * 0.18);
  const priceH = H - padT - padB - volH - 8;
  const n = bars.length, cw = (W - padL - padR) / n;
  let lo = Infinity, hi = -Infinity, vmax = 0;
  for (const b of bars) {
    lo = Math.min(lo, b.low); hi = Math.max(hi, b.high);
    if (b.actual) { lo = Math.min(lo, b.actual.low); hi = Math.max(hi, b.actual.high); }
    vmax = Math.max(vmax, b.volume || 0, b.actual ? b.actual.volume || 0 : 0);
  }
  const pad = (hi - lo) * 0.05 || 1;
  lo -= pad; hi += pad;
  const y = (v) => padT + (hi - v) / (hi - lo) * priceH;
  const volTop = padT + priceH + 8;
  const yv = (v) => volTop + volH - (vmax ? v / vmax * volH : 0);
  const x = (i) => padL + i * cw + cw / 2;

  // grid + axis
  ctx.strokeStyle = css('--grid'); ctx.fillStyle = css('--muted');
  ctx.font = '11px system-ui'; ctx.textAlign = 'left'; ctx.lineWidth = 1;
  for (let k = 0; k <= 5; k++) {
    const v = lo + (hi - lo) * k / 5, yy = Math.round(y(v)) + 0.5;
    ctx.beginPath(); ctx.moveTo(padL, yy); ctx.lineTo(W - padR, yy); ctx.stroke();
    ctx.fillText(fmt(v), W - padR + 6, yy + 4);
  }
  ctx.textAlign = 'center';
  const every = Math.ceil(n / 6);
  for (let i = every >> 1; i < n; i += every) ctx.fillText(fmtTime(bars[i].time).slice(5), x(i), H - 6);

  // forecast region
  const split = showHist.length;
  ctx.fillStyle = css('--pred-up') + '14';
  ctx.fillRect(padL + split * cw, padT, (n - split) * cw, H - padT - padB);
  ctx.strokeStyle = css('--muted'); ctx.setLineDash([4, 4]);
  ctx.beginPath(); ctx.moveTo(padL + split * cw, padT); ctx.lineTo(padL + split * cw, H - padB); ctx.stroke();
  ctx.setLineDash([]);

  const bodyW = Math.max(1, Math.min(12, cw * 0.7));
  const candle = (b, i, upC, downC, alpha = 1) => {
    ctx.globalAlpha = alpha;
    const up = b.close >= b.open, col = up ? upC : downC;
    ctx.strokeStyle = col; ctx.fillStyle = col;
    ctx.beginPath(); ctx.moveTo(x(i), y(b.high)); ctx.lineTo(x(i), y(b.low)); ctx.stroke();
    const top = y(Math.max(b.open, b.close)), bot = y(Math.min(b.open, b.close));
    ctx.fillRect(x(i) - bodyW / 2, top, bodyW, Math.max(1, bot - top));
    if (b.volume) ctx.fillRect(x(i) - bodyW / 2, yv(b.volume), bodyW, volTop + volH - yv(b.volume));
    ctx.globalAlpha = 1;
  };
  const up = css('--up'), down = css('--down'), pu = css('--pred-up'), pd = css('--pred-down'), muted = css('--muted');
  bars.forEach((b, i) => {
    if (b.kind === 'hist') candle(b, i, up, down);
    else {
      if (b.actual) candle(b.actual, i, muted, muted, 0.35);
      candle(b, i, pu, pd);
    }
  });
  // close lines in forecast zone
  const line = (get, color, dash) => {
    ctx.strokeStyle = color; ctx.lineWidth = 1.5; ctx.setLineDash(dash);
    ctx.beginPath();
    ctx.moveTo(x(split - 1), y(showHist[split - 1].close));
    for (let i = split; i < n; i++) ctx.lineTo(x(i), y(get(bars[i])));
    ctx.stroke(); ctx.setLineDash([]); ctx.lineWidth = 1;
  };
  if (actual) line((b) => b.actual.close, muted, [3, 3]);
  line((b) => b.close, pu, []);
  layout = { bars, x, cw, padL, W, H };
}

function onHover(e) {
  const tip = $('tooltip');
  if (!layout) return;
  const rect = $('chart').getBoundingClientRect();
  const px = e.clientX - rect.left;
  const i = Math.floor((px - layout.padL) / layout.cw);
  const b = layout.bars[i];
  if (!b) { tip.style.display = 'none'; return; }
  const line = (r) => `O ${fmt(r.open)} · H ${fmt(r.high)} · L ${fmt(r.low)} · C ${fmt(r.close)}`;
  tip.innerHTML = `<b>${fmtTime(b.time)}</b> ${b.kind === 'pred' ? '(predicción)' : ''}<br>${line(b)}`
    + (b.volume ? `<br>Vol ${fmt(b.volume)}` : '')
    + (b.actual ? `<br><span style="color:var(--muted)">Real: ${line(b.actual)}</span>` : '');
  tip.style.display = 'block';
  const left = Math.min(px + 14, rect.width - tip.offsetWidth - 4);
  tip.style.left = `${Math.max(0, left)}px`;
  tip.style.top = `${Math.max(0, e.clientY - rect.top - tip.offsetHeight - 10)}px`;
}

// ---------------------------------------------------------------------------
// Results
// ---------------------------------------------------------------------------

function renderResults(seconds) {
  const { history, preds, actual } = view;
  const last = history[history.length - 1].close;
  const end = preds[preds.length - 1].close;
  const ch = (end / last - 1) * 100;
  const stats = [
    ['Último cierre', fmt(last)],
    ['Cierre previsto', fmt(end)],
    ['Cambio previsto', `${ch >= 0 ? '+' : ''}${ch.toFixed(2)}%`],
    ['Tiempo', `${seconds.toFixed(1)} s`],
  ];
  if (actual) {
    const mae = actual.reduce((s, a, i) => s + Math.abs(a.close - preds[i].close), 0) / actual.length;
    const realCh = actual[actual.length - 1].close / last - 1;
    const hit = Math.sign(realCh) === Math.sign(end / last - 1);
    stats.push(['MAE cierre', fmt(mae)], ['Dirección', hit ? 'Acierto' : 'Fallo']);
  }
  $('stats').innerHTML = stats.map(([k, v]) => `<div class="stat"><small>${k}</small><b>${v}</b></div>`).join('');
  const head = ['Fecha', ...FEATURES.slice(0, 5), ...(actual ? ['close real'] : [])];
  $('table').innerHTML = `<thead><tr>${head.map((h) => `<th>${h}</th>`).join('')}</tr></thead><tbody>`
    + preds.map((p, i) => `<tr><td>${fmtTime(p.time)}</td>${FEATURES.slice(0, 5).map((f) => `<td>${fmt(p[f])}</td>`).join('')}${actual ? `<td>${fmt(actual[i].close)}</td>` : ''}</tr>`).join('')
    + '</tbody>';
  $('download').classList.remove('hidden');
  $('legendActual').classList.toggle('hidden', !actual);
}

function downloadCsv() {
  const rows = [['timestamps', ...FEATURES].join(',')]
    .concat(view.preds.map((p) => [fmtTime(p.time), ...FEATURES.map((f) => p[f])].join(',')));
  const a = document.createElement('a');
  a.href = URL.createObjectURL(new Blob([rows.join('\n')], { type: 'text/csv' }));
  a.download = 'kronos_prediccion.csv';
  a.click();
  URL.revokeObjectURL(a.href);
}

// ---------------------------------------------------------------------------
// Wiring
// ---------------------------------------------------------------------------

function setStatus(text, error = false) {
  $('status').textContent = text;
  $('status').classList.toggle('error', error);
}

function setProgress(v) {
  const p = $('progress');
  if (v == null) { p.classList.add('hidden'); return; }
  p.classList.remove('hidden');
  if (v < 0) p.removeAttribute('value'); else p.value = v;
}

async function run() {
  const btn = $('run');
  btn.disabled = true;
  setProgress(-1);
  try {
    const lookback = Math.max(16, +$('lookback').value | 0);
    const predLen = Math.max(1, +$('predLen').value | 0);
    const backtest = $('backtest').checked;
    const modelKey = $('model').value;
    const model = { ...MODELS[modelKey], hub: $('hub').value.trim() || 'https://huggingface.co' };

    let all;
    if (source === 'binance') {
      setStatus('Descargando velas de Binance…');
      all = await loadBinance($('symbol').value.trim(), $('interval').value, lookback + (backtest ? predLen : 0));
      $('chartTitle').textContent = `${$('symbol').value.toUpperCase()} · ${$('interval').value}`;
    } else {
      if (!csvData) throw new Error('Selecciona un archivo CSV.');
      all = csvData;
      $('chartTitle').textContent = $('csv').files[0]?.name || 'CSV';
    }
    const end = backtest ? all.length - predLen : all.length;
    if (end < 16) throw new Error('No hay suficientes velas para la historia solicitada.');
    const history = all.slice(Math.max(0, end - lookback), end);
    const actual = backtest ? all.slice(end, end + predLen) : null;
    const yTimes = backtest ? actual.map((r) => r.time) : futureTimes(history.map((r) => r.time), predLen);
    $('dataInfo').textContent = `${history.length} velas de historia: ${fmtTime(history[0].time)} → ${fmtTime(history[history.length - 1].time)}`;
    if (history.length > model.maxContext)
      $('dataInfo').textContent += ` (el modelo solo ve las últimas ${model.maxContext})`;

    setStatus('Cargando modelo…');
    const result = await new Promise((resolve, reject) => {
      worker.onmessage = ({ data: m }) => {
        if (m.type === 'download') {
          const mb = (b) => (b / 1048576).toFixed(1);
          setStatus(m.cached ? `${m.label}: desde caché` : `Descargando ${m.label}: ${mb(m.loaded)}${m.total ? ` / ${mb(m.total)}` : ''} MB`);
          setProgress(m.total ? m.loaded / m.total : -1);
        } else if (m.type === 'status') {
          setStatus(m.text); setProgress(-1);
        } else if (m.type === 'progress') {
          setStatus(`Generando predicción… ${Math.round(m.value * 100)}%`); setProgress(m.value);
        } else if (m.type === 'result') resolve(m);
        else if (m.type === 'error') reject(new Error(m.message));
      };
      worker.postMessage({
        type: 'run',
        model,
        rows: history.map(({ open, high, low, close, volume, amount }) => ({ open, high, low, close, volume, amount })),
        xTimes: history.map((r) => r.time),
        yTimes,
        opts: {
          temperature: +$('temp').value || 1,
          topP: +$('topP').value || 0.9,
          topK: 0,
          sampleCount: Math.max(1, +$('samples').value | 0),
          seed: +$('seed').value | 0,
        },
      });
    });
    view = { history, preds: result.preds, actual };
    drawChart();
    renderResults(result.seconds);
    setStatus(`Listo · ${predLen} velas previstas en ${result.seconds.toFixed(1)} s`);
  } catch (err) {
    console.error(err);
    setStatus(err.message || String(err), true);
  } finally {
    btn.disabled = false;
    setProgress(null);
  }
}

document.querySelectorAll('.tabs button').forEach((b) => b.addEventListener('click', () => {
  source = b.dataset.src;
  document.querySelectorAll('.tabs button').forEach((o) => o.classList.toggle('active', o === b));
  $('src-binance').classList.toggle('hidden', source !== 'binance');
  $('src-csv').classList.toggle('hidden', source !== 'csv');
}));

$('csv').addEventListener('change', async () => {
  const f = $('csv').files[0];
  if (!f) return;
  try {
    csvData = parseCsv(await f.text());
    $('dataInfo').textContent = `${csvData.length} velas cargadas (${fmtTime(csvData[0].time)} → ${fmtTime(csvData[csvData.length - 1].time)})`;
    setStatus('');
  } catch (err) {
    csvData = null;
    setStatus(err.message, true);
  }
});

$('model').addEventListener('change', () => {
  const max = MODELS[$('model').value].maxContext;
  if (+$('lookback').value > max) $('lookback').value = max;
});
$('run').addEventListener('click', run);
$('download').addEventListener('click', downloadCsv);
$('chart').addEventListener('mousemove', onHover);
$('chart').addEventListener('mouseleave', () => { $('tooltip').style.display = 'none'; });
window.addEventListener('resize', drawChart);
window.matchMedia('(prefers-color-scheme: dark)').addEventListener('change', drawChart);
drawChart();
