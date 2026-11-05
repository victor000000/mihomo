import importlib.util
import collections
import json
from pathlib import Path
import tempfile
import unittest
import sys
from unittest.mock import Mock, patch

if sys.platform == 'win32':
    raise unittest.SkipTest('Passive observer requires Linux/WSL; covered by the Linux CI job')

ROOT = Path(__file__).resolve().parents[2]
SPEC = importlib.util.spec_from_file_location('theta_observer', ROOT/'tools/ObserveThetaNetwork.py')
m = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(m)


class ObserverTests(unittest.TestCase):
    def test_rolling_receive_retains_burst_progress_and_ages_it_out(self):
        history = collections.deque()
        self.assertEqual(m.rolling_receive(history, 0, 0)['receive_window_bytes'], 0)
        m.rolling_receive(history, 1, 1000)
        quiet = m.rolling_receive(history, 2, 1000)
        self.assertEqual(quiet['receive_window_bytes'], 1000)
        self.assertEqual(quiet['receive_window_seconds'], 2)
        m.rolling_receive(history, 30, 1000)
        self.assertEqual(m.rolling_receive(history, 31, 1000)['receive_window_bytes'], 0)
        self.assertEqual(m.rolling_receive(history, 32, 0)['receive_window_bytes'], 0)

    def test_status_excludes_local_relay_rtt_from_upstream_metrics(self):
        raw = 'ESTAB 0 0 127.0.0.1:45706 127.0.0.1:7897 users:(("java",pid=42,fd=3))\n cubic rtt:0.4/0.1 bytes_received:100\n'
        with tempfile.TemporaryDirectory() as d, \
                patch.object(m, 'adapter_addresses', return_value={}), \
                patch.object(m, 'terminal_processes', return_value={42}), \
                patch.object(m.subprocess, 'run', return_value=Mock(stdout=raw)):
            root = Path(d)
            observer = m.Observer(root, root, root)
            observer.completed_receipts = Mock(return_value=[])
            status = observer.sample(now=1)
            self.assertEqual(status['transport_mode'], 'local_proxy_relay')
            self.assertEqual(status['upstream_tls_connections'], 0)
            self.assertEqual(status['local_proxy_relay_connections'], 1)
            self.assertIsNone(status['rtt_ms_min'])
            self.assertEqual(status['relay_rtt_ms_min'], 0.4)
            self.assertEqual(status['adapters'], {})
            self.assertEqual(status['receive_window_bytes'], 0)
            self.assertIn('observer only', status['requests_sent_scope'])
            self.assertGreater(status['observer_pid'], 0)
            for handler in observer.logger.handlers[:]:
                handler.close()
                observer.logger.removeHandler(handler)

    def test_proxy_relay_is_not_an_internet_rtt_or_physical_adapter(self):
        raw = 'ESTAB 0 0 [::ffff:127.0.0.1]:45706 [::ffff:127.0.0.1]:7897 users:(("java",pid=42,fd=3))\n cubic rtt:0.461/0.4 bytes_received:100\n'
        row = next(iter(m.parse_sockets(raw, {42}, {}).values()))
        self.assertEqual(row['transport'], 'local_proxy_relay')
        direct = 'ESTAB 0 0 10.0.0.2:1 203.0.113.9:443 users:(("java",pid=42,fd=3))\n cubic rtt:320/5\n'
        self.assertEqual(next(iter(m.parse_sockets(direct, {42}, {}).values()))['transport'], 'direct_tls')

    def test_ticker_receipt_scope_requires_theta_provenance_and_sanitizes_timings(self):
        with tempfile.TemporaryDirectory() as d:
            root = Path(d)
            folder = root/'runtime/var/maintenance/ibit-extension-greeks'
            folder.mkdir(parents=True)
            observer = m.Observer.__new__(m.Observer)
            observer.data_root = root
            observer.receipts = {}
            observer.receipts_initialized = True
            observer.log = Mock()
            receipt = dict(endpoint='option/history/greeks/first_order', status='downloaded',
                           source='other', timing={'http_seconds':2.5})
            p = folder/('d'*64+'.json')
            p.write_text(json.dumps(receipt))
            self.assertEqual(observer.completed_receipts(), [])
            receipt.update(source='thetadata_v3', params={'secret':'SECRET'},
                           timing={'http_seconds':2.5,'lock_wait_seconds':10,
                                   'decoded_response_bytes':123,'response_headers_seconds':'SECRET',
                                   'pacing_seconds':True,'private':'SECRET'})
            p.write_text(json.dumps(receipt))
            result = observer.completed_receipts()
            self.assertEqual(len(result),1)
            self.assertEqual(result[0]['timing'],dict(http_seconds=2.5,lock_wait_seconds=10,decoded_response_bytes=123))
            self.assertNotIn('SECRET',str(observer.log.call_args_list))

    def test_counter_baseline_churn_and_reset(self):
        first = {'a':dict(received=100,sent=20,retrans=4)}
        self.assertEqual(m.socket_deltas(first, {}, False)['received'], 0)
        second = {'a':dict(received=150,sent=30,retrans=6),
                  'b':dict(received=10,sent=2,retrans=0)}
        self.assertEqual(m.socket_deltas(second, first, True),
                         dict(received=60,sent=12,retrans=2,opened=1,disappeared=0))
        self.assertEqual(m.socket_deltas({}, second, True)['disappeared'],2)
        reset = {'a':dict(received=1,sent=1,retrans=0)}
        self.assertEqual(m.socket_deltas(reset, first, True)['received'],0)

    def test_socket_filter_and_mapped_ipv4_source(self):
        raw = '''State Recv-Q Send-Q Local Peer Process
ESTAB 0 0 [::ffff:10.0.0.2]:4567 [::ffff:203.0.113.9]:443 users:(("java",pid=42,fd=3))
 cubic rtt:123.4/5 bytes_sent:200 bytes_received:1000
ESTAB 0 0 10.0.0.2:4568 203.0.113.9:443 users:(("other",pid=99,fd=4))
 cubic rtt:5/1 bytes_received:999999
'''
        rows = m.parse_sockets(raw, {42}, {'10.0.0.2':'test-adapter'})
        self.assertEqual(len(rows), 1)
        value = next(iter(rows.values()))
        self.assertEqual(value['received'], 1000)
        self.assertEqual(value['rtt_ms'], 123.4)
        self.assertEqual(value['adapter'], 'test-adapter')

    def test_absent_tcp_counters_are_not_invented(self):
        raw='ESTAB 0 0 10.0.0.2:1 203.0.113.9:443 users:(("java",pid=42,fd=3))\n cubic\n'
        row=next(iter(m.parse_sockets(raw, {42}, {}).values()))
        self.assertEqual(row['received'],0)
        self.assertEqual(row['adapter'],'unmapped')

    def test_receipt_observer_ignores_history_and_never_logs_params(self):
        with tempfile.TemporaryDirectory() as d:
            root=Path(d)
            folder=root/'runtime/var/maintenance/theta-test'
            folder.mkdir(parents=True)
            old=folder/('a'*64+'.json')
            old.write_text(json.dumps(dict(endpoint='option/history/quote',status='downloaded',params={'token':'SECRET'})))
            observer=m.Observer.__new__(m.Observer)
            observer.data_root=root
            observer.receipts={}
            observer.receipts_initialized=False
            observer.log=Mock()
            self.assertEqual(observer.completed_receipts(),[])
            new=folder/('b'*64+'.json')
            new.write_text(json.dumps(dict(endpoint='option/history/quote',status='in_flight',params={'token':'SECRET'})))
            self.assertEqual(observer.completed_receipts(),[])
            new.write_text(json.dumps(dict(endpoint='option/history/quote',status='downloaded',rows=10,elapsed_seconds=2.5,params={'token':'SECRET'})))
            rows=observer.completed_receipts()
            self.assertEqual(len(rows),1)
            self.assertEqual(rows[0]['elapsed_seconds'],2.5)
            self.assertNotIn('SECRET',str(observer.log.call_args_list))
            self.assertEqual(observer.completed_receipts(),[])

    def test_sample_timestamp_does_not_collide_with_logger_timestamp(self):
        observer=m.Observer.__new__(m.Observer)
        observer.logger=Mock()
        observer.log('sample',utc='sample-time',requests_sent=0)
        record=json.loads(observer.logger.info.call_args.args[0])
        self.assertEqual(record['utc'],'sample-time')
        self.assertEqual(record['requests_sent'],0)

    def test_unexpected_receipt_values_cannot_be_logged_as_status_or_metrics(self):
        with tempfile.TemporaryDirectory() as d:
            root=Path(d)
            folder=root/'runtime/var/maintenance/theta-test'
            folder.mkdir(parents=True)
            observer=m.Observer.__new__(m.Observer)
            observer.data_root=root
            observer.receipts={}
            observer.receipts_initialized=True
            observer.log=Mock()
            (folder/('c'*64+'.json')).write_text(json.dumps(dict(endpoint='option/history/quote',status='SECRET',rows='SECRET',elapsed_seconds='SECRET')))
            result=observer.completed_receipts()[0]
            self.assertEqual(result['status'],'other')
            self.assertIsNone(result['rows'])
            self.assertNotIn('SECRET',str(observer.log.call_args_list))


if __name__=='__main__':
    unittest.main()
