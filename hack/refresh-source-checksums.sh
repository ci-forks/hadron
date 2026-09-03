#!/bin/sh
# Refresh the sha256 pin of named packages in sources.yaml.
#
# A version bump is two edits, not one: `version` and `sha256` describe the
# same tarball and are checked against each other by populate-sources (and by
# the upstream-mode build in hack/render.sh). Bumping only `version` produces
# a sources.yaml that fails every build, so the autobumper runs this straight
# after `updatecli apply`.
#
# Packages must be named, either on the command line or via --changed, which
# selects every package whose `version` differs from HEAD. Refreshing the
# whole file unconditionally would let an upstream retag of a package nobody
# bumped rewrite its pin silently, which is the one thing the sha256 is there
# to prevent. Naming the packages keeps a refresh scoped to the bump being
# made.
#
# Usage:
#   hack/refresh-source-checksums.sh --changed
#   hack/refresh-source-checksums.sh busybox lvm2

set -eu

repo_root=$(cd "$(dirname "$0")/.." && pwd)
cd "$repo_root"

if [ "$#" -eq 0 ]; then
    echo "usage: $0 --changed | <package>..." >&2
    exit 2
fi

if [ ! -f sources.yaml ]; then
    echo "error: sources.yaml not found in $repo_root" >&2
    exit 1
fi

if [ "$1" = "--changed" ] && [ "$#" -ne 1 ]; then
    echo "error: --changed takes no package arguments" >&2
    exit 2
fi

HADRON_REFRESH_PACKAGES="$*"
export HADRON_REFRESH_PACKAGES

python3 - <<'PY'
import hashlib
import os
import re
import shutil
import subprocess
import sys
import tempfile

try:
    import yaml
except ImportError:
    sys.exit("PyYAML is required to refresh checksums (pip install pyyaml)")

SOURCES = 'sources.yaml'
ATTEMPTS = 3
TIMEOUT = 60


def load(text):
    return (yaml.safe_load(text) or {}).get('packages') or {}


text = open(SOURCES).read()
packages = load(text)

argv = os.environ['HADRON_REFRESH_PACKAGES'].split()
if argv == ['--changed']:
    # Compare against the committed file rather than parsing a diff: the
    # question is only "which versions differ", and both sides parse.
    try:
        head = subprocess.run(
            ['git', 'show', f'HEAD:{SOURCES}'],
            check=True, capture_output=True, text=True,
        ).stdout
    except subprocess.CalledProcessError as e:
        sys.exit(f'could not read HEAD:{SOURCES}: {e.stderr.strip()}')
    before = load(head)
    selected = sorted(
        name for name, spec in packages.items()
        if str(spec.get('version')) != str(before.get(name, {}).get('version'))
    )
    if not selected:
        print(f'no version changes in {SOURCES}, nothing to refresh')
        raise SystemExit(0)
    print('refreshing checksums for changed packages: ' + ' '.join(selected))
else:
    selected = argv
    unknown = sorted(set(selected) - set(packages))
    if unknown:
        sys.exit('not in ' + SOURCES + ': ' + ' '.join(unknown))


def sha256_of(urls, into):
    """Download the first URL that serves a non-empty body, return (url, sha256).

    curl rather than urllib: several of the mirrors in sources.yaml answer 403
    to a request without a User-Agent, and curl is already a dependency of
    hack/list-missing-sources.sh. Streaming to a file also keeps the larger
    tarballs (the kernel is ~150MB) off the heap.
    """
    last = None
    for _ in range(ATTEMPTS):
        for url in urls:
            proc = subprocess.run(
                ['curl', '-fsSL', '--max-time', str(TIMEOUT), '-o', into, url],
                capture_output=True, text=True,
            )
            if proc.returncode != 0:
                last = f'{url}: {proc.stderr.strip() or "curl exit " + str(proc.returncode)}'
                continue
            if os.path.getsize(into) == 0:
                last = f'{url}: empty body'
                continue
            digest = hashlib.sha256()
            with open(into, 'rb') as fh:
                for chunk in iter(lambda: fh.read(1 << 20), b''):
                    digest.update(chunk)
            return url, digest.hexdigest()
    raise RuntimeError(last or 'no urls')


def replace_sha256(text, package, new):
    """Rewrite one package's sha256 line and leave the rest of the file alone."""
    block = re.compile(
        r'(^  ' + re.escape(package) + r':\n'
        r'(?:    [^\n]*\n|      [^\n]*\n)*?'
        r'    sha256: )([0-9a-fA-F]+)',
        re.M,
    )
    text, n = block.subn(lambda m: m.group(1) + new, text, count=1)
    if n != 1:
        raise SystemExit(f'could not locate the sha256 line for {package!r}')
    return text


if not shutil.which('curl'):
    sys.exit('curl not found')

changed = []
tmpdir = tempfile.mkdtemp(prefix='hadron-checksums-')
for name in selected:
    spec = packages[name]
    version = str(spec['version'])
    urls = [u.replace('${version}', version) for u in spec['urls']]
    try:
        url, actual = sha256_of(urls, os.path.join(tmpdir, 'tarball'))
    except RuntimeError as e:
        shutil.rmtree(tmpdir, ignore_errors=True)
        sys.exit(f'{name} {version}: no url served the tarball ({e})')
    if actual == spec['sha256']:
        print(f'{name} {version}: sha256 already correct')
        continue
    text = replace_sha256(text, name, actual)
    changed.append(name)
    print(f'{name} {version}: {spec["sha256"]} -> {actual} (from {url})')

shutil.rmtree(tmpdir, ignore_errors=True)

if changed:
    open(SOURCES, 'w').write(text)
    print(f'updated {len(changed)} checksum(s) in {SOURCES}')
else:
    print('no checksums needed updating')
PY
