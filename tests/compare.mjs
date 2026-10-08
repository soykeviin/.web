import fs from 'fs';
const K = await import(process.argv[2]);
const dir = process.argv[3];
const load = (p) => { const b = fs.readFileSync(p); return K.parseSafetensors(b.buffer.slice(b.byteOffset, b.byteOffset + b.length)); };
const tc = JSON.parse(fs.readFileSync(dir + '/tok/config.json')), mc = JSON.parse(fs.readFileSync(dir + '/mdl/config.json'));
const tok = new K.KronosTokenizer(tc, load(dir + '/tok/model.safetensors'));
const mdl = new K.KronosModel(mc, load(dir + '/mdl/model.safetensors'));
const R = JSON.parse(fs.readFileSync(dir + '/ref.json'));
const { T, P } = R;
const x = Float32Array.from(R.x.flat()), st = Float32Array.from(R.stamps.flat());
const maxdiff = (a, b) => { let m = 0; a = a.flat ? a.flat() : a; for (let i = 0; i < b.length; i++) m = Math.max(m, Math.abs(a[i] - b[i])); return m; };
const { s1, s2 } = tok.encode(x, T);
const tokMis = R.s1.filter((v, i) => v !== s1[i]).length + R.s2.filter((v, i) => v !== s2[i]).length;
console.log('encode mismatches', tokMis);
console.log('decode maxdiff', maxdiff(R.dec, tok.decode(s1, s2, T)));
const cache = mdl.newCache(T);
console.log('s1 logits maxdiff', maxdiff(R.s1_logits, mdl.stepS1(s1, s2, st, T, cache)));
console.log('s2 logits maxdiff', maxdiff(R.s2_logits, mdl.stepS2(7, cache)));
for (const m of [512, 48, 30]) {
  const pr = new K.KronosPredictor(mdl, tok, { maxContext: m });
  const out = await pr.generate(x, T, st, P, { temperature: 1, topK: 1, topP: 0.99, sampleCount: 2, seed: 1, greedy: false });
  console.log(`autoregressive (max_context=${m}) maxdiff`, maxdiff(R[`ar_${m}`], out));
}
