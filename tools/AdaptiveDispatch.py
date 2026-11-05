#!/usr/bin/env python3
"""Capacity-aware weighted proxy rotation and sticky direct traffic for Mihomo.

Only selector preferences are changed at runtime; existing connections, application
rules, native routes and credentials are never edited by the controller.
"""
import argparse
import collections
import copy
import datetime as dt
import hashlib
import json
import logging
from logging.handlers import RotatingFileHandler
import math
import os
from pathlib import Path
import re
import time
import urllib.error
import urllib.parse
import urllib.request

ADAPTERS = ('win_turbo_phone', 'pisen_2026_10', 'jd_5G', 'pisen_2026_03')
REGIONS = {
    'WAN': ('WAN-', 'WAN-ACTIVE', 'https://www.baidu.com/', '200-399'),
    'TOKYO': ('BALANCED-', 'TOKYO-ACTIVE', 'https://www.google.com/generate_204', '204'),
    'LA': ('LA-', 'LA-ACTIVE', 'https://www.google.com/generate_204', '204'),
}


def utc():
    return dt.datetime.now(dt.timezone.utc).isoformat()


def managed_path(region, adapter):
    return f'ADAPTIVE-PATH-{region}-{adapter}'


def retire_paid_alias(config):
    """Retire the legacy group name without changing its general-proxy routing."""
    groups = config['proxy-groups']
    paid = next((g for g in groups if g['name'] == 'PAID'), None)
    if paid and not any(g['name'] == 'AUTO' for g in groups):
        replacement = copy.deepcopy(paid)
        replacement['name'] = 'AUTO'
        groups.append(replacement)
    config['proxy-groups'] = [g for g in groups if g['name'] != 'PAID']
    for g in config['proxy-groups']:
        if 'proxies' in g:
            names = []
            for n in g['proxies']:
                replacements = paid.get('proxies', []) if n == 'PAID' and g['name'] == 'AUTO' and paid else ['AUTO' if n == 'PAID' else n]
                for name in replacements:
                    if name not in names:
                        names.append(name)
            g['proxies'] = names
    config['rules'] = [re.sub(r',PAID(?=(?:,no-resolve)?$)', ',AUTO', r) for r in config.get('rules', [])]
    for node in config.get('proxies', []):
        if node.get('dialer-proxy') == 'PAID':
            node['dialer-proxy'] = 'AUTO'
    for category in ('proxy-providers', 'rule-providers'):
        for provider in config.get(category, {}).values():
            if provider.get('proxy') == 'PAID':
                provider['proxy'] = 'AUTO'


def validate_policy(policy):
    uplink_order = policy.get('proxyUplinkOrder')
    if uplink_order is not None and (not isinstance(uplink_order, list)
                                    or sorted(uplink_order) != sorted(ADAPTERS)):
        raise ValueError('proxyUplinkOrder must list every managed adapter exactly once')
    bindings = policy.get('interfaceBindings', {})
    if (not isinstance(bindings, dict) or not set(bindings) <= set(ADAPTERS)
            or any(not isinstance(v, str) or not v.strip() or '\n' in v or '\r' in v
                   for v in bindings.values())):
        raise ValueError('interfaceBindings must map managed slots to Windows adapter names')
    sources = policy.get('adapterProxySources', {})
    remote_paths = {REGIONS[r][0] + a for r in ('TOKYO', 'LA') for a in ADAPTERS}
    if (not isinstance(sources, dict) or not set(sources) <= remote_paths
            or any(not isinstance(v, str) or not v.strip() or v in remote_paths
                   or v.startswith('WAN-') for v in sources.values())):
        raise ValueError('adapterProxySources must map remote adapter paths to base proxy names')
    standby = policy.get('standbyPaths', {})
    if (not isinstance(standby, dict) or not set(standby) <= set(REGIONS)
            or any(not isinstance(v, list) or not set(v) <= set(ADAPTERS)
                   or len(v) != len(set(v)) or len(v) == len(ADAPTERS)
                   for v in standby.values())):
        raise ValueError('standbyPaths must leave an ordinary path in each configured region')
    if not 20 <= policy.get('slots', 24) <= 32:
        raise ValueError('slots must be between 20 and 32 (at most 5% per bucket)')
    if policy.get('pollSeconds', 10) < 5 or policy.get('rebalanceSeconds', 300) < 60:
        raise ValueError('poll/rebalance intervals are too short')
    if not 0 < policy.get('ewmaAlpha', .25) <= 1:
        raise ValueError('invalid EWMA alpha')
    if not set(policy.get('enabledRegions', REGIONS)) <= set(REGIONS):
        raise ValueError('unknown dispatch region')
    if policy.get('preferredBulkRegion', 'TOKYO') not in ('TOKYO', 'LA'):
        raise ValueError('unknown bulk region')
    stability = policy.get('regionalStability', {})
    if stability.get('enabled'):
        if not 1 <= stability.get('minHealthyPaths', 2) <= 4 or stability.get('minHealthyChecks', 3) < 2:
            raise ValueError('invalid regional health requirements')
        if stability.get('minimumStableSeconds', 60) < 30 or stability.get('holdDownSeconds', 180) < 60:
            raise ValueError('regional stability windows are too short')
    for region in REGIONS:
        caps = policy['capacitiesMbps'][region]
        if set(caps) != set(ADAPTERS):
            raise ValueError('capacity entries must cover exactly the four managed adapters')
        if any(not isinstance(v, (int, float)) or not math.isfinite(v) or v <= 0 for v in caps.values()):
            raise ValueError('capacities must be finite and positive')


