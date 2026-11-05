import collections
import copy
import datetime as dt
import importlib.util
import json
import re
from pathlib import Path
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[2]
SPEC = importlib.util.spec_from_file_location('dispatch', ROOT / 'tools/AdaptiveDispatch.py')
m = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(m)


def policy():
    return dict(enabled=True, slots=24, pollSeconds=10, logSeconds=30,
                rebalanceSeconds=300, staleHealthSeconds=100, ewmaAlpha=.2,
                capacitiesMbps={r: dict.fromkeys(m.ADAPTERS, 5) for r in m.REGIONS})


def config():
    nodes = [dict(name=prefix + a, type='direct', **{'interface-name': a})
             for prefix, *_ in m.REGIONS.values() for a in m.ADAPTERS]
    return dict(proxies=nodes, dns={'enable': True}, tun={'enable': False},
                rules=['IP-CIDR,127.0.0.0/8,DIRECT', 'DOMAIN-SUFFIX,thetadata.us,DEV', 'MATCH,AUTO'],
                **{'proxy-groups': [dict(name=n, type='fallback', proxies=['WAN-jd_5G'])
                    for n in ['DISPATCH', 'TOKYO-POOL', 'LA-POOL', 'TWS', 'FUTU-DIRECT', 'DEV']]})


def sample(now, delay=100, ok=True):
    return {'healthy': ok, 'stamp': now, 'delay_ms': delay, 'reason': 'ok' if ok else 'failed'}


class FakeAPI:
    def __init__(self, now=1000):
        self.now, self.puts, self.connections, self.deleted = now, [], [], []
        self.proxies = {}
        for region, (prefix, _, url, _) in m.REGIONS.items():
            for a in m.ADAPTERS:
                self.proxies[prefix+a] = {'extra': {url: {'alive': True, 'history': [
                    {'time': dt.datetime.fromtimestamp(now, dt.timezone.utc).isoformat(), 'delay': 100}]}}}
            owners = m.smooth_sequence(dict.fromkeys([m.managed_path(region, a) for a in m.ADAPTERS], 6))
            for i, owner in enumerate(owners):
                self.proxies[f'ADAPTIVE-{region}-{i:02d}'] = dict(type='Fallback', now=owner, fixed=owner)

    def request(self, path, method='GET', value=None):
        if method == 'DELETE':
            name = path.rsplit('/', 1)[1]
            self.deleted.append(name)
            self.proxies[name]['fixed'] = ''
        elif method == 'PUT':
            name = path.rsplit('/', 1)[1]
            self.puts.append((name, value['name']))
            self.proxies[name].update(now=value['name'], fixed=value['name'])
        elif path == '/proxies':
            return {'proxies': dict(self.proxies)}
        elif path == '/connections':
            return {'connections': self.connections}
        elif path == '/providers/proxies':
            return {'providers': {'ADAPTIVE-NODES-'+r: {'proxies': [
                dict(name=m.managed_path(r, a), **self.proxies[prefix+a]) for a in m.ADAPTERS]}
                for r, (prefix, *_) in m.REGIONS.items()}}
        else:
            raise AssertionError(path)


