// Kronos inference in plain JavaScript (no dependencies).
// Port of model/kronos.py + model/module.py from https://github.com/shiyu-coder/Kronos
// Works in browsers (main thread or Web Worker) and in Node.js.

// ---------------------------------------------------------------------------
// safetensors
// ---------------------------------------------------------------------------

function f16ToF32(h) {
  const s = (h & 0x8000) >> 15, e = (h & 0x7c00) >> 10, f = h & 0x03ff;
  if (e === 0) return (s ? -1 : 1) * Math.pow(2, -14) * (f / 1024);
  if (e === 0x1f) return f ? NaN : (s ? -Infinity : Infinity);
  return (s ? -1 : 1) * Math.pow(2, e - 15) * (1 + f / 1024);
}

export function parseSafetensors(buffer) {
  const view = new DataView(buffer);
  const headerLen = Number(view.getBigUint64(0, true));
  const header = JSON.parse(new TextDecoder().decode(new Uint8Array(buffer, 8, headerLen)));
  const base = 8 + headerLen;
  const tensors = {};
  for (const [name, info] of Object.entries(header)) {
    if (name === '__metadata__') continue;
    const [start, end] = info.data_offsets;
    const n = info.shape.reduce((a, b) => a * b, 1);
    const bytes = new Uint8Array(buffer, base + start, end - start);
    let data;
    if (info.dtype === 'F32') {
      data = new Float32Array(n);
      new Uint8Array(data.buffer).set(bytes);
    } else if (info.dtype === 'F16' || info.dtype === 'BF16') {
      const u16 = new Uint16Array(n);
      new Uint8Array(u16.buffer).set(bytes);
      data = new Float32Array(n);
      if (info.dtype === 'F16') {
        for (let i = 0; i < n; i++) data[i] = f16ToF32(u16[i]);
      } else {
        const u32 = new Uint32Array(data.buffer);
        for (let i = 0; i < n; i++) u32[i] = u16[i] << 16;
      }
    } else {
      continue; // integer buffers (e.g. quantizer basis) are not needed
    }
    tensors[name] = { data, shape: info.shape };
  }
  return tensors;
}

// ---------------------------------------------------------------------------
// Tensor primitives. Activations are row-major Float32Array [rows, dim].
// Linear weights keep PyTorch layout [out, in].
// ---------------------------------------------------------------------------

// y = x W^T + b. Rows are processed in blocks of 4 and outputs in pairs so each
// weight load is reused 4 times (~2.5x faster than the naive loop in V8).
function linear(x, rows, inDim, W, b, outDim) {
  const y = new Float32Array(rows * outDim);
  let r = 0;
  for (; r + 3 < rows; r += 4) {
    const x0 = r * inDim, x1 = x0 + inDim, x2 = x1 + inDim, x3 = x2 + inDim;
    const y0 = r * outDim, y1 = y0 + outDim, y2 = y1 + outDim, y3 = y2 + outDim;
    let o = 0;
    for (; o + 1 < outDim; o += 2) {
      const wa = o * inDim, wb = wa + inDim;
      let a0 = 0, a1 = 0, a2 = 0, a3 = 0, c0 = 0, c1 = 0, c2 = 0, c3 = 0;
      for (let i = 0; i < inDim; i++) {
        const w = W[wa + i], v = W[wb + i];
        const p0 = x[x0 + i], p1 = x[x1 + i], p2 = x[x2 + i], p3 = x[x3 + i];
        a0 += p0 * w; a1 += p1 * w; a2 += p2 * w; a3 += p3 * w;
        c0 += p0 * v; c1 += p1 * v; c2 += p2 * v; c3 += p3 * v;
      }
      const ba = b ? b[o] : 0, bc = b ? b[o + 1] : 0;
      y[y0 + o] = a0 + ba; y[y1 + o] = a1 + ba; y[y2 + o] = a2 + ba; y[y3 + o] = a3 + ba;
      y[y0 + o + 1] = c0 + bc; y[y1 + o + 1] = c1 + bc; y[y2 + o + 1] = c2 + bc; y[y3 + o + 1] = c3 + bc;
    }
    if (o < outDim) {
      const wo = o * inDim;
      let a0 = 0, a1 = 0, a2 = 0, a3 = 0;
      for (let i = 0; i < inDim; i++) {
        const w = W[wo + i];
        a0 += x[x0 + i] * w; a1 += x[x1 + i] * w; a2 += x[x2 + i] * w; a3 += x[x3 + i] * w;
      }
      const ba = b ? b[o] : 0;
      y[y0 + o] = a0 + ba; y[y1 + o] = a1 + ba; y[y2 + o] = a2 + ba; y[y3 + o] = a3 + ba;
    }
  }
  for (; r < rows; r++) {
    const xo = r * inDim, yo = r * outDim;
    for (let o = 0; o < outDim; o++) {
      const wo = o * inDim;
      let s0 = 0, s1 = 0, s2 = 0, s3 = 0, i = 0;
      for (; i + 3 < inDim; i += 4) {
        s0 += x[xo + i] * W[wo + i];
        s1 += x[xo + i + 1] * W[wo + i + 1];
        s2 += x[xo + i + 2] * W[wo + i + 2];
        s3 += x[xo + i + 3] * W[wo + i + 3];
      }
      for (; i < inDim; i++) s0 += x[xo + i] * W[wo + i];
      y[yo + o] = s0 + s1 + s2 + s3 + (b ? b[o] : 0);
    }
  }
  return y;
}

