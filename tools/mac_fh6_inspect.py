#!/usr/bin/env python3
"""Report, in French, on a run with the shim's inspector (HB_TSSHIM_INSPECT=1, tools/tsshim/inspect.c).

Reads the inspector's log (C:\\highball\\logs\\inspect-<pid>.log, the newest one by default) and, when given, the Wine
log of the same run (out/fh6-after.log), and says piece by piece what was created and what failed, and for each
pipeline whether its draws wrote pixels and, when they did not, at which step the pixels were lost (from the
inspector's twins): nothing on screen, culled, discarded by the pixel shader, rejected by the depth test or by the
stencil test. Reads only.
Usage: mac_fh6_inspect.py [--wine <wine log>] [--out <report>] [<inspect log>]
       mac_fh6_inspect.py --probe <inspect log>     checks tools/inspectprobe's eight cases against their answer"""
import glob
import os
import re
import sys
from collections import Counter, defaultdict

CATS = ['LIT', 'ZERO', 'EMPTY', 'CULLED', 'DISCARD', 'DEPTH', 'STENCIL']
LABEL = {
    'LIT': 'dessine (des pixels sont écrits)',
    'ZERO': "n'écrit rien (pas encore analysé)",
    'EMPTY': "rien à l'écran (géométrie vide, hors de l'écran, ou 0 instance)",
    'CULLED': 'triangles retirés par le culling (sens des faces)',
    'DISCARD': 'le pixel shader jette tous ses pixels (discard / alpha)',
    'DEPTH': 'tous les pixels refusés par le test de profondeur',
    'STENCIL': 'tous les pixels refusés par le test de stencil',
}
FUNC = {1: 'NEVER', 2: 'LESS', 3: 'EQUAL', 4: 'LESS_EQUAL', 5: 'GREATER', 6: 'NOT_EQUAL', 7: 'GREATER_EQUAL', 8: 'ALWAYS'}
ARITY = {'hr': 1, 'depth': 3, 'stencil': 1, 'cull': 1, 'rt': 2, 'dsv': 1, 'samples': 1, 'a2c': 1, 'uav': 1, 'copy': 1, 'watch': 1}


def parse_inspect(path):
    run = {'psos': {}, 'stats': {}, 'equal': {}, 'twins': {}, 'investigated': {}, 'fails': [], 'ticks': [], 'res': {}, 'removed': None,
           'start': '', 'device': '', 'end': False, 'duration': 0.0, 'cmdsigs': 0}
    for line in open(path, errors='replace'):
        w = line.split()
        if len(w) < 2:
            continue
        try:
            t = float(w[0])
        except ValueError:
            continue
        run['duration'] = max(run['duration'], t)
        k = w[1]
        if k == 'pso' and len(w) >= 4:
            p = {'id': int(w[2]), 'kind': w[3], 'shaders': {}, 't': t}
            i = 4
            while i < len(w):
                tok = w[i]
                if '=' in tok:
                    stage, tag = tok.split('=', 1)
                    digest, _, name = tag.partition(':')
                    p['shaders'][stage] = (digest, name or '-')
                    i += 1
                elif tok in ARITY:
                    n = ARITY[tok]
                    vals = w[i + 1:i + 1 + n]
                    p[tok] = vals[0] if n == 1 else vals
                    i += 1 + n
                else:
                    i += 1
            run['psos'][p['id']] = p
        elif k == 'stat' and len(w) >= 3:
            s = {'id': int(w[2])}
            i = 3
            while i < len(w):
                if w[i] == 'cat':
                    s['cat'] = [int(x) for x in w[i + 1:i + 8]]; i += 8
                elif w[i] == 'tw':
                    s['tw'] = [int(x) for x in w[i + 1:i + 5]]; i += 5
                elif i + 1 < len(w):
                    s[w[i]] = int(w[i + 1]); i += 2
                else:
                    i += 1
            run['stats'][s['id']] = s
        elif k == 'equal' and len(w) >= 20:
            # equal <id> failed <n> ps <ps> rec <4> all ps <ps> real <real> rec <4>
            run['equal'][int(w[2])] = {'failed': int(w[4]), 'ps': int(w[6]), 'rec': [int(x) for x in w[8:12]],
                                       'all_ps': int(w[14]), 'all_real': int(w[16]), 'all_rec': [int(x) for x in w[18:22]]}
        elif k == 'twin' and len(w) >= 9:
            run['twins'][int(w[2])] = (int(w[4]), int(w[6]), w[8])
        elif k == 'investigate' and len(w) >= 4:
            run['investigated'][int(w[2])] = w[3]
        elif k == 'fail':
            run['fails'].append(' '.join(w[2:]))
        elif k == 'tick':
            d = {w[i]: int(w[i + 1]) for i in range(2, len(w) - 1, 2)}
            d['t'] = t
            run['ticks'].append(d)
        elif k == 'res':
            i, d = 2, {}
            while i < len(w):
                if w[i] == 'tilemappings':
                    d['tilemappings'] = (int(w[i + 1]), 0); i += 2
                else:
                    d[w[i]] = (int(w[i + 1]), int(w[i + 2])); i += 3
            run['res'] = d
        elif k == 'removed':
            run['removed'] = ' '.join(w[2:])
        elif k == 'start':
            run['start'] = ' '.join(w[2:])
        elif k == 'device':
            run['device'] = ' '.join(w[2:])
        elif k == 'cmdsig':
            run['cmdsigs'] += 1
        elif k == 'end':
            run['end'] = True
    return run


