"""Canlı Codex kol izleyici: bugünkü (veya verilen) rollout dosyalarının son adımlarını gösterir.
Kullanım: python codex-watch.py [--since HH-MM] [--n 4]"""
import json, glob, os, sys, datetime, argparse
sys.stdout.reconfigure(encoding='utf-8')
ap = argparse.ArgumentParser(); ap.add_argument('--since', default=''); ap.add_argument('--n', type=int, default=4); ap.add_argument('--limit', action='store_true', help='yalnız limit satırı')
a = ap.parse_args()
d = datetime.date.today()
base = os.path.expanduser(f'~/.codex/sessions/{d:%Y/%m/%d}')
files = sorted(glob.glob(os.path.join(base, 'rollout-*.jsonl')))
if a.limit:
    y = d - datetime.timedelta(days=1)
    files = sorted(glob.glob(os.path.expanduser(f'~/.codex/sessions/{y:%Y/%m/%d}/rollout-*.jsonl'))) + files
if a.limit and not files:
    prev = sorted(glob.glob(os.path.expanduser('~/.codex/sessions/*/*/*/rollout-*.jsonl')))
    files = prev[-1:]
if a.since: files = [f for f in files if os.path.basename(f)[19:24] >= a.since]
latest = (0, None)
for f in files:
    L = []
    for line in open(f, encoding='utf-8'):
        try: L.append(json.loads(line))
        except Exception: pass
    model = cwd = eff = ''; tok = cached = outk = 0; steps = []; done = False; first = ''; last_ts = ''
    for x in L:
        t, p = x.get('type'), x.get('payload') or {}
        last_ts = x.get('timestamp', last_ts) or last_ts
        if t == 'turn_context': model, cwd, eff = p.get('model', ''), p.get('cwd', ''), p.get('effort') or p.get('reasoning_effort') or ''
        if t == 'event_msg' and p.get('type') == 'token_count':
            info = p.get('info') or {}; tu = info.get('total_token_usage') or {}; tok = tu.get('total_tokens', tok)
            cached = tu.get('cached_input_tokens', 0); outk = tu.get('output_tokens', 0)
            if p.get('rate_limits') and x.get('timestamp', '') > str(latest[0]): latest = (x.get('timestamp', ''), p['rate_limits'])
        if t == 'event_msg' and p.get('type') in ('task_complete', 'turn_complete'): done = True
        if t == 'response_item':
            pt = p.get('type')
            if pt in ('function_call', 'custom_tool_call', 'local_shell_call'):
                arg = p.get('arguments') or p.get('input') or json.dumps(p.get('action', ''))
                try:
                    j = json.loads(arg); arg = j.get('cmd') or j.get('command') or arg
                except Exception: pass
                steps.append('$ ' + ' '.join(arg) if isinstance(arg, list) else '$ ' + str(arg))
            elif pt == 'reasoning':
                s = ' '.join(i.get('text', '') for i in (p.get('summary') or []))
                if s: steps.append('~ ' + s)
            elif pt == 'message' and p.get('role') == 'user':
                txt = ' '.join(c.get('text', '') for c in p.get('content', []))
                if '# Görev' in txt or not first: first = txt
    title = next((l for l in first.splitlines() if l.startswith('# Görev') or l.startswith('# Task')), first.splitlines()[0][:60] if first else '?')
    # dosya mtime'ı Windows'ta açık dosyada geç güncellenir -> son olayın kendi zaman damgası kullanılır
    try: age = int((datetime.datetime.now(datetime.timezone.utc) - datetime.datetime.fromisoformat(last_ts.replace('Z', '+00:00'))).total_seconds())
    except Exception: age = int((datetime.datetime.now() - datetime.datetime.fromtimestamp(os.path.getmtime(f))).total_seconds())
    state = 'BİTTİ' if done else ('çalışıyor' if age < 900 else 'durmuş/kesilmiş')
    if a.limit: continue
    print(f"\n=== {title.strip()} | {model} {eff} | {state} | {tok:,} token (önbellek {cached:,}, çıktı {outk:,}) | son etkinlik {age}s önce")
    for s in (steps[-a.n:] if a.n and not a.limit else []): print('   ' + s.replace('\n', ' ')[:170])

if latest[1]:
    r = latest[1]; pr, se = dict(r.get('primary') or {}), dict(r.get('secondary') or {})
    now = datetime.datetime.now().timestamp()
    for w in (pr, se):  # sıfırlanma zamanı geçmişse kayıt bayattır: pencere %0
        if w.get('resets_at') and w['resets_at'] <= now: w['used_percent'] = 0.0; w['resets_at'] = None
    fmt = lambda t: datetime.datetime.fromtimestamp(t).strftime('%d %b %H:%M') if t else 'sıfırlandı'
    print(f"\nLİMİT ({r.get('plan_type')}): 5 saatlik %{pr.get('used_percent')} (sıfırlanma {fmt(pr.get('resets_at'))}) | haftalık %{se.get('used_percent')} (sıfırlanma {fmt(se.get('resets_at'))})")