def allocate(scores, slots):
    """Bounded capacity shares; half the budget remains evenly distributed.

    Capacity inputs come from bounded independent probes, never from the current
    allocation's own rate/load score. Failed paths receive zero buckets.
    """
    good = {n: s for n, s in scores.items() if math.isfinite(s) and s > 0}
    if not good:
        return {}
    total = sum(good.values())
    raw = {n: slots * (.5 / len(good) + .5 * s / total) for n, s in good.items()}
    result = {n: math.floor(v) for n, v in raw.items()}
    remainder = slots - sum(result.values())
    for n in sorted(good, key=lambda n: (raw[n] - math.floor(raw[n]), good[n], n), reverse=True)[:remainder]:
        result[n] += 1
    return result


def smooth_sequence(counts):
    """Arrange a finite weighted rotation without contiguous per-link bursts."""
    credits = dict.fromkeys(sorted(counts), 0)
    result, total = [], sum(counts.values())
    for _ in range(total):
        for owner in credits:
            credits[owner] += counts[owner]
        owner = max(credits, key=credits.get)
        result.append(owner)
        credits[owner] -= total
    return result


def stable_assignment(current, counts):
    """Keep as many bucket owners as possible while meeting new target weights."""
    if sum(counts.values()) != len(current):
        raise ValueError('bucket target count mismatch')
    remaining = dict(counts)
    result = [None] * len(current)
    for i, owner in enumerate(current):
        if remaining.get(owner, 0):
            result[i] = owner
            remaining[owner] -= 1
    fill = smooth_sequence({n: v for n, v in remaining.items() if v})
    for i in range(len(result)):
        if result[i] is None:
            result[i] = fill.pop(0)
    return result


def prefer_nonstandby(scores, region, policy):
    """Reserve a poor route while retaining it when every ordinary route fails."""
    standby = {managed_path(region, a) for a in policy.get('standbyPaths', {}).get(region, [])}
    if any(value > 0 for name, value in scores.items() if name not in standby):
        return {name: 0 if name in standby else value for name, value in scores.items()}
    return dict(scores)


