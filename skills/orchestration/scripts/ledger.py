"""Orkestrasyon defteri özeti: ~/.claude/orchestration/ledger.jsonl (codex.ps1 ve gemini.ps1 yazar).
Kullanım: python ledger.py [--days 7] [--last 15]
Her model/mod için çalıştırma sayısı, durumlar, ortalama süre, token ve Codex 5 saatlik limitten yenen pay."""
import json, os, sys, argparse, datetime, collections
sys.stdout.reconfigure(encoding='utf-8')
ap = argparse.ArgumentParser(); ap.add_argument('--days', type=int, default=7); ap.add_argument('--last', type=int, default=10)
a = ap.parse_args()
path = os.path.expanduser('~/.claude/orchestration/ledger.jsonl')
if not os.path.exists(path): sys.exit('Defter yok: ' + path)
since = datetime.datetime.now(datetime.timezone.utc) - datetime.timedelta(days=a.days)
rows = []
for line in open(path, encoding='utf-8-sig'):
    try: r = json.loads(line)
    except Exception: continue
    try: ts = datetime.datetime.fromisoformat(r['ts'])
    except Exception: continue
    if ts.tzinfo is None: ts = ts.astimezone()
    if ts >= since and r.get('lane') != 'test': rows.append(r)
g = collections.defaultdict(list)
for r in rows: g[(r.get('family'), r.get('model'), r.get('mode'), r.get('effort', ''))].append(r)
print(f"Son {a.days} gün, {len(rows)} kayıt\n")
print(f"{'aile':7} {'model':24} {'mod':8} {'seviye':7} {'n':>3} {'ok':>3} {'engel':>5} {'limit':>5} {'ort.sn':>7} {'ort.token':>10} {'5s limit Δ ort.':>15}")
for k, v in sorted(g.items(), key=lambda kv: -len(kv[1])):
    st = collections.Counter(x.get('status') for x in v)
    secs = [x['seconds'] for x in v if isinstance(x.get('seconds'), (int, float))]
    toks = [(x.get('tokens_in') or 0) + (x.get('tokens_out') or 0) for x in v if x.get('tokens_in')]
    d = [x['limit5h_after'] - x['limit5h_before'] for x in v
         if isinstance(x.get('limit5h_after'), (int, float)) and isinstance(x.get('limit5h_before'), (int, float))]
    avg = lambda L: sum(L) / len(L) if L else 0
    print(f"{k[0] or '?':7} {k[1] or '?':24} {k[2] or '?':8} {k[3] or '':7} {len(v):>3} {st['ok']:>3} {st['blocked']:>5} {st['limit'] + st['quota']:>5} "
          f"{avg(secs):>7.0f} {avg(toks):>10,.0f} {('%+.1f' % avg(d)) if d else '-':>15}")
print(f"\nSon {a.last} çalıştırma:")
for r in rows[-a.last:]:
    print(f"  {r['ts'][:16]} {r.get('family')}/{r.get('model')}/{r.get('mode')} {r.get('effort','')} lane={r.get('lane') or '-'} "
          f"durum={r.get('status')} 5s:{r.get('limit5h_before','-')}→{r.get('limit5h_after','-')} {r.get('reason') or ''}")
