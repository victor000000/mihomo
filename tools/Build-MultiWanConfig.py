#!/usr/bin/env python3
"""Mihomo-only policy: four adapter paths, stable application routes, no VM."""
import argparse
import copy
import json
from pathlib import Path
import yaml

ADAPTERS = ['win_turbo_phone', 'pisen_2026_10', 'jd_5G', 'pisen_2026_03']
URL = 'https://www.google.com/generate_204'
RETIRED = {'omr', 'GATEWAY-WAN', 'WINDOWS-EMERGENCY', 'HYPOMUX-PATH', 'hypomux'}
PERFORMANCE_GROUPS = {'TOKYO-ACTIVE', 'LA-ACTIVE'}

def remove_911(config):
    """Retire the expiring Connect911 subscription, including legacy config inputs."""
    c = copy.deepcopy(config)
    providers = c.setdefault('proxy-providers', {})
    removed = {n for n, p in providers.items() if n == 'clashmi' or n.startswith('wan911-') or 'connect911.' in p.get('url', '')}
    c['proxy-providers'] = {n: p for n, p in providers.items() if n not in removed}
    c['rule-providers'] = {n: p for n, p in c.get('rule-providers', {}).items() if n != 'clashmi-911'}
    removed_groups = {g['name'] for g in c['proxy-groups'] if g['name'].startswith('911-')}
    for g in c['proxy-groups']:
        if 'use' in g:
            g['use'] = [n for n in g['use'] if n not in removed]
            if not g['use']:
                g.pop('use')
        if 'proxies' in g:
            g['proxies'] = [n for n in g['proxies'] if n not in removed_groups]
        if g['name'] not in removed_groups and not g.get('proxies') and not g.get('use'):
            g['proxies'] = ['aliyun-tokyo']
    c['proxy-groups'] = [g for g in c['proxy-groups'] if g['name'] not in removed_groups]
    c['rules'] = [r for r in c.get('rules', []) if not r.startswith('RULE-SET,clashmi-911,')]
    policy = c.get('dns', {}).get('nameserver-policy', {})
    for n in list(policy):
        if 'connect911.' in n:
            del policy[n]
    return c

def apply_performance_policy(config, standby_adapters=()):
    """Keep slow adapters as automatic backup without assigning routine flows to them."""
    c = copy.deepcopy(config)
    standby = set(standby_adapters)
    if not standby <= set(ADAPTERS):
        raise ValueError('Unknown standby adapter')
    if not standby:
        if any(g['name'] in PERFORMANCE_GROUPS for g in c['proxy-groups']):
            raise ValueError('Rebuild the configuration to restore all-adapter balancing')
        return c
    active = [a for a in ADAPTERS if a not in standby]
    if not active:
        raise ValueError('At least one adapter must remain active')
    c['proxy-groups'] = [g for g in c['proxy-groups'] if g['name'] not in PERFORMANCE_GROUPS]
    groups = {g['name']: g for g in c['proxy-groups']}
    for pool, prefix in [('TOKYO', 'BALANCED-'), ('LA', 'LA-')]:
        g = groups.get(pool+'-POOL')
        if g is None:
            continue
        health = {k: copy.deepcopy(g[k]) for k in ('url', 'interval', 'timeout', 'lazy', 'expected-status') if k in g}
        common = dict(type='load-balance', strategy='round-robin', **health)
        primary = dict(name=pool+'-ACTIVE', **common)
        primary['proxies'] = [prefix+a for a in active]
        backups = [prefix+a for a in ADAPTERS if a in standby]
        c['proxy-groups'].append(primary)
        g.clear()
        g.update(name=pool+'-POOL', type='fallback', proxies=[primary['name']]+backups, **health)
    return c

