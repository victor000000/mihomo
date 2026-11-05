#!/usr/bin/env python3
"""Passive WSL Theta telemetry. Sends no network or market-data requests."""
import argparse
import collections
import datetime as dt
import fcntl
import ipaddress
import json
import logging
from logging.handlers import RotatingFileHandler
import math
import os
from pathlib import Path
import re
import subprocess
import time


def save(path, value):
    temp = path.with_suffix('.tmp')
    temp.write_text(json.dumps(value, indent=2))
    temp.replace(path)


def terminal_processes(allowed_root=None):
    roots, parents = set(), {}
    for p in Path('/proc').iterdir():
        if not p.name.isdigit():
            continue
        try:
            if p.joinpath('comm').read_text().strip() != 'java':
                continue
            args = p.joinpath('cmdline').read_bytes().split(b'\0')
            for argument in args:
                jar = Path(argument.decode(errors='replace'))
                if jar.name.lower() not in ('thetaterminalv3.jar', 'thetaterminal3.jar'):
                    continue
                resolved = (jar if jar.is_absolute() else p.joinpath('cwd').resolve()/jar).resolve()
                if allowed_root is None or resolved.is_relative_to(allowed_root.resolve()):
                    roots.add(int(p.name))
            status = p.joinpath('status').read_text()
            parents[int(p.name)] = int(re.search(r'^PPid:\s+(\d+)', status, re.M).group(1))
        except (OSError, ValueError, AttributeError):
            continue
    selected = set(roots)
    while True:
        children = {pid for pid, parent in parents.items() if parent in selected}
        if children <= selected:
            return selected
        selected |= children


def parse_sockets(raw, pids, adapter_addresses):
    """Internal socket keys never leave this function's caller or enter logs."""
    result = {}
    lines = raw.splitlines()
    for i, line in enumerate(lines):
        found = re.search(r'pid=(\d+)', line)
        if not found or int(found.group(1)) not in pids:
            continue
        fields = line.split()
        if len(fields) < 5:
            continue
        info = lines[i+1] if i+1 < len(lines) and not re.search(r'pid=\d+', lines[i+1]) else ''
        def number(name):
            m = re.search(r'\b'+name+r':([\d.]+)', info)
            return float(m.group(1)) if m else 0
        source = fields[3].rsplit(':', 1)[0].strip('[]').removeprefix('::ffff:')
        peer, port = fields[4].rsplit(':', 1)
        peer = peer.strip('[]').removeprefix('::ffff:')
        try:
            relay = port == '7897' and ipaddress.ip_address(peer).is_loopback
        except ValueError:
            relay = False
        key = (int(found.group(1)), fields[3], fields[4])
        result[key] = dict(received=int(number('bytes_received')), sent=int(number('bytes_sent')),
                           rtt_ms=number('rtt'), retrans=int(number('bytes_retrans')),
                           receive_queue=int(fields[1]), send_queue=int(fields[2]),
                           last_receive_ms=number('lastrcv'),
                           transport='local_proxy_relay' if relay else 'direct_tls',
                           state=fields[0] if fields[0] in {'ESTAB','CLOSE-WAIT','FIN-WAIT-1','FIN-WAIT-2','SYN-SENT','LAST-ACK','CLOSING','TIME-WAIT'} else 'OTHER',
                           established=fields[0] == 'ESTAB', adapter=adapter_addresses.get(source, 'unmapped'))
    return result


def socket_deltas(current, previous, initialized):
    """Closed sockets are observations, not proven unexpected disconnections."""
    counts = dict(received=0, sent=0, retrans=0,
                  opened=len(current.keys()-previous.keys()) if initialized else 0,
                  disappeared=len(previous.keys()-current.keys()) if initialized else 0)
    for key, value in current.items():
        old = previous.get(key)
        if old or initialized:
            for metric in ('received', 'sent', 'retrans'):
                counts[metric] += max(0, value[metric]-(old[metric] if old else 0))
    return counts


def rolling_receive(history, now, total, window_seconds=30):
    """Use cumulative progress so a quiet one-second sample is not called idle."""
    if history and (now < history[-1][0] or total < history[-1][1]):
        history.clear()
    history.append((now, total))
    while len(history) > 1 and history[1][0] <= now-window_seconds:
        history.popleft()
    elapsed = max(0, now-history[0][0])
    received = total-history[0][1]
    return dict(receive_window_seconds=round(elapsed, 3),
                receive_window_bytes=received,
                receive_window_mbps=round(received*8/elapsed/1e6, 4) if elapsed else 0)


