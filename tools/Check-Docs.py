#!/usr/bin/env python3
"""Offline checks for maintained Markdown local links and heading anchors.

Scope: root Markdown and docs/**/*.md; inline links only, excluding fenced code.
External URLs are not fetched. Reference-style links and embedded HTML are outside
this check; documentation review must cover those separately.
"""
import argparse
import json
from pathlib import Path
import re
from urllib.parse import unquote, urlsplit
import unicodedata


def prose(text):
    fence = None
    for number, line in enumerate(text.splitlines(), 1):
        marker = re.match(r'^\s*(`{3,}|~{3,})', line)
        if marker:
            kind = marker[1][0]
            if fence is None:
                fence = (kind, len(marker[1]))
            elif fence[0] == kind and len(marker[1]) >= fence[1]:
                fence = None
            continue
        if fence is None:
            yield number, line


def anchors(text):
    counts, result = {}, set()
    for _, line in prose(text):
        heading = re.match(r'^#{1,6}\s+(.+?)\s*#*$', line)
        if not heading:
            continue
        title = re.sub(r'\[([^]]+)\]\([^)]+\)', r'\1', heading[1]).lower()
        slug = ''.join(c for c in title if c in ' -_' or
                       unicodedata.category(c)[0] in 'LN').replace(' ', '-')
        n = counts.get(slug, 0)
        result.add(slug if not n else f'{slug}-{n}')
        counts[slug] = n + 1
    return result


def check(root, current_only=False):
    root = root.resolve()
    docs = set(root.glob('*.md'))
    if current_only:
        docs |= set((root / 'docs/current').glob('*.md'))
        if (root / 'docs/README.md').exists():
            docs.add(root / 'docs/README.md')
    else:
        docs |= set((root / 'docs').rglob('*.md'))
    docs = sorted(docs)
    errors, links = [], 0
    if not docs:
        return dict(documents=0, local_links=0, errors=['No maintained Markdown found.'])
    for source in docs:
        for number, line in prose(source.read_text(encoding='utf-8-sig')):
            for match in re.finditer(r'!?\[[^]]*\]\((<[^>]+>|[^\s)]+)\)', line):
                target = match[1].strip('<>')
                url = urlsplit(target)
                if url.scheme or url.netloc:
                    continue
                links += 1
                dest = (source.parent / unquote(url.path)).resolve() if url.path else source
                issue = None
                if not dest.is_relative_to(root):
                    issue = 'link leaves repository'
                elif not dest.exists():
                    issue = 'missing local target'
                elif url.fragment and dest.suffix.lower() == '.md' and unquote(url.fragment) not in anchors(dest.read_text(encoding='utf-8-sig')):
                    issue = 'missing Markdown anchor'
                if issue:
                    errors.append(f'{source.relative_to(root).as_posix()}:{number}: {issue}: {target}')
    return dict(documents=len(docs), local_links=links, errors=errors)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--root', type=Path, default=Path(__file__).resolve().parents[1])
    parser.add_argument('--current-only', action='store_true', help='Check root Markdown, docs index and current guides; exclude historical records.')
    args = parser.parse_args()
    result = check(args.root, args.current_only)
    print(json.dumps(result, indent=2))
    return int(bool(result['errors']))


if __name__ == '__main__':
    raise SystemExit(main())
