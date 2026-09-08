#!/usr/bin/env python3
"""Audit manually recorded host results; never execute or certify a model E2E."""

import argparse
import json
from pathlib import Path
import re
import sys

HOSTS = ('claude', 'codex', 'grok')
STAGES = ('installation', 'issue_create', 'draft', 'merge', 'recover', 'isolation')
METADATA = ('host', 'host_version', 'rite_commit', 'surface', 'execution_mode')


def init_record(host, output):
    record = {
        'metadata': {key: host if key == 'host' else '' for key in METADATA},
        'stages': {stage: {'status': 'unverified', 'reason': 'not_run', 'evidence': []}
                   for stage in STAGES},
    }
    with Path(output).open('x', encoding='utf-8') as stream:
        json.dump(record, stream, indent=2, ensure_ascii=False)
        stream.write('\n')
    print(f'Initialized {host}: all {len(STAGES)} stages unverified')
    return 0


def unique_object(pairs):
    result = {}
    for key, value in pairs:
        if key in result:
            raise ValueError(f'duplicate JSON key: {key}')
        result[key] = value
    return result


def validate_record(path):
    with path.open(encoding='utf-8') as stream:
        record = json.load(stream, object_pairs_hook=unique_object)
    if not isinstance(record, dict) or set(record) != {'metadata', 'stages'}:
        raise ValueError('record must contain metadata and stages')
    metadata, stages = record['metadata'], record['stages']
    if not isinstance(metadata, dict) or set(metadata) != set(METADATA):
        raise ValueError('metadata keys do not match schema')
    if not all(isinstance(value, str) for value in metadata.values()):
        raise ValueError('metadata values must be strings')
    if metadata['host'] not in HOSTS:
        raise ValueError('unknown host')
    if metadata['surface'] not in ('', 'development', 'distribution'):
        raise ValueError('surface must be development or distribution')
    if metadata['rite_commit'] and not re.fullmatch('[0-9a-fA-F]{40}', metadata['rite_commit']):
        raise ValueError('rite_commit must be a full 40-character Git revision')
    if not isinstance(stages, dict) or set(stages) != set(STAGES):
        raise ValueError('stages must contain exactly the six required stage keys')
    counts = dict.fromkeys(('pass', 'fail', 'unverified'), 0)
    for name, stage in stages.items():
        if not isinstance(stage, dict) or set(stage) != {'status', 'reason', 'evidence'}:
            raise ValueError(f'{name}: stage keys do not match schema')
        status, reason, evidence = stage['status'], stage['reason'], stage['evidence']
        if not isinstance(status, str) or status not in counts:
            raise ValueError(f'{name}: status must be pass, fail, or unverified')
        if not isinstance(reason, str) or not reason.strip():
            raise ValueError(f'{name}: reason is required')
        if not isinstance(evidence, list) or not all(
                isinstance(item, str) and item.strip() for item in evidence):
            raise ValueError(f'{name}: evidence must be a list of nonempty paths')
        if status == 'pass':
            if not all(value.strip() for value in metadata.values()):
                raise ValueError(f'{name}: pass requires all metadata')
            if not evidence:
                raise ValueError(f'{name}: pass requires evidence')
            for item in evidence:
                artifact = path.parent / item
                if not artifact.is_file() or artifact.stat().st_size == 0:
                    raise ValueError(f'{name}: evidence is missing, empty, or not a file: {item}')
        counts[status] += 1
    return metadata, counts


def check_records(files):
    seen = set()
    comparison = {key: set() for key in ('rite_commit', 'surface', 'execution_mode')}
    totals = dict.fromkeys(('pass', 'fail', 'unverified'), 0)
    invalid = False
    for filename in files:
        try:
            metadata, counts = validate_record(Path(filename))
            host = metadata['host']
            if host in seen:
                raise ValueError(f'duplicate host: {host}')
            seen.add(host)
            for key in comparison:
                value = metadata[key]
                if value:
                    comparison[key].add(value.lower() if key == 'rite_commit' else value)
            for status, count in counts.items():
                totals[status] += count
            print(f'{host}: pass={counts["pass"]} fail={counts["fail"]} '
                  f'unverified={counts["unverified"]}')
        except (OSError, ValueError) as error:
            print(f'ERROR: {filename}: {error}', file=sys.stderr)
            invalid = True
    for key, values in comparison.items():
        if len(values) > 1:
            print(f'ERROR: mixed {key}; compare each revision/surface/execution mode separately',
                  file=sys.stderr)
            invalid = True
    missing = sorted(set(HOSTS) - seen)
    if missing:
        print(f'Unverified hosts: {", ".join(missing)}')
    print(f'Recorded stages: pass={totals["pass"]} fail={totals["fail"]} '
          f'unverified={totals["unverified"]}; missing hosts={len(missing)}')
    print('Audit only: evidence contents and actual host execution require recorder review.')
    if invalid or totals['fail']:
        return 1
    return 2 if missing or totals['unverified'] else 0


def main():
    parser = argparse.ArgumentParser(description=__doc__, epilog=(
        'check exit codes: 0 = all three hosts pass all stages; '
        '1 = invalid/failed; 2 = unverified/missing host. Evidence paths are '
        'absolute or relative to the record JSON. This is an audit aid for '
        'the recorder, not automatic model E2E execution.'))
    commands = parser.add_subparsers(dest='command', required=True)
    init = commands.add_parser('init', help='exclusively create an unverified JSON record')
    init.add_argument('host', choices=HOSTS)
    init.add_argument('output')
    check = commands.add_parser('check', help='read-only validation and aggregation')
    check.add_argument('files', nargs='+')
    args = parser.parse_args()
    try:
        return init_record(args.host, args.output) if args.command == 'init' else check_records(args.files)
    except (OSError, ValueError) as error:
        print(f'ERROR: {error}', file=sys.stderr)
        return 1


if __name__ == '__main__':
    sys.exit(main())