def adapter_addresses(repository):
    entries = json.loads((repository / 'config/mihomo-adapters.json').read_text(encoding='utf-8-sig'))
    macs = {x['mac'].lower().replace('-', ':'): x['name'] for x in entries}
    ips = {x['ipv4Address']: x['name'] for x in entries if x.get('ipv4Address')}
    raw = subprocess.run(['ip', '-j', 'address', 'show'], capture_output=True, text=True, check=True).stdout
    for interface in json.loads(raw):
        label = macs.get(interface.get('address', '').lower(), interface['ifname'])
        for address in interface.get('addr_info', []):
            ips[address['local']] = macs.get(interface.get('address', '').lower(), ips.get(address['local'], label))
    return ips


class Observer:
    def __init__(self, repository, data_root, directory):
        self.repository, self.data_root, self.directory = repository, data_root, directory
        self.started_utc = dt.datetime.now(dt.timezone.utc).isoformat()
        self.addresses = adapter_addresses(repository)
        self.previous_sockets, self.previous_cpu, self.receipts = {}, {}, {}
        self.last = None
        self.total_received, self.total_sent = 0, 0
        self.receive_history = collections.deque()
        self.receipts_initialized = False
        self.last_receipt_scan = None
        self.logger = logging.getLogger('theta-network-observer')
        self.logger.setLevel(logging.INFO)
        handler = RotatingFileHandler(directory / 'telemetry.jsonl', maxBytes=5*1024*1024, backupCount=3)
        handler.setFormatter(logging.Formatter('%(message)s'))
        self.logger.addHandler(handler)

    def log(self, event, **value):
        record = dict(utc=dt.datetime.now(dt.timezone.utc).isoformat(), event=event)
        record.update(value)
        self.logger.info(json.dumps(record))

    def completed_receipts(self):
        completed = []
        maintenance = self.data_root / 'runtime/var/maintenance'
        for directory in maintenance.iterdir():
            if not directory.is_dir():
                continue
            for p in directory.glob('*.json'):
                if len(p.stem) != 64 or not re.fullmatch('[0-9a-f]+', p.stem):
                    continue
                try:
                    stat = p.stat()
                    if stat.st_size > 2*1024*1024:
                        continue
                    old = self.receipts.get(p)
                    if old and old[0] == stat.st_mtime_ns:
                        continue
                    r = json.loads(p.read_text())
                    if not isinstance(r, dict) or 'endpoint' not in r:
                        continue
                    # Current acquisitions also use ticker-named directories.
                    # Require provider provenance outside the legacy theta-* scope.
                    if not directory.name.startswith('theta-') and r.get('source') != 'thetadata_v3':
                        continue
                    self.receipts[p] = (stat.st_mtime_ns, r.get('status'))
                    terminal = r.get('status') not in (None, 'in_flight', 'reserved')
                    if self.receipts_initialized and terminal and (not old or old[1] in ('in_flight', 'reserved')):
                        endpoint = r['endpoint'] if re.fullmatch('[a-z_/]{1,128}', r['endpoint']) else 'other'
                        safe_status = r.get('status') if r.get('status') in {
                            'downloaded', 'not_entitled', 'missing_upstream', 'denied_no_replay',
                            'empty_or_failed_no_replay', 'uncertain_no_replay', 'request_failed',
                            'failed_no_replay', 'invalid_response'} else 'other'
                        def numeric(name):
                            v = r.get(name)
                            return v if isinstance(v, (int, float)) and not isinstance(v, bool) and math.isfinite(v) and v >= 0 else None
                        item = dict(endpoint=endpoint, status=safe_status, rows=numeric('rows'),
                                    elapsed_seconds=numeric('elapsed_seconds'), headers_seconds=numeric('headers_seconds'))
                        timing = r.get('timing', {})
                        if isinstance(timing, dict):
                            item['timing'] = {
                                key: value for key in ('lock_wait_seconds', 'pacing_seconds',
                                    'http_seconds', 'response_headers_seconds',
                                    'post_headers_seconds_estimate', 'decoded_response_bytes')
                                if isinstance((value := timing.get(key)), (int, float))
                                and not isinstance(value, bool) and math.isfinite(value) and value >= 0}
                        completed.append(item)
                        self.log('receipt_completion_observed', **item)
                except (OSError, ValueError, TypeError):
                    continue
        self.receipts_initialized = True
        return completed

    def sample(self, now=None):
        now = time.monotonic() if now is None else now
        pids = terminal_processes(self.data_root / 'runtime/tools')
        raw = subprocess.run(['ss', '-tinp', '( dport = :443 or dport = :7897 )'], capture_output=True, text=True, timeout=3, check=True).stdout
        sockets = parse_sockets(raw, pids, self.addresses)
        elapsed = max(.001, now-self.last) if self.last is not None else None
        delta = socket_deltas(sockets, self.previous_sockets, self.last is not None)
        received, sent = delta['received'], delta['sent']
        cpu = {}
        cpu_ticks = rss = 0
        for pid in pids:
            try:
                fields = (Path('/proc') / str(pid) / 'stat').read_text().rsplit(')', 1)[1].split()
                ticks = int(fields[11])+int(fields[12])
                cpu[pid] = ticks
                if pid in self.previous_cpu:
                    cpu_ticks += max(0, ticks-self.previous_cpu[pid])
                rss += int(fields[21])*os.sysconf('SC_PAGE_SIZE')
            except (OSError, ValueError, IndexError):
                continue
        self.total_received += received
        self.total_sent += sent
        window = rolling_receive(self.receive_history, now, self.total_received)
        self.previous_sockets, self.previous_cpu, self.last = sockets, cpu, now
        active = [s for s in sockets.values() if s['established']]
        direct = [s for s in active if s['transport'] == 'direct_tls']
        relays = [s for s in active if s['transport'] == 'local_proxy_relay']
        rtts = [s['rtt_ms'] for s in direct if s['rtt_ms'] > 0]
        relay_rtts = [s['rtt_ms'] for s in relays if s['rtt_ms'] > 0]
        completed = []
        # Bound metadata work as the request ledger grows; sockets still sample each second.
        if self.last_receipt_scan is None or now-self.last_receipt_scan >= 10:
            completed = self.completed_receipts()
            self.last_receipt_scan = now
        status = dict(utc=dt.datetime.now(dt.timezone.utc).isoformat(), sample_epoch=time.time(),
                      observer_pid=os.getpid(), observer_started_utc=self.started_utc,
                      state='terminal_running' if pids else 'terminal_not_running', java_processes=len(pids),
                      upstream_tls_connections=len(direct), local_proxy_relay_connections=len(relays),
                      established_transport_connections=len(active),
                      transport_mode='mixed' if direct and relays else 'local_proxy_relay' if relays else 'direct_tls' if direct else 'idle',
                      adapters=dict(collections.Counter(s['adapter'] for s in direct)),
                      socket_states=dict(collections.Counter(s['state'] for s in sockets.values())),
                      received_bytes_delta=received, sent_bytes_delta=sent,
                      sent_retransmitted_bytes_delta=delta['retrans'],
                      sockets_opened=delta['opened'], sockets_disappeared=delta['disappeared'],
                      receive_queue_bytes=sum(s['receive_queue'] for s in active),
                      send_queue_bytes=sum(s['send_queue'] for s in active),
                      longest_receive_idle_ms=max((s['last_receive_ms'] for s in active), default=None),
                      observed_received_bytes=self.total_received, observed_sent_bytes=self.total_sent,
                      observed_receive_mbps=round(received*8/elapsed/1e6, 4) if elapsed else 0,
                      rtt_ms_min=min(rtts) if rtts else None, rtt_ms_max=max(rtts) if rtts else None,
                      relay_rtt_ms_min=min(relay_rtts) if relay_rtts else None,
                      relay_rtt_ms_max=max(relay_rtts) if relay_rtts else None,
                      cpu_percent_one_core=round(cpu_ticks/os.sysconf('SC_CLK_TCK')/elapsed*100, 2) if elapsed else 0,
                      process_rss_mib=round(rss/1024/1024, 1), completed_receipts=completed,
                      requests_sent=0, observer_requests_sent=0,
                      requests_sent_scope='observer only; provider acquisition count is not measured here',
                      route_changes=0,
                      limits='Passive transport counters are not CSV or physical wire throughput. Relay RTT is localhost only, never Internet RTT. Direct RTT excludes relays. Closed-between-poll bytes may be missed. Retransmissions cover local sends only. Socket closure/idle does not establish failure or server stall.')
        status.update(window)
        save(self.directory / 'status.json', status)
        mirror = self.data_root / 'runtime/var/maintenance/theta-network-observer'
        mirror.mkdir(parents=True, exist_ok=True)
        save(mirror / 'latest.json', status)
        return status


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--repository', type=Path, default=Path(__file__).resolve().parents[1])
    parser.add_argument('--data-root', type=Path, default=Path('/home/vic/data_providers'))
    parser.add_argument('--once', action='store_true')
    args = parser.parse_args()
    directory = args.repository / 'state/native-theta'
    directory.mkdir(parents=True, exist_ok=True)
    lock = (directory / 'observer.lock').open('a+b')
    try:
        fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
    except BlockingIOError:
        return
    observer = Observer(args.repository, args.data_root, directory)
    observer.log('observer_start', requests_sent=0)
    last_log = 0
    try:
        while True:
            try:
                status = observer.sample()
                if time.monotonic()-last_log >= 5:
                    observer.log('sample', **status)
                    last_log = time.monotonic()
            except Exception as exc:
                observer.log('observer_error', error_type=type(exc).__name__)
                if args.once:
                    raise
            if args.once:
                break
            time.sleep(1)
    finally:
        observer.log('observer_stop')
        lock.close()


if __name__ == '__main__':
    main()