function rmsNorm(x, rows, dim, w, eps = 1e-5) {
  const y = new Float32Array(rows * dim);
  for (let r = 0; r < rows; r++) {
    const o = r * dim;
    let ss = 0;
    for (let i = 0; i < dim; i++) ss += x[o + i] * x[o + i];
    const inv = 1 / Math.sqrt(ss / dim + eps);
    for (let i = 0; i < dim; i++) y[o + i] = x[o + i] * inv * w[i];
  }
  return y;
}

function addInPlace(a, b) {
  for (let i = 0; i < a.length; i++) a[i] += b[i];
  return a;
}

function softmaxInPlace(a, n = a.length) {
  let m = -Infinity;
  for (let i = 0; i < n; i++) if (a[i] > m) m = a[i];
  let s = 0;
  for (let i = 0; i < n; i++) { a[i] = Math.exp(a[i] - m); s += a[i]; }
  for (let i = 0; i < n; i++) a[i] /= s;
  return a;
}

// RoPE tables: cos/sin for positions [0, len) over head_dim, using the
// "rotate_half" layout of RotaryPositionalEmbedding (freqs duplicated).
const ropeCache = new Map();
function ropeTables(headDim, len) {
  const key = headDim;
  let t = ropeCache.get(key);
  if (!t || t.len < len) {
    const n = Math.max(len, t ? t.len * 2 : 64);
    const half = headDim / 2;
    const cos = new Float32Array(n * headDim), sin = new Float32Array(n * headDim);
    for (let p = 0; p < n; p++) {
      for (let j = 0; j < half; j++) {
        // inv_freq computed in float32 like torch
        const invFreq = Math.fround(1 / Math.pow(10000, Math.fround((2 * j) / headDim)));
        const ang = Math.fround(p * invFreq);
        const c = Math.cos(ang), s = Math.sin(ang);
        cos[p * headDim + j] = c; cos[p * headDim + j + half] = c;
        sin[p * headDim + j] = s; sin[p * headDim + j + half] = s;
      }
    }
    t = { len: n, cos, sin };
    ropeCache.set(key, t);
  }
  return t;
}

// Apply RoPE in place to x [rows, nHeads*headDim], row r at position posStart + r.
function applyRope(x, rows, nHeads, headDim, posStart) {
  const { cos, sin } = ropeTables(headDim, posStart + rows);
  const half = headDim / 2;
  const tmp = new Float32Array(headDim);
  for (let r = 0; r < rows; r++) {
    const p = (posStart + r) * headDim;
    for (let h = 0; h < nHeads; h++) {
      const o = r * nHeads * headDim + h * headDim;
      for (let j = 0; j < half; j++) {
        tmp[j] = -x[o + j + half];
        tmp[j + half] = x[o + j];
      }
      for (let j = 0; j < headDim; j++) {
        x[o + j] = x[o + j] * cos[p + j] + tmp[j] * sin[p + j];
      }
    }
  }
}