def parse_wine(path):
    out = {'noop': {}, 'faults': [], 'unhandled': [], 'refused_completion': [], 'dll_fail': [], 'err': Counter(),
           'loaded': Counter(), 'fatal_hr': []}
    if not path or not os.path.exists(path):
        return None
    for raw in open(path, 'rb'):
        line = raw.decode('utf-8', 'replace').rstrip('\r\n')
        m = re.search(r'marking PSO\((\d+)\) as no-op', line)
        if m:
            r = re.search(r'Code=\d+ "([^"]{0,140})', line)
            out['noop'][int(m.group(1))] = r.group(1) if r else line[:140]
            continue
        if 'FHTRACE' in line:
            continue
        if ':err:fh6fault:' in line:
            if 'fh6_fault_report code' in line:
                out['faults'].append(line.split('fh6_fault_report ', 1)[1][:160])
            elif 'fh6_fault_report regs' in line:
                m = re.search(r'rax ([0-9a-f]+)', line)
                if m and m.group(1).startswith('ffffffff8'):
                    out['fatal_hr'].append('0x' + m.group(1)[8:])
            continue
        if 'Unhandled' in line and 'wine:' in line:
            out['unhandled'].append(line[:200])
        elif 'not calling completion routine' in line:
            out['refused_completion'].append(line[:200])
        elif ':trace:loaddll:' in line and 'Loaded' in line:
            out['loaded']['native' if 'native' in line else 'builtin'] += 1
        elif re.search(r':err:module:(import_dll|load_dll|LdrInitializeThunk)', line) or 'not found' in line and ':err:module:' in line:
            out['dll_fail'].append(line[:200])
        m = re.match(r'^[0-9a-f]+:err:([a-z0-9_]+):([A-Za-z0-9_]+)', line)
        if m:
            out['err'][m.group(1) + ':' + m.group(2)] += 1
    return out


def pso_name(p):
    for stage in ('ps', 'vs', 'ms', 'cs'):
        if stage in p['shaders'] and p['shaders'][stage][1] != '-':
            return p['shaders'][stage][1]
    return p['kind'] + ' sans nom'


def dominant(cat):
    if not cat or not sum(cat):
        return None
    explained = [(n, CATS[i]) for i, n in enumerate(cat) if CATS[i] != 'ZERO' and n]
    if explained:
        return max(explained)[1]
    return 'ZERO'


def depth_text(p):
    d = p.get('depth')
    if not d:
        return '?'
    if d[0] == '0':
        return 'pas de test'
    return f"{FUNC.get(int(d[2]), d[2])}{', écrit' if d[1] == '1' else ', sans écrire'}"


def suspect(p, cause):
    """Why a cause is abnormal for this pipeline, or None when it is ordinary (a hidden or culled object)."""
    if cause == 'DEPTH' and p.get('depth') and p['depth'][0] == '1' and p['depth'][2] == '3':
        return "test EQUAL : la passe ne retrouve pas la profondeur écrite par sa pré-passe"
    if cause == 'CULLED':
        return 'les triangles sont tous à l’envers'
    if cause == 'DISCARD':
        return 'le pixel shader ne garde aucun pixel'
    return None


