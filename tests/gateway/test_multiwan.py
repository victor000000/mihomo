import copy,importlib.util,unittest,json
from pathlib import Path
spec=importlib.util.spec_from_file_location('multi',Path(__file__).resolve().parents[2]/'tools/Build-MultiWanConfig.py');m=importlib.util.module_from_spec(spec);spec.loader.exec_module(m)
class MultiWanTests(unittest.TestCase):
 def setUp(self):
  self.c={'proxies':[dict(name=n,type='vless',server='example.test') for n in ('aliyun-tokyo','aliyun-la','omr')],'proxy-providers':{'clashmi':{'type':'http','url':'https://example.test/provider','path':'./providers/clashmi.yaml'}},'proxy-groups':[dict(name=n,type='fallback',proxies=['aliyun-tokyo','omr']) for n in ('DISPATCH','LINGODA','ZOOM','CHATGPT','AUTO','PAID','DATA')],'rules':['DOMAIN-SUFFIX,lingoda.com,LINGODA','MATCH,AUTO']}
 def test_four_independent_paths_in_each_aliyun_pool(self):
  c=m.transform(self.c);nodes={p['name']:p for p in c['proxies']};groups={g['name']:g for g in c['proxy-groups']}
  for name in ('TOKYO-POOL','LA-POOL'):
   g=groups[name];self.assertEqual(g['type'],'load-balance');self.assertEqual({nodes[n]['interface-name'] for n in g['proxies']},set(m.ADAPTERS))
   for n in g['proxies']:self.assertNotIn('dialer-proxy',nodes[n])
 def test_upstream_outage_has_la_fallback(self):
  g={g['name']:g for g in m.transform(self.c)['proxy-groups']}
  self.assertEqual(g['AUTO']['type'],'fallback');self.assertEqual(g['AUTO']['proxies'],['TOKYO-POOL','LA-POOL'])
 def test_expired_provider_is_removed_from_legacy_inputs(self):
  self.c['proxy-providers']['wan911-jd_5G-clashmi']=copy.deepcopy(self.c['proxy-providers']['clashmi'])
  self.c['proxy-groups'].extend([dict(name='911-POOL',use=['clashmi']),dict(name='LEGACY-HK',use=['clashmi'])])
  self.c['proxy-groups'][0]['proxies'].append('911-POOL')
  self.c['rule-providers']={'clashmi-911':{'type':'file'},'keep':{'type':'file'}}
  self.c['rules'].insert(0,'RULE-SET,clashmi-911,AUTO')
  self.c['dns']={'nameserver-policy':{'domain:connect911.au':['1.1.1.1'],'example.com':['8.8.8.8']}}
  c=m.transform(self.c);g={x['name']:x for x in c['proxy-groups']}
  self.assertEqual(c['proxy-providers'],{});self.assertNotIn('911-POOL',g)
  self.assertEqual(g['LEGACY-HK']['proxies'],['aliyun-tokyo'])
  self.assertNotIn('use',g['LEGACY-HK']);self.assertEqual(list(c['rule-providers']),['keep'])
  self.assertEqual(c['rules'],self.c['rules'][1:]);self.assertEqual(list(c['dns']['nameserver-policy']),['example.com'])
  self.assertEqual(c,m.transform(c))
 def test_class_is_stable_with_remaining_upstreams(self):
  g={g['name']:g for g in m.transform(self.c)['proxy-groups']}
  for n in ('LINGODA','ZOOM','CHATGPT'):
   self.assertEqual(g[n]['type'],'fallback');self.assertEqual(g[n]['proxies'][:2],['aliyun-tokyo','aliyun-la']);self.assertNotIn('use',g[n])
 def test_explicit_direct_classroom_preference_survives_rebuild(self):
  for g in self.c['proxy-groups']:
   if g['name'] in ('LINGODA','ZOOM'):g['proxies'].insert(0,'WAN-jd_5G')
  c=m.transform(self.c);groups={g['name']:g for g in c['proxy-groups']}
  for n in ('LINGODA','ZOOM'):
   self.assertEqual(groups[n]['proxies'][:3],['WAN-jd_5G','aliyun-tokyo','aliyun-la'])
  self.assertEqual(c,m.transform(c))
 def test_codex_adapter_bound_preference_survives_rebuild(self):
  for g in self.c['proxy-groups']:
   if g['name']=='CHATGPT':g['proxies']=['BALANCED-jd_5G','LA-jd_5G']+g['proxies']
  c=m.transform(self.c);groups={g['name']:g for g in c['proxy-groups']}
  self.assertEqual(groups['CHATGPT']['proxies'][:2],['BALANCED-jd_5G','LA-jd_5G'])
  self.assertEqual(c,m.transform(c))
 def test_idempotent_and_no_vm_reference(self):
  c=m.transform(self.c);self.assertEqual(c,m.transform(c));self.assertFalse(set(p['name'] for p in c['proxies'])&m.RETIRED)
 def test_input_and_application_rules_preserved(self):
  old=copy.deepcopy(self.c);c=m.transform(self.c);self.assertEqual(self.c,old);self.assertEqual(c['rules'],old['rules'])
 def test_slow_adapter_is_backup_for_each_pool(self):
  c=m.transform(self.c, ['pisen_2026_03']);groups={g['name']:g for g in c['proxy-groups']}
  for region,prefix in [('TOKYO','BALANCED-'),('LA','LA-')]:
   self.assertEqual(groups[region+'-POOL']['proxies'],[region+'-ACTIVE',prefix+'pisen_2026_03'])
   self.assertEqual(groups[region+'-POOL']['type'],'fallback')
   self.assertEqual(set(groups[region+'-ACTIVE']['proxies']),{prefix+a for a in m.ADAPTERS if a!='pisen_2026_03'})
  self.assertNotIn('911-POOL',groups)
  self.assertEqual(c,m.transform(c,['pisen_2026_03']))
  self.assertEqual(c['rules'],self.c['rules'])
  self.assertIn('WAN-pisen_2026_03',groups['DISPATCH']['proxies'])
 def test_invalid_or_all_standby_adapters_rejected(self):
  for standby in (['unknown'],m.ADAPTERS):
   with self.assertRaises(ValueError):m.transform(self.c,standby)
 def test_clearing_standby_policy_restores_all_adapter_balancing(self):
  optimized=m.transform(self.c,['pisen_2026_03'])
  self.assertEqual(m.transform(optimized),m.transform(self.c))
class TemplateTests(unittest.TestCase):
 def test_template_is_current_and_has_no_dangling_proxy_references(self):
  c=m.yaml.safe_load((Path(__file__).resolve().parents[2]/'config/mihomo-config.template.yaml').read_text())
  policy=json.loads((Path(__file__).resolve().parents[2]/'config/network-architecture.json').read_text())
  generated=m.transform(c,policy.get('standbyAdapters',[]))
  # Named group order does not change routing; rules and member order still do.
  actual=copy.deepcopy(c)
  for policy in (actual,generated):
   policy['proxy-groups']={g['name']:g for g in policy['proxy-groups']}
  self.assertEqual(actual,generated)
  names={p['name'] for p in c['proxies']}|{g['name'] for g in c['proxy-groups']}|{'DIRECT','REJECT','REJECT-DROP','PASS','COMPATIBLE'}
  for g in c['proxy-groups']:
   for n in g.get('proxies',[]):self.assertIn(n,names)
   for n in g.get('use',[]):self.assertIn(n,c['proxy-providers'])
  for p in c['proxies']:
   if p.get('dialer-proxy'):self.assertIn(p['dialer-proxy'],names)

if __name__=='__main__':unittest.main()