def transform(config, standby_adapters=()):
    c = remove_911(config)
    # Mihomo uses full subscription URLs as database keys when ETag caching is enabled.
    c['etag-support'] = False
    c['proxies'] = [p for p in c['proxies'] if p['name'] not in RETIRED and not p['name'].startswith(('WAN-', 'BALANCED-', 'LA-'))]
    nodes = {p['name']: p for p in c['proxies']}
    if not {'aliyun-tokyo', 'aliyun-la'} <= nodes.keys():
        raise ValueError('Tokyo and LA definitions are required')
    for p in c['proxies']:
        p['dialer-proxy'] = 'DISPATCH'
        p.pop('interface-name', None)
    c['proxies'] += [dict(name='WAN-'+a, type='direct', **{'interface-name':a}) for a in ADAPTERS]
    c['proxy-groups'] = [g for g in c['proxy-groups'] if g['name'] not in RETIRED | PERFORMANCE_GROUPS and not g['name'].startswith('PATH-') and g['name'] not in ('TOKYO-POOL','LA-POOL','911-POOL')]
    groups = {g['name']:g for g in c['proxy-groups']}
    for g in c['proxy-groups']:
        if 'proxies' in g:
            g['proxies'] = [n for n in g['proxies'] if n not in RETIRED]
    groups['DISPATCH'].update(type='fallback', proxies=['WAN-'+a for a in ADAPTERS]+['DIRECT'], url='https://www.baidu.com/', interval=15, timeout=4000, lazy=False)
    providers = c.setdefault('proxy-providers', {})
    # Dispatch's internal inline providers are not subscription alternatives for
    # application groups. The overlay rebuilds them after the legacy transform.
    originals = [n for n in providers if not n.startswith('ADAPTIVE-NODES-')]
    for name in originals:
        providers[name].setdefault('override', {})['dialer-proxy'] = 'DISPATCH'
    paths=[]
    for a in ADAPTERS:
        members=[]
        for prefix, source in [('BALANCED-', 'aliyun-tokyo'), ('LA-', 'aliyun-la')]:
            node=copy.deepcopy(nodes[source]);node.update(name=prefix+a, **{'interface-name':a});node.pop('dialer-proxy',None)
            c['proxies'].append(node);members.append(node['name'])
        paths.append('BALANCED-'+a)
    common=dict(type='load-balance',strategy='round-robin',url=URL,interval=30,timeout=5000,lazy=False)
    c['proxy-groups'].append(dict(name='TOKYO-POOL',proxies=paths.copy(),**common))
    c['proxy-groups'].append(dict(name='LA-POOL',proxies=['LA-'+a for a in ADAPTERS],**common))
    choices=['TOKYO-POOL','LA-POOL']
    for name in ('AUTO','DATA'):
        g=groups[name]
        for k in ('use','filter','exclude-filter','tolerance','strategy'):g.pop(k,None)
        g.update(type='fallback',proxies=choices.copy(),url=URL,interval=30,timeout=5000,lazy=False)
    for name in ('LINGODA','ZOOM','CHATGPT','ANTHROPIC','GOOGLE','IB','DEV'):
        if name not in groups:continue
        g=groups[name]
        # Preserve explicitly configured direct classroom paths across rebuilds.
        direct_choices = ['WAN-'+a for a in ADAPTERS]
        codex_choices = [prefix+a for prefix in ('BALANCED-', 'LA-') for a in ADAPTERS]
        preferred=[n for n in g.get('proxies',[]) if
                   (name in ('LINGODA','ZOOM') and n in direct_choices) or
                   (name == 'CHATGPT' and n in codex_choices)]
        rest=[n for n in g.get('proxies',[]) if n not in preferred+['aliyun-tokyo','aliyun-la']]
        g.update(type='fallback',proxies=preferred+['aliyun-tokyo','aliyun-la']+rest,interval=30,timeout=5000,lazy=False)
        if originals:g['use']=originals.copy()
    # Remove rules referring to retired groups without changing domain policy.
    c['rules']=[','.join('AUTO' if part in RETIRED else part for part in rule.split(',')) for rule in c.get('rules',[])]
    c.setdefault('tun',{})['enable']=False
    return apply_performance_policy(c, standby_adapters)

if __name__=='__main__':
    p=argparse.ArgumentParser();p.add_argument('--input',required=True);p.add_argument('--output',required=True)
    p.add_argument('--policy', default=str(Path(__file__).resolve().parents[1]/'config/network-architecture.json'))
    p.add_argument('--dispatch-policy', default=str(Path(__file__).resolve().parents[1]/'config/dispatch-policy.json'))
    a=p.parse_args()
    data=yaml.safe_load(Path(a.input).read_text(encoding='utf-8-sig'))
    policy=json.loads(Path(a.policy).read_text(encoding='utf-8-sig'))
    result = transform(data, policy.get('standbyAdapters', []))
    if Path(a.dispatch_policy).exists():
        from AdaptiveDispatch import apply_policy
        result = apply_policy(result, json.loads(Path(a.dispatch_policy).read_text(encoding='utf-8-sig')))
    Path(a.output).write_text(yaml.safe_dump(result,allow_unicode=True,sort_keys=False),encoding='utf-8')