def apply_policy(config, policy):
    """A narrow, idempotent transformation; never regenerate app-specific policy."""
    validate_policy(policy)
    c = copy.deepcopy(config)
    # Keep logical path names and saved application selections stable when a
    # physical tethering device is replaced. Also cover provider overrides.
    bindings = policy.get('interfaceBindings', {})
    def bind_interfaces(value):
        if isinstance(value, dict):
            interface = value.get('interface-name')
            if interface in bindings:
                value['interface-name'] = bindings[interface]
            for child in value.values():
                bind_interfaces(child)
        elif isinstance(value, list):
            for child in value:
                bind_interfaces(child)
    bind_interfaces(c)
    # A measured alternative transport keeps the logical adapter/region name.
    definitions = {node['name']: node for node in c.get('proxies', [])}
    for target, source in policy.get('adapterProxySources', {}).items():
        if target not in definitions or source not in definitions:
            raise ValueError('adapter proxy transport source or target is missing')
        if definitions[source].get('type') in ('direct', 'reject', 'dns'):
            raise ValueError('adapter transport source must be a remote proxy')
        interface = definitions[target].get('interface-name')
        if not interface:
            raise ValueError('adapter transport target must have an interface binding')
        node = copy.deepcopy(definitions[source])
        node.pop('dialer-proxy', None)
        node.update(name=target, **{'interface-name': interface})
        c['proxies'] = [node if old['name'] == target else old for old in c['proxies']]
    if policy.get('proxyUplinkOrder'):
        # Base proxy servers need stable transport; destination hashing for
        # ordinary direct traffic must not rotate their carrier on each dial.
        uplink = dict(name='PROXY-UPLINK', type='fallback',
                      proxies=['WAN-' + a for a in policy['proxyUplinkOrder']],
                      url='https://www.baidu.com/', interval=30, timeout=4000,
                      lazy=False, **{'expected-status': '200-399'})
        c['proxy-groups'] = [g for g in c['proxy-groups'] if g['name'] != 'PROXY-UPLINK']
        c['proxy-groups'].append(uplink)
        for node in c['proxies']:
            if node.get('dialer-proxy') in ('DISPATCH', 'PROXY-UPLINK'):
                node['dialer-proxy'] = 'PROXY-UPLINK'
    retire_paid_alias(c)
    if not policy.get('enabled', False):
        return c
    names = {p['name'] for p in c.get('proxies', [])}
    needed = {prefix + a for prefix, *_ in REGIONS.values() for a in ADAPTERS}
    if not needed <= names:
        raise ValueError('missing adapter-bound WAN/Tokyo/LA nodes')
    enabled = set(policy.get('enabledRegions', REGIONS))
    # Restore ordinary two-path pools when a previously managed remote region
    # is disabled, so no references to removed virtual buckets survive.
    for region, (prefix, active, url, expected) in REGIONS.items():
        if region in enabled or region == 'WAN':
            continue
        for g in c['proxy-groups']:
            if g['name'] == active and any(n.startswith('ADAPTIVE-') for n in g.get('proxies', [])):
                g.update(type='load-balance', strategy='round-robin',
                         proxies=[prefix+'win_turbo_phone', prefix+'pisen_2026_10'],
                         interval=30, lazy=False)
    active_names = {REGIONS[r][1] for r in enabled}
    active_names.add('WAN-ACTIVE')
    c['proxy-groups'] = [g for g in c['proxy-groups']
                         if not g['name'].startswith('ADAPTIVE-') and g['name'] not in active_names]
    groups = {g['name']: g for g in c['proxy-groups']}
    providers = c.setdefault('proxy-providers', {})
    c['proxy-providers'] = providers = {n: p for n, p in providers.items() if not n.startswith('ADAPTIVE-NODES-')}
    node_definitions = {p['name']: p for p in c['proxies']}
    for region, (prefix, active, url, expected) in REGIONS.items():
        if region not in enabled:
            continue
        members = [managed_path(region, a) for a in ADAPTERS]
        initial = policy.get('initialEligible', {}).get(region, list(ADAPTERS))
        scores = {managed_path(region, a): policy['capacitiesMbps'][region][a] if a in initial else 0 for a in ADAPTERS}
        scores = prefer_nonstandby(scores, region, policy)
        counts = allocate(scores, policy['slots'])
        if not counts:
            counts = allocate({n: 1 for n in members}, policy['slots'])
        owners = smooth_sequence(counts)
        health = dict(url=url, **{'expected-status': expected}, timeout=4000)
        provider_name = 'ADAPTIVE-NODES-' + region
        payload = []
        for adapter in ADAPTERS:
            node = copy.deepcopy(node_definitions[prefix + adapter])
            node['name'] = managed_path(region, adapter)
            payload.append(node)
        providers[provider_name] = dict(type='inline', payload=payload, **{'health-check': {
            'enable': True, 'url': url, 'interval': 30, 'lazy': False,
            'timeout': 4000, 'expected-status': expected}})
        c['proxy-groups'].append(dict(name='ADAPTIVE-HEALTH-' + region, type='url-test',
                                      use=[provider_name], interval=30, lazy=False, tolerance=100,
                                      hidden=True, **health))
        slots = []
        for i, owner in enumerate(owners):
            name = f'ADAPTIVE-{region}-{i:02d}'
            slots.append(name)
            # Every slot shares one inline provider and its four health probes.
            # No per-slot compatible provider or health-check goroutine is made.
            standby_members = {managed_path(region, a) for a in policy.get('standbyPaths', {}).get(region, [])}
            ordinary = [n for n in members if n != owner and n not in standby_members]
            backups = [n for n in members if n != owner and n in standby_members]
            filters = ['^' + re.escape(owner) + '$']
            filters += ['^(?:' + '|'.join(re.escape(n) for n in part) + ')$'
                        for part in (ordinary, backups) if part]
            preferred_order = '`'.join(filters)
            c['proxy-groups'].append(dict(name=name, type='fallback',
                                          use=[provider_name], filter=preferred_order,
                                          interval=3600, lazy=True, hidden=True, **health))
        group = groups.get(active)
        if group is None:
            group = {'name': active}
            c['proxy-groups'].append(group)
        group.clear()
        # Direct egress needs destination affinity. Both remote proxy families
        # retain the same exit server while rotating transport across adapters.
        strategy = 'consistent-hashing' if region == 'WAN' else 'round-robin'
        group.update(name=active, type='load-balance', strategy=strategy,
                     proxies=slots, interval=3600, lazy=True, **health)
        if region != 'WAN':
            pool = groups[region + '-POOL']
            pool.clear()
            pool.update(name=region + '-POOL', type='fallback', proxies=[active] + [prefix+a for a in ADAPTERS],
                        interval=30, lazy=False, **health)
    # Optional policy override for the direct fallback order; default is the managed order.
    fallback_order = policy.get('fallbackOrder', list(ADAPTERS))
    if sorted(fallback_order) != sorted(ADAPTERS):
        raise ValueError('fallbackOrder must list every managed adapter exactly once')
    if 'WAN' in enabled:
        dispatch = groups['DISPATCH']
        dispatch.update(type='fallback', proxies=['WAN-ACTIVE'] + ['WAN-' + a for a in fallback_order] + ['DIRECT'])
        for key in ('strategy', 'tolerance', 'use', 'filter'):
            dispatch.pop(key, None)
    elif 'WAN-ACTIVE' in groups['DISPATCH'].get('proxies', []):
        groups['DISPATCH']['proxies'] = ['WAN-'+a for a in fallback_order] + ['DIRECT']
    preferred = policy.get('preferredBulkRegion', 'TOKYO') + '-POOL'
    for name in ('AUTO', 'DATA'):
        g = groups.get(name)
        if g and preferred in g.get('proxies', []):
            g['proxies'] = [preferred] + [n for n in g['proxies'] if n != preferred]
    return c