// Attention for query rows q [qRows, d] at absolute positions qPosStart..,
// against keys/values [kRows, d] at positions 0..kRows-1.
function attention(q, qRows, k, v, kRows, nHeads, headDim, causal, qPosStart) {
  const d = nHeads * headDim;
  const out = new Float32Array(qRows * d);
  const scale = 1 / Math.sqrt(headDim);
  const scores = new Float32Array(kRows);
  for (let h = 0; h < nHeads; h++) {
    const ho = h * headDim;
    for (let r = 0; r < qRows; r++) {
      const qo = r * d + ho;
      const limit = causal ? Math.min(kRows, qPosStart + r + 1) : kRows;
      for (let t = 0; t < limit; t++) {
        const ko = t * d + ho;
        let s = 0;
        for (let j = 0; j < headDim; j++) s += q[qo + j] * k[ko + j];
        scores[t] = s * scale;
      }
      softmaxInPlace(scores, limit);
      const oo = r * d + ho;
      for (let t = 0; t < limit; t++) {
        const p = scores[t], vo = t * d + ho;
        for (let j = 0; j < headDim; j++) out[oo + j] += p * v[vo + j];
      }
    }
  }
  return out;
}

// ---------------------------------------------------------------------------
// Transformer block (pre-norm, causal self-attention with RoPE, SwiGLU FFN)
// ---------------------------------------------------------------------------

class TransformerBlock {
  constructor(W, prefix, dModel, nHeads, ffDim) {
    const g = (n) => W(prefix + n);
    this.d = dModel; this.nHeads = nHeads; this.headDim = dModel / nHeads; this.ff = ffDim;
    this.norm1 = g('norm1.weight'); this.norm2 = g('norm2.weight');
    this.qW = g('self_attn.q_proj.weight'); this.qB = g('self_attn.q_proj.bias');
    this.kW = g('self_attn.k_proj.weight'); this.kB = g('self_attn.k_proj.bias');
    this.vW = g('self_attn.v_proj.weight'); this.vB = g('self_attn.v_proj.bias');
    this.oW = g('self_attn.out_proj.weight'); this.oB = g('self_attn.out_proj.bias');
    this.w1 = g('ffn.w1.weight'); this.w2 = g('ffn.w2.weight'); this.w3 = g('ffn.w3.weight');
  }

  // x: [rows, d] at positions cache.len .. cache.len+rows-1 (cache may be null).
  // When a cache is given, the new keys/values are appended to it.
  forward(x, rows, cache = null) {
    const { d, nHeads, headDim } = this;
    const h = rmsNorm(x, rows, d, this.norm1);
    const q = linear(h, rows, d, this.qW, this.qB, d);
    const k = linear(h, rows, d, this.kW, this.kB, d);
    const v = linear(h, rows, d, this.vW, this.vB, d);
    const pos = cache ? cache.len : 0;
    applyRope(q, rows, nHeads, headDim, pos);
    applyRope(k, rows, nHeads, headDim, pos);
    let K = k, V = v, kRows = rows;
    if (cache) {
      cache.k.set(k, pos * d); cache.v.set(v, pos * d);
      kRows = pos + rows;
      K = cache.k.subarray(0, kRows * d); V = cache.v.subarray(0, kRows * d);
    }
    const a = attention(q, rows, K, V, kRows, nHeads, headDim, true, pos);
    const x1 = addInPlace(linear(a, rows, d, this.oW, this.oB, d), x);
    const h2 = rmsNorm(x1, rows, d, this.norm2);
    const g1 = linear(h2, rows, d, this.w1, null, this.ff);
    const g3 = linear(h2, rows, d, this.w3, null, this.ff);
    for (let i = 0; i < g1.length; i++) {
      const z = g1[i];
      g1[i] = (z / (1 + Math.exp(-z))) * g3[i];
    }
    return addInPlace(linear(g1, rows, this.ff, this.w2, null, d), x1);
  }
}

function getter(tensors, label) {
  return (name) => {
    const t = tensors[name];
    if (!t) throw new Error(`${label}: missing weight "${name}"`);
    return t.data;
  };
}

// ---------------------------------------------------------------------------
// KronosTokenizer (hybrid BSQ tokenizer)
// ---------------------------------------------------------------------------

