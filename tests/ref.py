import sys, json, numpy as np, torch
sys.path.insert(0, sys.argv[1])
from model.kronos import KronosTokenizer, Kronos, auto_regressive_inference
torch.manual_seed(0)
learn_te = sys.argv[3] == '1'
out = sys.argv[2]
tok = KronosTokenizer(d_in=6, d_model=64, n_heads=4, ff_dim=96, n_enc_layers=3, n_dec_layers=3, ffn_dropout_p=0, attn_dropout_p=0, resid_dropout_p=0,
                      s1_bits=8, s2_bits=8, beta=0.05, gamma0=1.0, gamma=1.1, zeta=0.05, group_size=4).eval()
mdl = Kronos(s1_bits=8, s2_bits=8, n_layers=3, d_model=64, n_heads=4, ff_dim=128, ffn_dropout_p=0, attn_dropout_p=0, resid_dropout_p=0, token_dropout_p=0, learn_te=learn_te).eval()
# make weights less trivial
with torch.no_grad():
    for n, p in list(tok.named_parameters()) + list(mdl.named_parameters()):
        if 'norm' in n: p.add_(0.1 * torch.randn_like(p))
        if n.endswith('bias'): p.add_(0.05 * torch.randn_like(p))
tok.save_pretrained(out + '/tok'); mdl.save_pretrained(out + '/mdl')
T, P = 40, 20
x = torch.randn(1, T, 6).clamp(-5, 5)
ts = np.array([[m % 60, (m // 60) % 24, (m // 1440) % 7, 1 + (m // 1440) % 31, 1 + (m // 40000) % 12] for m in range(0, (T + P) * 37, 37)], dtype=np.float32)
xs = torch.from_numpy(ts[:T])[None]; ys = torch.from_numpy(ts[T:])[None]
res = {'x': x[0].tolist(), 'stamps': ts.tolist(), 'T': T, 'P': P}
with torch.no_grad():
    s1, s2 = tok.encode(x, half=True)
    res['s1'] = s1[0].tolist(); res['s2'] = s2[0].tolist()
    res['dec'] = tok.decode([s1, s2], half=True)[0].tolist()
    lg, ctx = mdl.decode_s1(s1, s2, xs)
    res['s1_logits'] = lg[0, -1].tolist()
    sid = torch.tensor([[7]])
    res['s2_logits'] = mdl.decode_s2(ctx, sid)[0, -1].tolist()
    for mc in (512, 48, 30):
        res[f'ar_{mc}'] = auto_regressive_inference(tok, mdl, x, xs, ys, mc, P, top_k=1, sample_count=2)[0, -P:].tolist()
json.dump(res, open(out + '/ref.json', 'w'))
print('ok')