def health_sample(proxy, url, now, stale_seconds=100):
    """Use only this test URL; unrelated broker/website histories are not a vote."""
    state = proxy.get('extra', {}).get(url)
    if state is None:
        return {'healthy': False, 'reason': 'no_matching_health_history'}
    history = state.get('history', [])
    if not history:
        return {'healthy': False, 'reason': 'no_matching_health_history'}
    sample = history[-1]
    try:
        stamp = dt.datetime.fromisoformat(sample['time'].replace('Z', '+00:00')).timestamp()
        delay = float(sample['delay'])
    except (KeyError, TypeError, ValueError):
        return {'healthy': False, 'reason': 'invalid_health_sample'}
    age = now - stamp
    ok = state.get('alive', False) and delay > 0 and -5 <= age <= stale_seconds
    return dict(healthy=bool(ok), delay_ms=delay, stamp=stamp, age_seconds=round(age, 2),
                reason='ok' if ok else 'failed_or_stale')


def update_metric(previous, sample, capacity, transfer_count, mbps, alpha=.25):
    m = dict(previous or {})
    fresh = sample.get('stamp') is not None and sample.get('stamp') != m.get('stamp')
    if not sample['healthy']:
        m.update(quarantined=True, recovery=0, recovery_since=None, healthy=False, score=0)
    elif fresh:
        m['recovery'] = m.get('recovery', 0) + 1
        if m.get('recovery_since') is None:
            m['recovery_since'] = sample['stamp']
        stable_recovery = m['recovery'] >= 2 and sample['stamp'] - m['recovery_since'] >= 10
        if not m.get('quarantined') or stable_recovery:
            m.update(quarantined=False, healthy=True)
        old = m.get('latency_ms', sample['delay_ms'])
        m['latency_ms'] = old * (1 - alpha) + sample['delay_ms'] * alpha
    m['stamp'] = sample.get('stamp', m.get('stamp'))
    m['reason'] = sample['reason']
    m['active_transfers'] = transfer_count
    m['observed_mbps'] = round(mbps, 4)
    # HypoMux's regression demonstrates why rate/load must not drive allocation:
    # low demand and already-assigned long flows bias both operands. Polled API
    # counters also cannot identify client backpressure or short finished flows.
    # Keep those metrics observable, but use independent capacity priors only.
    m['capacity_mbps'] = capacity
    m['learning_state'] = 'observation_only_backpressure_and_full_flow_counters_unavailable'
    m['score'] = capacity if m.get('healthy') and sample['healthy'] else 0
    return m