export class KronosTokenizer {
  constructor(config, tensors) {
    const W = getter(tensors, 'tokenizer');
    this.cfg = config;
    this.dIn = config.d_in; this.d = config.d_model;
    this.s1Bits = config.s1_bits; this.s2Bits = config.s2_bits;
    this.codebookDim = this.s1Bits + this.s2Bits;
    this.embedW = W('embed.weight'); this.embedB = W('embed.bias');
    this.headW = W('head.weight'); this.headB = W('head.bias');
    this.quantW = W('quant_embed.weight'); this.quantB = W('quant_embed.bias');
    this.postW = W('post_quant_embed.weight'); this.postB = W('post_quant_embed.bias');
    this.encoder = [];
    for (let i = 0; i < config.n_enc_layers - 1; i++)
      this.encoder.push(new TransformerBlock(W, `encoder.${i}.`, this.d, config.n_heads, config.ff_dim));
    this.decoder = [];
    for (let i = 0; i < config.n_dec_layers - 1; i++)
      this.decoder.push(new TransformerBlock(W, `decoder.${i}.`, this.d, config.n_heads, config.ff_dim));
  }

  // x: Float32Array [len, d_in] -> { s1: Int32Array, s2: Int32Array }
  encode(x, len) {
    let z = linear(x, len, this.dIn, this.embedW, this.embedB, this.d);
    for (const layer of this.encoder) z = layer.forward(z, len);
    const c = this.codebookDim;
    const q = linear(z, len, this.d, this.quantW, this.quantB, c);
    // BSQ: L2-normalise then sign; normalisation does not change the sign.
    const s1 = new Int32Array(len), s2 = new Int32Array(len);
    for (let t = 0; t < len; t++) {
      let a = 0, b = 0;
      for (let i = 0; i < this.s1Bits; i++) if (q[t * c + i] > 0) a |= 1 << i;
      for (let i = 0; i < this.s2Bits; i++) if (q[t * c + this.s1Bits + i] > 0) b |= 1 << i;
      s1[t] = a; s2[t] = b;
    }
    return { s1, s2 };
  }

  // s1, s2: index arrays of equal length -> Float32Array [len, d_in]
  decode(s1, s2, len) {
    const c = this.codebookDim, scale = 1 / Math.sqrt(c);
    const bits = new Float32Array(len * c);
    // indices_to_bits(half=True) uses codebook_dim // 2 bits for each half
    const half = c >> 1;
    for (let t = 0; t < len; t++) {
      for (let i = 0; i < half; i++) {
        bits[t * c + i] = ((s1[t] >> i) & 1 ? 1 : -1) * scale;
        bits[t * c + half + i] = ((s2[t] >> i) & 1 ? 1 : -1) * scale;
      }
    }
    let z = linear(bits, len, c, this.postW, this.postB, this.d);
    for (const layer of this.decoder) z = layer.forward(z, len);
    return linear(z, len, this.d, this.headW, this.headB, this.dIn);
  }
}

// ---------------------------------------------------------------------------
// Kronos (decoder-only autoregressive model over hierarchical tokens)
// ---------------------------------------------------------------------------

function sinusoidTable(cIn, d) {
  const w = new Float32Array(cIn * d);
  for (let p = 0; p < cIn; p++) {
    for (let i = 0; i < d; i += 2) {
      const div = Math.exp(i * -(Math.log(10000) / d));
      w[p * d + i] = Math.sin(p * div);
      if (i + 1 < d) w[p * d + i + 1] = Math.cos(p * div);
    }
  }
  return w;
}

export class KronosModel {
  constructor(config, tensors) {
    const W = getter(tensors, 'model');
    this.cfg = config;
    this.d = config.d_model;
    this.s1Bits = config.s1_bits; this.s2Bits = config.s2_bits;
    this.s1Vocab = 2 ** this.s1Bits; this.s2Vocab = 2 ** this.s2Bits;
    this.embS1 = W('embedding.emb_s1.weight');
    this.embS2 = W('embedding.emb_s2.weight');
    this.fusionW = W('embedding.fusion_proj.weight'); this.fusionB = W('embedding.fusion_proj.bias');
    const sizes = { minute: 60, hour: 24, weekday: 7, day: 32, month: 13 };
    this.timeEmb = {};
    for (const [k, n] of Object.entries(sizes)) {
      const t = tensors[`time_emb.${k}_embed.emb.weight`] || tensors[`time_emb.${k}_embed.weight`];
      this.timeEmb[k] = t ? t.data : sinusoidTable(n, this.d);
    }
    this.layers = [];
    for (let i = 0; i < config.n_layers; i++)
      this.layers.push(new TransformerBlock(W, `transformer.${i}.`, this.d, config.n_heads, config.ff_dim));
    this.normW = W('norm.weight');
    this.headS1W = W('head.proj_s1.weight'); this.headS1B = W('head.proj_s1.bias');
    this.headS2W = W('head.proj_s2.weight'); this.headS2B = W('head.proj_s2.bias');
    // DependencyAwareLayer (cross attention, 4 heads by default)
    const ca = 'dep_layer.cross_attn.';
    this.depHeads = 4;
    this.dqW = W(ca + 'q_proj.weight'); this.dqB = W(ca + 'q_proj.bias');
    this.dkW = W(ca + 'k_proj.weight'); this.dkB = W(ca + 'k_proj.bias');
    this.dvW = W(ca + 'v_proj.weight'); this.dvB = W(ca + 'v_proj.bias');
    this.doW = W(ca + 'out_proj.weight'); this.doB = W(ca + 'out_proj.bias');
    this.depNormW = W('dep_layer.norm.weight');
  }