class DispatchTests(unittest.TestCase):
    def test_adapter_transport_override_preserves_region_binding_and_payload(self):
        before = config()
        before['proxies'].append({'name': 'quic-base', 'type': 'hysteria2',
                                  'server': '192.0.2.1', 'port': 443,
                                  'password': 'test-only', 'dialer-proxy': 'DISPATCH'})
        settings = policy()
        settings['interfaceBindings'] = {'win_turbo_phone': 'iPhone 17 pro max'}
        settings['adapterProxySources'] = {'BALANCED-win_turbo_phone': 'quic-base'}
        out = m.apply_policy(before, settings)
        node = next(x for x in out['proxies'] if x['name'] == 'BALANCED-win_turbo_phone')
        self.assertEqual(node['type'], 'hysteria2')
        self.assertEqual(node['interface-name'], 'iPhone 17 pro max')
        self.assertNotIn('dialer-proxy', node)
        payload = out['proxy-providers']['ADAPTIVE-NODES-TOKYO']['payload']
        self.assertEqual(next(x for x in payload if x['name'].endswith('win_turbo_phone'))['type'], 'hysteria2')
        self.assertEqual(m.apply_policy(out, settings), out)
        self.assertEqual(before['proxies'][0]['interface-name'], 'win_turbo_phone')

    def test_transport_override_fails_closed_for_missing_or_local_source(self):
        settings = policy()
        settings['adapterProxySources'] = {'LA-win_turbo_phone': 'missing'}
        with self.assertRaises(ValueError):
            m.apply_policy(config(), settings)
        before = config()
        before['proxies'].append({'name': 'missing', 'type': 'direct'})
        with self.assertRaises(ValueError):
            m.apply_policy(before, settings)

    def test_standby_path_is_retained_only_when_ordinary_paths_fail(self):
        settings = policy()
        settings['standbyPaths'] = {'TOKYO': ['win_turbo_phone']}
        phone = m.managed_path('TOKYO', 'win_turbo_phone')
        pisen = m.managed_path('TOKYO', 'pisen_2026_10')
        self.assertEqual(m.prefer_nonstandby({phone: 5, pisen: 3}, 'TOKYO', settings), {phone: 0, pisen: 3})
        self.assertEqual(m.prefer_nonstandby({phone: 5, pisen: 0}, 'TOKYO', settings), {phone: 5, pisen: 0})
        out = m.apply_policy(config(), settings)
        for group in out['proxy-groups']:
            if group['name'].startswith('ADAPTIVE-TOKYO-'):
                filters = group['filter'].split('`')
                self.assertIsNone(re.fullmatch(filters[0], phone))
                self.assertIsNone(re.fullmatch(filters[1], phone))
                self.assertIsNotNone(re.fullmatch(filters[-1], phone))

    def test_transport_and_standby_policy_validation(self):
        for extra in [
            {'adapterProxySources': {'WAN-win_turbo_phone': 'server'}},
            {'adapterProxySources': {'LA-win_turbo_phone': 'BALANCED-pisen_2026_10'}},
            {'standbyPaths': {'TOKYO': list(m.ADAPTERS)}},
            {'standbyPaths': {'TOKYO': ['unknown']}},
        ]:
            with self.subTest(extra=extra):
                settings = policy()
                settings.update(extra)
                with self.assertRaises(ValueError):
                    m.validate_policy(settings)

    def test_base_proxy_transport_is_stable_and_rebuild_safe(self):
        before = config()
        before['proxies'].append(dict(name='server', type='vless', **{'dialer-proxy': 'DISPATCH'}))
        settings = policy()
        settings['proxyUplinkOrder'] = ['jd_5G', 'pisen_2026_10', 'win_turbo_phone', 'pisen_2026_03']
        out = m.apply_policy(before, settings)
        self.assertEqual(out['proxies'][-1]['dialer-proxy'], 'PROXY-UPLINK')
        uplink = next(g for g in out['proxy-groups'] if g['name'] == 'PROXY-UPLINK')
        self.assertEqual(uplink['type'], 'fallback')
        self.assertEqual(uplink['proxies'][0], 'WAN-jd_5G')
        self.assertEqual(out['rules'], before['rules'])
        self.assertEqual(out, m.apply_policy(out, settings))

    def test_invalid_stable_uplink_order_is_rejected(self):
        settings = policy()
        settings['proxyUplinkOrder'] = ['jd_5G'] * 4
        with self.assertRaises(ValueError):
            m.validate_policy(settings)

    def test_replacement_adapter_binds_inline_and_standalone_paths(self):
        before = config()
        before['proxy-providers'] = {'subscription': {'override': {'interface-name': 'win_turbo_phone'}}}
        settings = policy()
        settings['interfaceBindings'] = {'win_turbo_phone': 'iPhone 17 pro max'}
        out = m.apply_policy(before, settings)
        for node in out['proxies']:
            if node['name'].endswith('win_turbo_phone'):
                self.assertEqual(node['interface-name'], 'iPhone 17 pro max')
        for region in m.REGIONS:
            payload = out['proxy-providers']['ADAPTIVE-NODES-'+region]['payload']
            phone = next(n for n in payload if n['name'].endswith('win_turbo_phone'))
            self.assertEqual(phone['interface-name'], 'iPhone 17 pro max')
        self.assertEqual(out['proxy-providers']['subscription']['override']['interface-name'], 'iPhone 17 pro max')
        self.assertEqual(out['rules'], before['rules'])
        self.assertEqual(before['proxies'][0]['interface-name'], 'win_turbo_phone')
        self.assertEqual(out, m.apply_policy(out, settings))

    def test_invalid_adapter_bindings_rejected(self):
        for bindings in ([], {'unknown': 'iPhone'}, {'win_turbo_phone': ''}, {'win_turbo_phone': 42}):
            settings = policy()
            settings['interfaceBindings'] = bindings
            with self.assertRaises(ValueError):
                m.validate_policy(settings)

    def test_bounded_weights_prevent_starvation_and_exclude_failed_paths(self):
        scores = dict(a=100000, b=1, c=1, d=1, failed=0)
        got = m.allocate(scores, 24)
        self.assertEqual(sum(got.values()), 24)
        self.assertNotIn('failed', got)
        self.assertEqual(got, dict(a=15, b=3, c=3, d=3))
        self.assertEqual(m.allocate(dict(dead=0), 24), {})

    def test_smooth_rotation_delivers_counts_without_blocking_equal_paths(self):
        counts = dict(a=12, b=6, c=3, d=3)
        seq = m.smooth_sequence(counts)
        self.assertEqual(collections.Counter(seq), counts)
        self.assertEqual(m.smooth_sequence(dict(a=3, b=3)), ['a', 'b'] * 3)
        self.assertLessEqual(max(len(list(v)) for _, v in __import__('itertools').groupby(seq)), 2)

    def test_minimal_bucket_remap(self):
        old = list('aabbcc')
        new = m.stable_assignment(old, dict(a=1, b=2, c=3))
        self.assertEqual(sum(a != b for a, b in zip(old, new)), 1)
        self.assertEqual(collections.Counter(new), dict(a=1, b=2, c=3))

    def test_narrow_idempotent_config_preserves_apps_and_native_bypass(self):
        before = config()
        out = m.apply_policy(before, policy())
        for key in ['proxies', 'rules', 'dns', 'tun']:
            self.assertEqual(out[key], before[key])
        old = {g['name']: g for g in before['proxy-groups']}
        groups = {g['name']: g for g in out['proxy-groups']}
        for n in ['TWS', 'FUTU-DIRECT', 'DEV']:
            self.assertEqual(groups[n], old[n])
        self.assertEqual(groups['TOKYO-ACTIVE']['strategy'], 'round-robin')
        self.assertEqual(groups['WAN-ACTIVE']['strategy'], 'consistent-hashing')
        self.assertEqual(len(groups['LA-ACTIVE']['proxies']), 24)
        self.assertEqual(out, m.apply_policy(out, policy()))
        self.assertEqual(before, config())

    def test_bucket_count_does_not_multiply_provider_health_checks(self):
        out = m.apply_policy(config(), policy())
        providers = out['proxy-providers']
        self.assertEqual(len(providers), 3)
        self.assertTrue(all(len(p['payload']) == 4 for p in providers.values()))
        slots = [g for g in out['proxy-groups'] if g['name'].startswith('ADAPTIVE-TOKYO-')]
        self.assertEqual(len(slots), 24)
        self.assertTrue(all(g['use'] == ['ADAPTIVE-NODES-TOKYO'] for g in slots))
        self.assertTrue(all('proxies' not in g for g in slots))

    def test_paid_alias_removed_and_only_rule_actions_are_retargeted(self):
        c = config()
        c['proxy-groups'] += [dict(name='AUTO', type='fallback', proxies=['TOKYO-POOL']),
                              dict(name='PAID', type='fallback', proxies=['TOKYO-POOL']),
                              dict(name='OTHER', type='select', proxies=['PAID', 'AUTO'])]
        c['rules'] += ['RULE-SET,autolearn-paid,PAID', 'IP-CIDR,1.2.3.4/32,PAID,no-resolve',
                       'PROCESS-NAME,PAID,DIRECT']
        out = m.apply_policy(c, policy())
        groups = {g['name']: g for g in out['proxy-groups']}
        self.assertNotIn('PAID', groups)
        self.assertEqual(groups['OTHER']['proxies'], ['AUTO'])
        self.assertIn('RULE-SET,autolearn-paid,AUTO', out['rules'])
        self.assertIn('IP-CIDR,1.2.3.4/32,AUTO,no-resolve', out['rules'])
        self.assertIn('PROCESS-NAME,PAID,DIRECT', out['rules'])

    def test_legacy_builder_never_injects_internal_providers_into_apps(self):
        spec = importlib.util.spec_from_file_location('multi', ROOT / 'tools/Build-MultiWanConfig.py')
        multi = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(multi)
        base = config()
        base['proxies'] += [dict(name=n, type='vless', server='example.test')
                            for n in ('aliyun-tokyo', 'aliyun-la')]
        base['proxy-groups'] += [dict(name=n, type='fallback', proxies=['aliyun-tokyo'])
                                 for n in ('AUTO', 'PAID', 'DATA')]
        wrapped = m.apply_policy(base, policy())
        rebuilt = m.apply_policy(multi.transform(wrapped, ['jd_5G']), policy())
        apps = [g for g in rebuilt['proxy-groups'] if not g['name'].startswith('ADAPTIVE-')]
        self.assertTrue(all(not any(n.startswith('ADAPTIVE-NODES-') for n in g.get('use', [])) for g in apps))

    def test_health_is_url_specific_and_stale_data_cannot_revive_a_link(self):
        api = FakeAPI()
        node = api.proxies['WAN-jd_5G']
        self.assertFalse(m.health_sample(node, 'https://unrelated.test/', 1000)['healthy'])
        self.assertTrue(m.health_sample(node, m.REGIONS['WAN'][2], 1000)['healthy'])
        self.assertFalse(m.health_sample(node, m.REGIONS['WAN'][2], 1200)['healthy'])

    def test_disabled_region_restores_regular_pool_without_dangling_slots(self):
        p = policy()
        out = m.apply_policy(config(), p)
        p['enabledRegions'] = ['TOKYO']
        changed = m.apply_policy(out, p)
        groups = {g['name']: g for g in changed['proxy-groups']}
        self.assertNotIn('WAN-ACTIVE', groups)
        self.assertNotIn('WAN-ACTIVE', groups['DISPATCH']['proxies'])
        self.assertEqual(groups['LA-ACTIVE']['proxies'], ['LA-win_turbo_phone', 'LA-pisen_2026_10'])
        self.assertFalse(any(n.startswith('ADAPTIVE-LA-') for n in groups))
        self.assertEqual(changed, m.apply_policy(changed, p))

    def test_recovery_requires_two_distinct_successes(self):
        failed = m.update_metric({}, sample(1000, ok=False), 5, 0, 0)
        first = m.update_metric(failed, sample(1010), 5, 0, 0)
        repeated = m.update_metric(first, sample(1010), 5, 0, 0)
        self.assertEqual(repeated['score'], 0)
        second = m.update_metric(repeated, sample(1020), 5, 0, 0)
        self.assertEqual(second['score'], 5)

    def test_idle_demand_and_busy_rate_do_not_bias_capacity_weights(self):
        quiet = m.update_metric({}, sample(1000), 5, 0, 0)
        busy = m.update_metric({}, sample(1000), 5, 100, 10000)
        self.assertEqual(quiet['score'], busy['score'])
        self.assertEqual(busy['capacity_mbps'], 5)

    def test_invalid_policy_rejected(self):
        for cap in [0, -1, float('nan'), float('inf')]:
            p = policy()
            p['capacitiesMbps']['WAN']['jd_5G'] = cap
            with self.assertRaises(ValueError):
                m.validate_policy(p)
        p = policy()
        p['slots'] = 12
        with self.assertRaises(ValueError):
            m.validate_policy(p)

    def test_observe_only_never_mutates_controller(self):
        with tempfile.TemporaryDirectory() as d:
            api = FakeAPI()
            p = policy()
            p['capacitiesMbps']['WAN']['jd_5G'] = 100
            c = m.Controller(p, Path(d), api)
            c.tick(now=1000, observe_only=True)
            self.assertEqual(api.puts, [])

    def test_normal_weight_change_is_limited_to_one_bucket_and_cooldown(self):
        with tempfile.TemporaryDirectory() as d:
            api = FakeAPI()
            p = policy()
            p['capacitiesMbps']['WAN']['jd_5G'] = 100
            c = m.Controller(p, Path(d), api)
            c.tick(now=1000)
            self.assertEqual(len(api.puts), 1)
            c.tick(now=1010)
            self.assertEqual(len(api.puts), 1)

    def test_emergency_evacuates_every_failed_bucket_immediately(self):
        with tempfile.TemporaryDirectory() as d:
            api = FakeAPI()
            api.proxies['WAN-jd_5G']['extra'][m.REGIONS['WAN'][2]]['alive'] = False
            c = m.Controller(policy(), Path(d), api)
            c.tick(now=1000)
            self.assertEqual(len(api.puts), 6)
            self.assertTrue(all(new != m.managed_path('WAN', 'jd_5G') for _, new in api.puts))

    def test_recovered_path_regains_its_share_without_long_cooldown_starvation(self):
        with tempfile.TemporaryDirectory() as d:
            api = FakeAPI()
            health = api.proxies['WAN-jd_5G']['extra'][m.REGIONS['WAN'][2]]
            health['alive'] = False
            c = m.Controller(policy(), Path(d), api)
            c.tick(now=1000)
            health['alive'] = True
            for stamp in [1010, 1020]:
                health['history'] = [{'time': dt.datetime.fromtimestamp(stamp, dt.timezone.utc).isoformat(), 'delay': 100}]
                status = c.tick(now=stamp)
            self.assertEqual(status['regions']['WAN']['allocation'][m.managed_path('WAN', 'jd_5G')], 6)

    def test_all_failed_leaves_engine_fallbacks_untouched(self):
        with tempfile.TemporaryDirectory() as d:
            api = FakeAPI()
            for region, (prefix, _, url, _) in m.REGIONS.items():
                for a in m.ADAPTERS:
                    api.proxies[prefix+a]['extra'][url]['alive'] = False
            c = m.Controller(policy(), Path(d), api)
            status = c.tick(now=1000)
            self.assertEqual(api.puts, [])
            self.assertTrue(all(r['status'].startswith('all_paths_unavailable') for r in status['regions'].values()))

    def test_polled_counters_do_not_invent_start_bytes_or_leak_metadata(self):
        with tempfile.TemporaryDirectory() as d:
            c = m.Controller(policy(), Path(d), FakeAPI())
            conn = dict(id='PRIVATE-ID', chains=['WAN-jd_5G'], download=1000000, upload=0,
                        metadata={'host': 'SECRET-HOST', 'authorization': 'SECRET-TOKEN'})
            self.assertEqual(c.flows([conn], 1000)['WAN-jd_5G']['bytes'], 0)
            conn['download'] += 100000
            self.assertEqual(c.flows([conn], 1010)['WAN-jd_5G']['bytes'], 100000)
            c.flows([], 1020)
            log = (Path(d) / 'dispatch.jsonl').read_text()
            for secret in ['PRIVATE-ID', 'SECRET-HOST', 'SECRET-TOKEN']:
                self.assertNotIn(secret, log)
            self.assertEqual(json.loads(log)['observed_bytes'], 100000)

    def test_log_rotation_is_bounded(self):
        with tempfile.TemporaryDirectory() as d:
            logger = m.make_logger(Path(d), max_bytes=512, backups=2)
            for _ in range(100):
                logger.info('x' * 100)
            for h in logger.handlers:
                h.flush()
            self.assertLessEqual(len(list(Path(d).glob('dispatch.jsonl*'))), 3)

    def test_daily_rollup_uses_only_counter_deltas_and_survives_restart(self):
        with tempfile.TemporaryDirectory() as d:
            api = FakeAPI()
            c = m.Controller(policy(), Path(d), api)
            api.connections = [dict(id='x', chains=['WAN-jd_5G'], download=1000000, upload=0)]
            c.tick(now=1000, observe_only=True)
            api.connections[0]['download'] += 50000
            c.tick(now=1010, observe_only=True)
            daily = next(Path(d).glob('daily-*.json'))
            self.assertEqual(json.loads(daily.read_text())['paths']['WAN-jd_5G']['observed_bytes'], 50000)
            other = m.Controller(policy(), Path(d), api)
            other.tick(now=1020, observe_only=True)
            self.assertEqual(json.loads(daily.read_text())['paths']['WAN-jd_5G']['observed_bytes'], 50000)

    def test_daily_retention_counts_the_new_day(self):
        with tempfile.TemporaryDirectory() as d:
            now = dt.datetime.now(dt.timezone.utc)
            for days in range(1, 31):
                day = (now - dt.timedelta(days=days)).date().isoformat()
                (Path(d) / ('daily-'+day+'.json')).write_text('{}')
            c = m.Controller(policy(), Path(d), FakeAPI(now.timestamp()))
            c.tick(now=now.timestamp(), observe_only=True)
            self.assertEqual(len(list(Path(d).glob('daily-*.json'))), 30)

    def test_regional_hold_down_requires_sustained_recovery(self):
        with tempfile.TemporaryDirectory() as d:
            api = FakeAPI()
            for name in ('AUTO', 'DATA'):
                api.proxies[name] = dict(type='Fallback', now='TOKYO-POOL', fixed='', all=['TOKYO-POOL', 'LA-POOL'])
            p = policy()
            p['regionalStability'] = dict(enabled=True, minHealthyPaths=2, minHealthyChecks=3,
                                          minimumStableSeconds=60, holdDownSeconds=180)
            c = m.Controller(p, Path(d), api)
            def tick(stamp, bad_tokyo=False):
                for region, (prefix, _, url, _) in m.REGIONS.items():
                    for a in m.ADAPTERS:
                        state = api.proxies[prefix+a]['extra'][url]
                        state['alive'] = not (bad_tokyo and region == 'TOKYO')
                        state['history'] = [{'time': dt.datetime.fromtimestamp(stamp, dt.timezone.utc).isoformat(), 'delay': 100 if state['alive'] else 0}]
                return c.tick(now=stamp)
            self.assertEqual(tick(1000)['regional_choice']['selected'], 'LA')
            tick(1030)
            self.assertEqual(tick(1060)['regional_choice']['selected'], 'TOKYO')
            self.assertEqual(tick(1070, True)['regional_choice']['selected'], 'LA')
            for stamp in (1080, 1110, 1140, 1170, 1200, 1230):
                self.assertEqual(tick(stamp)['regional_choice']['selected'], 'LA')
            self.assertEqual(tick(1260)['regional_choice']['selected'], 'TOKYO')

    def test_releasing_regional_pin_respects_a_subsequent_manual_selection(self):
        with tempfile.TemporaryDirectory() as d:
            api = FakeAPI()
            api.proxies['AUTO'] = dict(fixed='TOKYO-POOL')
            api.proxies['DATA'] = dict(fixed='LA-POOL')
            c = m.Controller(policy(), Path(d), api)
            c.bulk_pins = {'AUTO': 'LA-POOL', 'DATA': 'LA-POOL'}
            c.release_bulk_pins()
            self.assertEqual(api.deleted, ['DATA'])


if __name__ == '__main__':
    unittest.main()