class API:
    def __init__(self, base='http://127.0.0.1:9097'):
        if base != 'http://127.0.0.1:9097':
            raise ValueError('controller must remain local')
        self.base = base
        self.opener = urllib.request.build_opener(urllib.request.ProxyHandler({}))

    def request(self, path, method='GET', value=None):
        body = json.dumps(value).encode() if value is not None else None
        req = urllib.request.Request(self.base + path, data=body, method=method,
                                     headers={'Content-Type': 'application/json'})
        with self.opener.open(req, timeout=5) as response:
            raw = response.read()
            return json.loads(raw) if raw else None


def write_json(path, value):
    temp = path.with_suffix('.tmp')
    temp.write_text(json.dumps(value, indent=2), encoding='utf-8')
    temp.replace(path)


def make_logger(directory, max_bytes=5 * 1024 * 1024, backups=5):
    logger = logging.getLogger('adaptive-dispatch')
    logger.setLevel(logging.INFO)
    for old in logger.handlers:
        old.close()
    logger.handlers.clear()
    handler = RotatingFileHandler(directory / 'dispatch.jsonl', maxBytes=max_bytes,
                                  backupCount=backups, encoding='utf-8')
    handler.setFormatter(logging.Formatter('%(message)s'))
    logger.addHandler(handler)
    return logger