  // Embeds tokens + time stamps. stamps: Float32Array [len, 5] (minute, hour, weekday, day, month)
  embed(s1, s2, stamps, len) {
    const d = this.d, sq = Math.sqrt(d);
    const cat = new Float32Array(len * 2 * d);
    for (let t = 0; t < len; t++) {
      const a = s1[t] * d, b = s2[t] * d, o = t * 2 * d;
      for (let i = 0; i < d; i++) {
        cat[o + i] = this.embS1[a + i] * sq;
        cat[o + d + i] = this.embS2[b + i] * sq;
      }
    }
    const x = linear(cat, len, 2 * d, this.fusionW, this.fusionB, d);
    if (stamps) {
      const te = this.timeEmb;
      for (let t = 0; t < len; t++) {
        const mi = stamps[t * 5] * d, ho = stamps[t * 5 + 1] * d, wd = stamps[t * 5 + 2] * d,
          dy = stamps[t * 5 + 3] * d, mo = stamps[t * 5 + 4] * d, o = t * d;
        for (let i = 0; i < d; i++)
          x[o + i] += te.hour[ho + i] + te.weekday[wd + i] + te.day[dy + i] + te.month[mo + i] + te.minute[mi + i];
      }
    }
    return x;
  }

  newCache(capacity) {
    return {
      len: 0,
      layers: this.layers.map(() => ({ k: new Float32Array(capacity * this.d), v: new Float32Array(capacity * this.d), len: 0 })),
      // final-normed hidden states, and their projections as keys/values of the dependency layer
      ctx: new Float32Array(capacity * this.d),
      dk: new Float32Array(capacity * this.d),
      dv: new Float32Array(capacity * this.d),
    };
  }

  cloneCache(c) {
    return {
      len: c.len,
      layers: c.layers.map((l) => ({ k: l.k.slice(), v: l.v.slice(), len: l.len })),
      ctx: c.ctx.slice(),
      dk: c.dk.slice(),
      dv: c.dv.slice(),
    };
  }

  // decode_s1: runs the transformer over `len` new tokens, appending to cache.
  // Returns logits over s1 for the last position. Context is stored in cache.ctx.
  stepS1(s1, s2, stamps, len, cache) {
    let x = this.embed(s1, s2, stamps, len);
    for (let i = 0; i < this.layers.length; i++) {
      const lc = cache.layers[i];
      lc.len = cache.len;
      x = this.layers[i].forward(x, len, lc);
    }
    const h = rmsNorm(x, len, this.d, this.normW);
    cache.ctx.set(h, cache.len * this.d);
    cache.dk.set(linear(h, len, this.d, this.dkW, this.dkB, this.d), cache.len * this.d);
    cache.dv.set(linear(h, len, this.d, this.dvW, this.dvB, this.d), cache.len * this.d);
    cache.len += len;
    const last = h.subarray((len - 1) * this.d, len * this.d);
    return linear(last, 1, this.d, this.headS1W, this.headS1B, this.s1Vocab);
  }

  // decode_s2 for the last position: cross attention from emb_s1[s1Id] to the context.
  // During inference the query has length 1, so RoPE reduces to position 0 (identity).
  stepS2(s1Id, cache) {
    const d = this.d, len = cache.len, nh = this.depHeads, hd = d / nh;
    const sib = this.embS1.subarray(s1Id * d, (s1Id + 1) * d);
    const q = linear(sib, 1, d, this.dqW, this.dqB, d);
    const a = attention(q, 1, cache.dk.subarray(0, len * d), cache.dv.subarray(0, len * d), len, nh, hd, false, 0);
    const o = linear(a, 1, d, this.doW, this.doB, d);
    const lastCtx = cache.ctx.subarray((len - 1) * d, len * d);
    for (let i = 0; i < d; i++) o[i] += lastCtx[i];
    const x2 = rmsNorm(o, 1, d, this.depNormW);
    return linear(x2, 1, d, this.headS2W, this.headS2B, this.s2Vocab);
  }
}

