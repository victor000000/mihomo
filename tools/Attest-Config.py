#!/usr/bin/env python3
"""Compare two local configs without emitting configuration values or contacting services."""
import argparse
import hashlib
import json
from pathlib import Path
import sys

import yaml


class UniqueLoader(yaml.SafeLoader):
    pass


def unique_mapping(loader, node):
    # YAML merge keys complicate duplicate detection; require explicit mappings.
    if any(key.tag == 'tag:yaml.org,2002:merge' for key, _ in node.value):
        raise ValueError('merge keys unsupported')
    result = {}
    for key, value in node.value:
        key = loader.construct_object(key)
        if not isinstance(key, str) or key in result:
            raise ValueError('mapping keys must be unique strings')
        result[key] = loader.construct_object(value)
    return result


UniqueLoader.add_constructor('tag:yaml.org,2002:map', unique_mapping)


def load_config(raw):
    value = yaml.load(raw, Loader=UniqueLoader)
    if not isinstance(value, dict):
        raise ValueError('configuration must be a mapping')
    # Reject non-JSON scalar types, including timestamps and non-finite numbers.
    json.dumps(value, allow_nan=False)
    for key in ('rules', 'proxies', 'proxy-groups', 'listeners'):
        if key in value and not isinstance(value[key], list):
            raise ValueError('configuration section must be a list')
    if any(not isinstance(rule, str) for rule in value.get('rules', [])):
        raise ValueError('rules must be strings')
    return value


def fingerprint(value):
    return hashlib.sha256(json.dumps(value, sort_keys=True, ensure_ascii=True,
                                    allow_nan=False).encode()).hexdigest()


def attest(before_raw, after_raw):
    before, after = load_config(before_raw), load_config(after_raw)
    # Fixed schema labels only: arbitrary YAML keys and values never enter output.
    sections = ('rules', 'proxies', 'proxy-groups', 'listeners', 'dns', 'tun',
                'hosts', 'proxy-providers', 'rule-providers')
    changed = [key for key in sections if fingerprint(before.get(key)) != fingerprint(after.get(key))
               or (key in before) != (key in after)]
    other_before = {k: v for k, v in before.items() if k not in sections}
    other_after = {k: v for k, v in after.items() if k not in sections}
    if fingerprint(other_before) != fingerprint(other_after):
        changed.append('other-settings')
    def theta_rules(config):
        return [rule for rule in config.get('rules', [])
                if any(part.strip().lower() in ('thetadata.net', 'thetadata.us')
                       for part in rule.split(','))]
    return dict(schema_version=1,
                before_sha256=hashlib.sha256(before_raw).hexdigest(),
                after_sha256=hashlib.sha256(after_raw).hexdigest(),
                bytes_equal=before_raw == after_raw,
                semantics_equal=fingerprint(before) == fingerprint(after),
                changed_sections=changed,
                theta_explicit_rules_equal=theta_rules(before) == theta_rules(after),
                limits='Offline comparison only. Equal explicit Theta rules do not establish '
                       'effective rule precedence, proxy-chain identity, loaded state, session '
                       'continuity, author identity, or request readiness.')


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('before', type=Path)
    parser.add_argument('after', type=Path)
    args = parser.parse_args(argv)
    try:
        report = attest(args.before.read_bytes(), args.after.read_bytes())
    except (OSError, ValueError, TypeError, yaml.YAMLError, RecursionError):
        # Parser exceptions can contain complete credential-bearing source lines.
        print(json.dumps({'error': 'Cannot attest: unreadable or unsupported configuration.'}))
        return 2
    print(json.dumps(report, indent=2))
    return 0


if __name__ == '__main__':
    sys.exit(main())