class Controller:
    def __init__(self, policy, directory, api=None):
        validate_policy(policy)
        self.policy, self.directory, self.api = policy, directory, api or API()
        self.metrics, self.previous, self.rebalanced = {}, {}, {}
        self.eligible_sets = {}
        self.last_sample, self.last_poll = 0, None
        self.rollup_day, self.rollup = None, None
        self.region_evidence = {}
        self.region_hold_until = 0
        pin_file = directory / 'owned-bulk-selections.json'
        self.bulk_pins = json.loads(pin_file.read_text()) if pin_file.exists() else {}
        self.logger = make_logger(directory)
        self.nodes = {prefix + a: (region, a) for region, (prefix, *_) in REGIONS.items() for a in ADAPTERS}
        self.nodes.update({managed_path(region, a): (region, a) for region in REGIONS for a in ADAPTERS})
        self.session_salt = os.urandom(16)

    def log(self, event, **fields):
        self.logger.info(json.dumps(dict(utc=utc(), event=event, **fields), separators=(',', ':')))

    def select_bulk_region(self, proxies, now, observe_only):
        options = self.policy.get('regionalStability', {})
        if not options.get('enabled', False):
            if self.bulk_pins and not observe_only:
                self.release_bulk_pins()
            return {'mode': 'native_fallback'}
        preferred = self.policy.get('preferredBulkRegion', 'TOKYO')
        backup = 'LA' if preferred == 'TOKYO' else 'TOKYO'
        evidence = {}
        for region in ('TOKYO', 'LA'):
            prefix = REGIONS[region][0]
            values = [self.metrics[managed_path(region, a) if region in self.policy.get('enabledRegions', REGIONS) else prefix+a]
                      for a in ADAPTERS]
            available = sum(v.get('healthy', False) and v.get('score', 0) > 0 for v in values) >= options.get('minHealthyPaths', 2)
            stamp = tuple(v.get('stamp') for v in values)
            prior = self.region_evidence.setdefault(region, dict(since=None, checks=0, stamp=None))
            if not available:
                prior.update(since=None, checks=0)
            elif stamp != prior['stamp']:
                if prior['since'] is None:
                    prior['since'] = now
                prior['checks'] += 1
            prior['stamp'] = stamp
            stable = available and prior['checks'] >= options.get('minHealthyChecks', 3) and now - prior['since'] >= options.get('minimumStableSeconds', 60)
            evidence[region] = dict(available=available, stable=stable, fresh_checks=prior['checks'])
        if not evidence[preferred]['available']:
            self.region_hold_until = max(self.region_hold_until, now + options.get('holdDownSeconds', 180))
        if evidence[preferred]['stable'] and now >= self.region_hold_until:
            choice, reason = preferred, 'preferred_region_stable'
        elif evidence[backup]['available']:
            choice = backup
            reason = 'preferred_region_hold_down' if now < self.region_hold_until else 'preferred_region_warming'
        elif evidence[preferred]['available']:
            choice, reason = preferred, 'only_available_region'
        else:
            return dict(mode='all_regions_unavailable', evidence=evidence)
        target = choice + '-POOL'
        changes = []
        if not observe_only:
            for group in ('AUTO', 'DATA'):
                state = proxies.get(group)
                if not state or target not in state.get('all', []):
                    continue
                if state.get('fixed') != target:
                    self.api.request('/proxies/'+group, 'PUT', {'name': target})
                    changes.append(group)
                self.bulk_pins[group] = target
            if changes:
                write_json(self.directory / 'owned-bulk-selections.json', self.bulk_pins)
                self.log('regional_selection', region=choice, reason=reason, groups=changes, evidence=evidence)
        return dict(mode='observe_only' if observe_only else 'stability_guard', selected=choice,
                    reason=reason, hold_remaining_seconds=round(max(0, self.region_hold_until-now)), evidence=evidence)

    def release_bulk_pins(self):
        proxies = self.api.request('/proxies')['proxies']
        for group, choice in self.bulk_pins.items():
            if proxies.get(group, {}).get('fixed') == choice:
                self.api.request('/proxies/'+group, 'DELETE')
        self.bulk_pins = {}
        write_json(self.directory / 'owned-bulk-selections.json', {})

    def flows(self, connections, now):
        seen, stats = {}, collections.defaultdict(lambda: dict(bytes=0, active_transfers=0, connections=0,
                                                              newly_observed_flows=0, ended_observed_flows=0))
        elapsed = max(.1, now - self.last_poll) if self.last_poll else None
        for c in connections:
            node = next((n for n in c.get('chains', []) if n in self.nodes), None)
            if node is None:
                continue
            # IDs, hostnames, IPs, process paths and rule payloads never enter logs.
            key = c.get('id')
            if not key:
                continue
            total = max(0, int(c.get('download', 0))) + max(0, int(c.get('upload', 0)))
            old = self.previous.get(key)
            delta = max(0, total - old['bytes']) if old else 0
            first = old['first'] if old else now
            seen[key] = dict(node=node, bytes=total, first=first, observed_delta=(old['observed_delta'] if old else 0) + delta)
            stats[node]['bytes'] += delta
            stats[node]['connections'] += 1
            if old is None:
                stats[node]['newly_observed_flows'] += 1
            if delta >= 16384:
                stats[node]['active_transfers'] += 1
        for key, old in self.previous.items():
            if key not in seen:
                stats[old['node']]['ended_observed_flows'] += 1
                token = hashlib.sha256(self.session_salt + key.encode()).hexdigest()[:16]
                self.log('flow_observed_end', token=token, path=old['node'],
                         observed_seconds=round(now - old['first'], 2),
                         observed_bytes=old['observed_delta'],
                         note='polling lower bound; final bytes and unobserved short flows are unavailable')
        self.previous, self.last_poll = seen, now
        for s in stats.values():
            s['mbps'] = s['bytes'] * 8 / elapsed / 1e6 if elapsed else 0
        return stats

    def tick(self, now=None, observe_only=False):
        now = time.time() if now is None else now
        proxies = self.api.request('/proxies')['proxies']
        providers = self.api.request('/providers/proxies').get('providers', {})
        for name, provider in providers.items():
            if name.startswith('ADAPTIVE-NODES-'):
                for proxy in provider.get('proxies', []):
                    proxies[proxy['name']] = proxy
        stats = self.flows(self.api.request('/connections')['connections'], now)
        regions = {}
        for region, (prefix, _, url, _) in REGIONS.items():
            current, scores = [], {}
            for a in ADAPTERS:
                node = managed_path(region, a) if region in self.policy.get('enabledRegions', REGIONS) else prefix+a
                sample = health_sample(proxies.get(node, {}), url, now,
                                       self.policy.get('staleHealthSeconds', 100))
                traffic = stats.get(node, {})
                m = update_metric(self.metrics.get(node), sample,
                                  self.policy['capacitiesMbps'][region][a],
                                  traffic.get('active_transfers', 0), traffic.get('mbps', 0),
                                  self.policy.get('ewmaAlpha', .25))
                m['connections'] = traffic.get('connections', 0)
                for key in ('bytes', 'newly_observed_flows', 'ended_observed_flows'):
                    m[key] = traffic.get(key, 0)
                self.metrics[node] = m
                scores[node] = m['score']
            scores = prefer_nonstandby(scores, region, self.policy)
            if region not in self.policy.get('enabledRegions', REGIONS):
                regions[region] = dict(status='baseline_retained_pending_evidence', allocation={})
                continue
            slots = [f'ADAPTIVE-{region}-{i:02d}' for i in range(self.policy['slots'])]
            if not all(n in proxies for n in slots):
                regions[region] = dict(status='policy_groups_missing', allocation={})
                continue
            for slot in slots:
                p = proxies[slot]
                # Effective fallback selection may already differ from a failed
                # fixed preference; use the preference so it can be cleared.
                current.append(p.get('fixed') or p.get('now'))
            counts = allocate(scores, len(slots))
            eligible = frozenset(n for n, score in scores.items() if score > 0)
            prior_eligible = self.eligible_sets.get(region)
            health_change = prior_eligible is not None and eligible != prior_eligible
            self.eligible_sets[region] = eligible
            if not counts:
                regions[region] = dict(status='all_paths_unavailable_no_selection_changes', allocation=dict(collections.Counter(current)))
                continue
            desired = stable_assignment(current, counts)
            moved = sum(a != b for a, b in zip(current, desired))
            emergency = health_change or any(scores.get(owner, 0) <= 0 for owner in current)
            due = now - self.rebalanced.get(region, 0) >= self.policy.get('rebalanceSeconds', 300)
            change = emergency or (due and moved > 0)
            changed = 0
            if moved and change and not observe_only:
                for slot, old, new in zip(slots, current, desired):
                    if old != new:
                        self.api.request('/proxies/' + urllib.parse.quote(slot, safe=''), 'PUT', {'name': new})
                        changed += 1
                        current[slots.index(slot)] = new
                        # A normal update shifts at most one bucket (4.17% with
                        # 24 buckets). Failures bypass that limit for safety.
                        if not emergency:
                            break
                self.rebalanced[region] = now
                reason = 'health_membership_change' if health_change else ('unhealthy_path' if emergency else 'independently_measured_capacity_prior')
                self.log('rebalance', region=region, reason=reason,
                         changed_slots=changed, allocation=dict(collections.Counter(current)), target=counts)
            regions[region] = dict(status='observe_only' if observe_only else 'active',
                                   allocation=dict(collections.Counter(current)), target=counts,
                                   changed_slots=changed, emergency=emergency)
        regional_choice = self.select_bulk_region(proxies, now, observe_only)
        native_file = self.directory.parent / 'native-theta' / 'status.json'
        native = {'state': 'observer_not_started'}
        if native_file.exists():
            try:
                native = json.loads(native_file.read_text(encoding='utf-8'))
                if now - native.get('sample_epoch', 0) > 30:
                    native = {'state': 'observer_stale'}
            except (OSError, ValueError):
                native = {'state': 'observer_unavailable'}
        day = dt.datetime.fromtimestamp(now, dt.timezone.utc).date().isoformat()
        daily_path = self.directory / ('daily-' + day + '.json')
        if day != self.rollup_day:
            self.rollup_day = day
            self.rollup = json.loads(daily_path.read_text(encoding='utf-8')) if daily_path.exists() else dict(
                date_utc=day, samples=0, paths={}, note='Observed polling deltas, not complete flow accounting')
            keep_candidates = set(self.directory.glob('daily-????-??-??.json')) | {daily_path}
            for old in sorted(keep_candidates)[:-30]:
                if old.exists():
                    old.unlink()
        self.rollup['samples'] += 1
        self.rollup['updated_utc'] = utc()
        for node, traffic in stats.items():
            total = self.rollup['paths'].setdefault(node, dict(observed_bytes=0, newly_observed_flows=0, ended_observed_flows=0))
            for key in ('newly_observed_flows', 'ended_observed_flows'):
                total[key] += traffic.get(key, 0)
            total['observed_bytes'] += traffic['bytes']
        self.rollup['latest_allocations'] = regions
        write_json(daily_path, self.rollup)
        snapshot = dict(utc=utc(), algorithm='bounded-capacity-weighted-rotation-sticky-direct-v1',
                        health_probe_model='shared_inline_provider_per_region',
                        policy_enabled=self.policy.get('enabled', False), regions=regions, paths=self.metrics,
                        observations=stats, regional_choice=regional_choice, native_theta=native,
                        logging='aggregated counters and salted opaque flow tokens; no endpoints, credentials or payloads',
                        limitations=['Bulk pools use weighted connection rotation; direct pool uses destination hash buckets; neither guarantees byte shares',
                                     'Native Windows/WSL connections outside Mihomo are not controlled',
                                     'Polled flow counters are lower bounds; passive rate does not alter capacity priors',
                                     'Throughput feedback remains observational because backpressure and complete flow lifecycles are unavailable'])
        write_json(self.directory / 'status.json', snapshot)
        if now - self.last_sample >= self.policy.get('logSeconds', 30):
            self.log('sample', regions=regions, paths=self.metrics, observations=stats,
                     regional_choice=regional_choice, native_theta=native)
            self.last_sample = now
        return snapshot