// ---------------------------------------------------------------------------
// Sampling
// ---------------------------------------------------------------------------

export function mulberry32(seed) {
  let a = seed >>> 0;
  return () => {
    a = (a + 0x6d2b79f5) >>> 0;
    let t = a;
    t = Math.imul(t ^ (t >>> 15), t | 1);
    t ^= t + Math.imul(t ^ (t >>> 7), t | 61);
    return ((t ^ (t >>> 14)) >>> 0) / 4294967296;
  };
}

// Mirrors sample_from_logits / top_k_top_p_filtering from kronos.py.
export function sampleFromLogits(logits, { temperature = 1, topK = 0, topP = 1, greedy = false }, rand) {
  const n = logits.length;
  const l = new Float32Array(n);
  for (let i = 0; i < n; i++) l[i] = logits[i] / temperature;
  if (topK > 0) {
    const k = Math.min(Math.max(topK, 1), n);
    const sorted = Float32Array.from(l).sort().reverse();
    const thr = sorted[k - 1];
    for (let i = 0; i < n; i++) if (l[i] < thr) l[i] = -Infinity;
  } else if (topP < 1) {
    const idx = Array.from({ length: n }, (_, i) => i).sort((a, b) => l[b] - l[a]);
    const p = new Float32Array(n);
    for (let i = 0; i < n; i++) p[i] = l[idx[i]];
    softmaxInPlace(p);
    let cum = 0;
    for (let r = 0; r < n; r++) {
      // token r is removed if the cumulative prob *before* it already exceeds top_p
      if (r > 0 && cum > topP) l[idx[r]] = -Infinity;
      cum += p[r];
    }
  }
  softmaxInPlace(l);
  if (greedy) {
    let best = 0;
    for (let i = 1; i < n; i++) if (l[i] > l[best]) best = i;
    return best;
  }
  const u = rand();
  let c = 0;
  for (let i = 0; i < n; i++) {
    c += l[i];
    if (u < c) return i;
  }
  for (let i = n - 1; i >= 0; i--) if (l[i] > 0) return i;
  return 0;
}

// ---------------------------------------------------------------------------
// Predictor
// ---------------------------------------------------------------------------

export const FEATURES = ['open', 'high', 'low', 'close', 'volume', 'amount'];

// Calendar features as used by calc_time_stamps (weekday: Monday = 0).
export function timeFeatures(date) {
  return [date.getUTCMinutes(), date.getUTCHours(), (date.getUTCDay() + 6) % 7, date.getUTCDate(), date.getUTCMonth() + 1];
}

export class KronosPredictor {
  constructor(model, tokenizer, { maxContext = 512, clip = 5 } = {}) {
    this.model = model; this.tokenizer = tokenizer;
    this.maxContext = maxContext; this.clip = clip;
  }

  /**
   * rows: array of {open, high, low, close, volume?, amount?}
   * xTimes / yTimes: arrays of Date (interpreted in UTC as naive wall-clock times)
   * Returns array of predicted rows for yTimes.
   */
  async predict(rows, xTimes, yTimes, opts = {}) {
    const {
      temperature = 1.0, topK = 0, topP = 0.9, sampleCount = 1, seed = 0,
      greedy = false, onProgress = null,
    } = opts;
    const predLen = yTimes.length;
    const F = FEATURES.length;
    const hasVol = rows.every((r) => r.volume != null && !Number.isNaN(r.volume));
    const hasAmt = rows.every((r) => r.amount != null && !Number.isNaN(r.amount));

    // Only the last maxContext rows can ever be seen by the model.
    const T = rows.length;
    const x = new Float64Array(T * F);
    rows.forEach((r, t) => {
      const vol = hasVol ? +r.volume : 0;
      const amt = hasVol ? (hasAmt ? +r.amount : vol * (r.open + r.high + r.low + r.close) / 4) : 0;
      const vals = [+r.open, +r.high, +r.low, +r.close, vol, amt];
      for (let f = 0; f < F; f++) {
        if (!Number.isFinite(vals[f])) throw new Error(`Invalid value in row ${t} (${FEATURES[f]})`);
        x[t * F + f] = vals[f];
      }
    });
    const mean = new Float64Array(F), std = new Float64Array(F);
    for (let f = 0; f < F; f++) {
      let s = 0;
      for (let t = 0; t < T; t++) s += x[t * F + f];
      mean[f] = s / T;
      let v = 0;
      for (let t = 0; t < T; t++) v += (x[t * F + f] - mean[f]) ** 2;
      std[f] = Math.sqrt(v / T);
    }
    const xn = new Float32Array(T * F);
    for (let t = 0; t < T; t++)
      for (let f = 0; f < F; f++) {
        const z = (x[t * F + f] - mean[f]) / (std[f] + 1e-5);
        xn[t * F + f] = Math.max(-this.clip, Math.min(this.clip, z));
      }

    const stamps = new Float32Array((T + predLen) * 5);
    [...xTimes, ...yTimes].forEach((d, i) => stamps.set(timeFeatures(d), i * 5));

    const preds = await this.generate(xn, T, stamps, predLen, { temperature, topK, topP, sampleCount, seed, greedy, onProgress });

    const out = [];
    for (let t = 0; t < predLen; t++) {
      const row = { time: yTimes[t] };
      for (let f = 0; f < F; f++) row[FEATURES[f]] = preds[t * F + f] * (std[f] + 1e-5) + mean[f];
      out.push(row);
    }
    return out;
  }