EQ_LABELS = ['plus près ou égal', 'plus loin ou égal', 'plus près ou égal + marge 64', 'plus près ou égal + marge 4096 et pente 1']


def probe_check(run):
    expected = {0: 'LIT', 1: 'DEPTH', 2: 'DISCARD', 3: 'CULLED', 4: 'EMPTY', 5: 'STENCIL', 6: 'DEPTH', 7: 'LIT', 8: 'DEPTH'}
    names = {0: 'ok', 1: 'depth', 2: 'discard', 3: 'culled', 4: 'offscreen', 5: 'stencil', 6: 'stream', 7: 'indirect', 8: 'close'}
    # which of the EQUAL variants (GE, LE, GE+64, GE+4096) let the failed draws' pixels through
    eq_expected = {1: [1, 0, 1, 1], 6: [1, 0, 1, 1], 8: [0, 1, 1, 1]}
    good = 0
    for i, want in expected.items():
        s = run['stats'].get(i, {})
        got = dominant(s.get('cat'))
        twins = [v for seq, (pid, v, hr) in run['twins'].items() if pid == i and hr == '0x00000000']
        extra = f"sampled {s.get('sampled', 0)} lit {s.get('lit', 0)} cat {s.get('cat')} tw {s.get('tw')} twins ok {sorted(twins)}"
        if i == 7:
            extra += f" indirect {s.get('indirect', 0)}"
        ok = got == want and (i != 7 or s.get('indirect', 0) > 0)
        if i in eq_expected:
            e = run['equal'].get(i)
            pattern = [int(r * 2 > e['ps']) for r in e['rec']] if e and e['ps'] else None
            extra += f" equal-variants {pattern} (expected {eq_expected[i]})"
            ok = ok and pattern == eq_expected[i]
        good += ok
        print(f"PROBE-CHECK case {i} {names[i]:<9} expected {want:<7} got {str(got):<7} {'ok' if ok else 'FAIL'}   {extra}")
    tick = run['ticks'][-1] if run['ticks'] else {}
    print(f"PROBE-CHECK {good}/{len(expected)} ok; sampled draws {tick.get('sampleddraws')}, no free slot {tick.get('noslot')}, lost {tick.get('lost')},"
          f" device {run['device']}")
    return good == len(expected)