def lock_instance(directory):
    f = (directory / 'controller.lock').open('a+b')
    if f.tell() == 0:
        f.write(b'0')
        f.flush()
    f.seek(0)
    if os.name == 'nt':
        import msvcrt
        msvcrt.locking(f.fileno(), msvcrt.LK_NBLCK, 1)
    else:
        import fcntl
        fcntl.flock(f.fileno(), fcntl.LOCK_EX | fcntl.LOCK_NB)
    return f


def main():
    root = Path(__file__).resolve().parents[1]
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--policy', type=Path, default=root / 'config/dispatch-policy.json')
    parser.add_argument('--state', type=Path, default=root / 'state/adaptive-dispatch')
    parser.add_argument('--input', type=Path)
    parser.add_argument('--output', type=Path)
    parser.add_argument('--once', action='store_true')
    parser.add_argument('--observe-only', action='store_true')
    args = parser.parse_args()
    policy = json.loads(args.policy.read_text(encoding='utf-8-sig'))
    validate_policy(policy)
    if args.input:
        if not args.output:
            parser.error('--output is required with --input')
        import yaml  # The running controller uses only the standard library.
        c = yaml.safe_load(args.input.read_text(encoding='utf-8-sig'))
        args.output.write_text(yaml.safe_dump(apply_policy(c, policy), sort_keys=False, allow_unicode=True), encoding='utf-8')
        return
    args.state.mkdir(parents=True, exist_ok=True)
    try:
        instance = lock_instance(args.state)
    except (OSError, BlockingIOError):
        return  # Another running controller owns this state directory.
    controller = Controller(policy, args.state)
    controller.log('controller_start', observe_only=args.observe_only, slots=policy['slots'],
                   policy_sha256=hashlib.sha256(json.dumps(policy, sort_keys=True).encode()).hexdigest(),
                   script_sha256=hashlib.sha256(Path(__file__).read_bytes()).hexdigest())
    try:
        while policy.get('enabled', False):
            try:
                controller.tick(observe_only=args.observe_only)
            except Exception as e:
                # Never log an API response or exception text containing metadata.
                controller.log('controller_error', error_type=type(e).__name__, status=getattr(e, 'code', None))
                if args.once:
                    raise
            if args.once:
                break
            time.sleep(policy.get('pollSeconds', 10))
            refreshed = json.loads(args.policy.read_text(encoding='utf-8-sig'))
            validate_policy(refreshed)
            policy = controller.policy = refreshed
    finally:
        if not policy.get('enabled', False) and not args.observe_only:
            try:
                controller.release_bulk_pins()
            except Exception as e:
                controller.log('release_pins_error', error_type=type(e).__name__)
        controller.log('controller_stop')
        for handler in controller.logger.handlers:
            handler.close()
        instance.close()


if __name__ == '__main__':
    main()