  // Port of auto_regressive_inference for a single series.
  // xn: normalised [T, 6]; stamps: [T + predLen, 5]. Returns mean prediction [predLen, 6].
  async generate(xn, T, stamps, predLen, opts) {
    const { temperature, topK, topP, sampleCount, seed, greedy, onProgress } = opts;
    const tok = this.tokenizer, model = this.model, maxCtx = this.maxContext;
    const F = FEATURES.length;
    const { s1: xs1, s2: xs2 } = tok.encode(xn, T);
    const total = T + predLen;
    const sampling = { temperature, topK, topP, greedy };
    const rand = mulberry32(seed || 1);

    const yield_ = () => new Promise((r) => setTimeout(r, 0));
    const sum = new Float32Array(predLen * F);
    const totalSteps = sampleCount * predLen;

    // Prefill is identical for every sample, so compute it once and clone.
    const start0 = Math.max(0, T - maxCtx);
    const prefillLen = T - start0;
    let baseCache = null, baseLogits = null;
    if (T < maxCtx) {
      baseCache = model.newCache(Math.min(total, maxCtx));
      baseLogits = model.stepS1(xs1.subarray(start0), xs2.subarray(start0), stamps.subarray(start0 * 5, T * 5), prefillLen, baseCache);
    }

    for (let s = 0; s < sampleCount; s++) {
      const s1 = new Int32Array(total), s2 = new Int32Array(total);
      s1.set(xs1); s2.set(xs2);
      let cache = baseCache ? model.cloneCache(baseCache) : null;
      let logits = baseLogits;
      for (let i = 0; i < predLen; i++) {
        const cur = T + i; // tokens available so far
        if (i > 0 || !logits) {
          if (cur <= maxCtx && cache) {
            // incremental step with KV cache (positions unchanged)
            const p = cur - 1;
            logits = model.stepS1(s1.subarray(p, cur), s2.subarray(p, cur), stamps.subarray(p * 5, cur * 5), 1, cache);
          } else {
            // sliding window: positions shift, recompute the full window
            const st = Math.max(0, cur - maxCtx);
            cache = model.newCache(cur - st);
            logits = model.stepS1(s1.subarray(st, cur), s2.subarray(st, cur), stamps.subarray(st * 5, cur * 5), cur - st, cache);
          }
        }
        const a = sampleFromLogits(logits, sampling, rand);
        const b = sampleFromLogits(model.stepS2(a, cache), sampling, rand);
        s1[cur] = a; s2[cur] = b;
        if (cur >= maxCtx) cache = null; // force full recompute next step
        if (onProgress) onProgress((s * predLen + i + 1) / totalSteps);
        if ((i & 3) === 3) await yield_();
      }
      const st = Math.max(0, total - maxCtx);
      const z = tok.decode(s1.subarray(st), s2.subarray(st), total - st);
      const off = (total - st - predLen) * F;
      for (let i = 0; i < predLen * F; i++) sum[i] += z[off + i];
    }
    for (let i = 0; i < sum.length; i++) sum[i] /= sampleCount;
    return sum;
  }
}
