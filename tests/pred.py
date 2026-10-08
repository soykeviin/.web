import sys, json, numpy as np, pandas as pd, torch
sys.path.insert(0, sys.argv[1])
from model.kronos import KronosTokenizer, Kronos, KronosPredictor
d = sys.argv[2]
tok = KronosTokenizer.from_pretrained(d + '/tok'); mdl = Kronos.from_pretrained(d + '/mdl')
rng = np.random.default_rng(3); T, P = 70, 15
c = 100 + np.cumsum(rng.normal(0, 1, T)); o = c + rng.normal(0, .3, T)
df = pd.DataFrame({'open': o, 'high': np.maximum(o, c) + .5, 'low': np.minimum(o, c) - .5, 'close': c, 'volume': rng.uniform(1e3, 5e3, T)})
xt = pd.Series(pd.date_range('2024-03-01 09:30', periods=T, freq='37min')); yt = pd.Series(pd.date_range(xt.iloc[-1] + pd.Timedelta('37min'), periods=P, freq='37min'))
for mc in (512, 50):
    p = KronosPredictor(mdl, tok, device='cpu', max_context=mc).predict(df, xt, yt, P, top_k=1, sample_count=1, verbose=False)
    json.dump({'rows': df.to_dict('records'), 'xt': [int(t.timestamp()*1000) for t in xt], 'yt': [int(t.timestamp()*1000) for t in yt], 'pred': p.values.tolist()}, open(f'{d}/pred_{mc}.json', 'w'))
print('ok')
