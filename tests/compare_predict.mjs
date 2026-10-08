import fs from 'fs';
const K = await import(process.argv[2]); const dir = process.argv[3];
const load = (p) => { const b = fs.readFileSync(p); return K.parseSafetensors(b.buffer.slice(b.byteOffset, b.byteOffset + b.length)); };
const tok = new K.KronosTokenizer(JSON.parse(fs.readFileSync(dir + '/tok/config.json')), load(dir + '/tok/model.safetensors'));
const mdl = new K.KronosModel(JSON.parse(fs.readFileSync(dir + '/mdl/config.json')), load(dir + '/mdl/model.safetensors'));
for (const mc of [512, 50]) {
  const R = JSON.parse(fs.readFileSync(`${dir}/pred_${mc}.json`));
  const out = await new K.KronosPredictor(mdl, tok, { maxContext: mc }).predict(R.rows, R.xt.map((t) => new Date(t)), R.yt.map((t) => new Date(t)), { topK: 1 });
  let m = 0; out.forEach((r, i) => K.FEATURES.forEach((f, j) => { m = Math.max(m, Math.abs(r[f] - R.pred[i][j]) / (Math.abs(R.pred[i][j]) + 1)); }));
  console.log(`predict() max_context=${mc} max rel diff`, m);
}