def report(run, wine, log_path, wine_path):
    psos, stats = run['psos'], run['stats']
    twin_ids = set(run['twins'])
    out = []
    say = out.append
    dur = run['duration']
    say(f"== Inspecteur FH6 : {os.path.basename(log_path)}, {int(dur // 60)} min {int(dur % 60)} s de jeu"
        f"{'' if run['end'] else ' (le jeu ne s’est pas fermé normalement)'}")
    say(f"   réglages : {run['start']}")
    say('')

    say('-- 1. Ce qui a été chargé')
    kinds = Counter(p['kind'] for p in psos.values())
    failed = [p for p in psos.values() if p.get('hr', '0x00000000') != '0x00000000']
    noop = wine['noop'] if wine else {}
    # D3DMetal's PSO numbers are the inspector's only when it created pipelines one at a time (HB_TSSHIM_INSPECT_SERIAL=1)
    serial = ' serial 1 ' in f" {run['start']} " or ' serial ' not in f" {run['start']} "
    noop_game = {n: r for n, r in noop.items() if n in psos} if serial else {}
    noop_twin = {n: r for n, r in noop.items() if n in twin_ids} if serial else {}
    say(f"   pipelines : {len(psos)} créés ({', '.join(f'{n} {k}' for k, n in kinds.most_common())})")
    say(f"   refusés à la création (D3D12) : {len(failed)}")
    for p in failed[:15]:
        say(f"     - pipeline {p['id']} {pso_name(p)} : hr {p.get('hr')}")
    if wine is not None:
        if serial:
            say(f"   marqués « no-op » par D3DMetal (ne dessineront jamais) : {len(noop_game)}"
                + (f" (et {len(noop_twin)} jumeaux de l'inspecteur)" if noop_twin else ''))
        else:
            say(f"   marqués « no-op » par D3DMetal (ne dessineront jamais) : {len(noop)} (jumeaux compris ; numéros non reliés aux"
                " pipelines sans HB_TSSHIM_INSPECT_SERIAL=1)")
        by_reason = Counter(noop_game.values())
        for r, n in by_reason.most_common(8):
            say(f"     - {n} × {r}")
        names = Counter(pso_name(psos[n]) for n in noop_game)
        for nm, n in names.most_common(10):
            say(f"       {n} × {nm}")
    else:
        say('   (pas de journal Wine : les « no-op » de D3DMetal ne sont pas comptés)')
    res = run['res']
    if res:
        labels = {'committed': 'ressources (committed)', 'placed': 'ressources (placed)', 'reserved': 'ressources (reserved, streaming de textures)',
                  'heap': 'tas mémoire', 'rootsig': 'root signatures', 'cmdsig': 'command signatures', 'descheap': 'tas de descripteurs',
                  'cmdlist': 'listes de commandes'}
        for key, label in labels.items():
            ok, bad = res.get(key, (0, 0))
            say(f"   {label:<45} {ok:>7} réussis, {bad} échecs")
        say(f"   mises à jour de tuiles (UpdateTileMappings) : {res.get('tilemappings', (0, 0))[0]}")
    if run['fails']:
        say(f"   échecs détaillés ({len(run['fails'])}) :")
        for f in Counter(run['fails']).most_common(15):
            say(f"     - {f[1]} × {f[0][:150]}")
    if run['removed']:
        say(f"   !! le GPU a été perdu (device removed) : {run['removed']}")
    say('')

    say('-- 2. Ce que chaque dessin met à l’écran (mesuré par fenêtres de quelques images)')
    tick = run['ticks'][-1] if run['ticks'] else {}
    say(f"   dessins mesurés : {tick.get('sampleddraws', 0)} ; fenêtres : {tick.get('bursts', 0)} ; dessins sans pipeline connu : {tick.get('unknowndraws', 0)}")
    if tick.get('noslot') or tick.get('lost') or tick.get('gamequery'):
        say(f"   non mesurés : {tick.get('noslot', 0)} (plus de place), {tick.get('gamequery', 0)} (le jeu mesurait déjà), {tick.get('lost', 0)} perdus")
    drawn = {i: s for i, s in stats.items() if i in psos and s.get('sampled', 0) > 0}
    lit = [i for i, s in drawn.items() if s.get('lit', 0) > 0]
    dark = [i for i, s in drawn.items() if s.get('lit', 0) == 0]
    say(f"   pipelines mesurés : {len(drawn)} ; qui dessinent : {len(lit)} ; qui n'écrivent aucun pixel : {len(dark)}")
    causes = Counter(dominant(drawn[i].get('cat')) for i in dark)
    for c, n in causes.most_common():
        say(f"     {n:>5} × {LABEL.get(c, c)}")
    say('')

    sus = []
    for i in dark:
        p, c = psos[i], dominant(drawn[i].get('cat'))
        why = suspect(p, c)
        if why:
            sus.append((p, drawn[i], c, why))
    say(f"-- 3. Anomalies (une cause qui ne devrait pas arriver) : {len(sus)}")
    groups = defaultdict(list)
    for p, s, c, why in sus:
        groups[(pso_name(p), c, why)].append((p, s))
    for (name, c, why), items in sorted(groups.items(), key=lambda kv: -sum(s.get('draws', 0) for p, s in kv[1])):
        draws = sum(s.get('draws', 0) + s.get('indirect', 0) for p, s in items)
        say(f"   - {name} : {len(items)} pipeline(s), {draws} dessins -> {LABEL[c]}")
        say(f"       {why} ; profondeur {depth_text(items[0][0])}, culling {items[0][0].get('cull', '?')}, pipelines {', '.join(str(p['id']) for p, s in items[:8])}")
    say('')

    eq_rows = defaultdict(lambda: {'ids': set(), 'failed': 0, 'ps': 0, 'rec': [0] * 4, 'all_ps': 0, 'all_real': 0, 'all_rec': [0] * 4})
    for i, e in run['equal'].items():
        if i not in psos:
            continue
        r = eq_rows[pso_name(psos[i])]
        r['ids'].add(i); r['failed'] += e['failed']; r['ps'] += e['ps']; r['all_ps'] += e['all_ps']; r['all_real'] += e['all_real']
        for j in range(4):
            r['rec'][j] += e['rec'][j]; r['all_rec'][j] += e['all_rec'][j]
    if eq_rows:
        say(f"-- 3b. Passes à profondeur EQUAL (après une pré-passe) : ce que chaque test de remplacement aurait laissé passer")
        say("   (en % des pixels que le pixel shader produit ; « réel » = ce que le jeu obtient avec EQUAL)")
        for name, r in sorted(eq_rows.items(), key=lambda kv: -kv[1]['all_ps']):
            if not r['all_ps']:
                continue
            pct = lambda x, tot: f"{100.0 * x / tot:5.1f} %" if tot else '   -  '
            say(f"   - {name} ({len(r['ids'])} pipelines) : réel {pct(r['all_real'], r['all_ps'])} ; "
                + ' ; '.join(f"{EQ_LABELS[j]} {pct(r['all_rec'][j], r['all_ps'])}" for j in range(4)))
            if r['failed']:
                say(f"       dessins entièrement refusés : {r['failed']} ; récupérés : "
                    + ' ; '.join(f"{EQ_LABELS[j]} {pct(r['rec'][j], r['ps'])}" for j in range(4)))
        say('')

    watched = [p for p in psos.values() if p.get('watch') == '1']
    if watched:
        say(f"-- 4. Pipelines surveillés ({run['start'].split('watch ')[-1]}) : {len(watched)}")
        rows = defaultdict(lambda: [0, 0, 0, [0] * 7, set(), set()])
        for p in watched:
            s = stats.get(p['id'], {})
            r = rows[pso_name(p)]
            r[0] += s.get('draws', 0) + s.get('indirect', 0); r[1] += s.get('sampled', 0); r[2] += s.get('lit', 0)
            for j, n in enumerate(s.get('cat', [0] * 7)):
                r[3][j] += n
            r[4].add(depth_text(p)); r[5].add(p['id'])
        for name, (draws, sampled, litn, cat, depths, ids) in sorted(rows.items(), key=lambda kv: -kv[1][0]):
            if not draws:
                continue
            parts = ', '.join(f"{CATS[j]} {n}" for j, n in enumerate(cat) if n)
            say(f"   - {name} : {draws} dessins, {sampled} mesurés, {litn} avec pixels ; {parts or 'aucune mesure'}")
            say(f"       profondeur : {' / '.join(sorted(depths))} ; pipelines {', '.join(str(i) for i in sorted(ids)[:10])}")
        say('')

    if wine is not None:
        say('-- 5. Plantages et erreurs (journal Wine)')
        say(f"   DLL chargées : {wine['loaded']['builtin']} intégrées à Wine, {wine['loaded']['native']} natives ; échecs de chargement : {len(wine['dll_fail'])}")
        for l in wine['dll_fail'][:8]:
            say(f"     - {l}")
        for l in wine['unhandled'][:5]:
            say(f"   plantage : {l}")
        for l in wine['faults'][:5]:
            say(f"   faute : {l}")
        for hr in wine['fatal_hr'][:5]:
            say(f"   le jeu s'est arrêté exprès sur l'erreur {hr}")
        for l in wine['refused_completion'][:5]:
            say(f"   rappel asynchrone refusé : {l}")
        say('   erreurs Wine les plus fréquentes :')
        for k, n in wine['err'].most_common(10):
            say(f"     {n:>7} × {k}")
    return '\n'.join(out)


def main(argv):
    wine_path = out_path = None
    probe = False
    args = []
    i = 0
    while i < len(argv):
        if argv[i] == '--wine':
            wine_path = argv[i + 1]; i += 2
        elif argv[i] == '--out':
            out_path = argv[i + 1]; i += 2
        elif argv[i] == '--probe':
            probe = True; i += 1
        else:
            args.append(argv[i]); i += 1
    if args:
        log_path = args[0]
    else:
        logs = glob.glob(os.path.expanduser('~/FH6/.blackwell-wine/drive_c/highball/logs/inspect-*.log'))
        if not logs:
            print('pas de journal de l’inspecteur (lancer le jeu avec HB_TSSHIM_INSPECT=1)')
            return 1
        log_path = max(logs, key=os.path.getmtime)
    run = parse_inspect(log_path)
    if probe:
        return 0 if probe_check(run) else 1
    text = report(run, parse_wine(wine_path), log_path, wine_path)
    print(text)
    if out_path:
        open(out_path, 'w').write(text + '\n')
    return 0


if __name__ == '__main__':
    sys.exit(main(sys.argv[1:]))
