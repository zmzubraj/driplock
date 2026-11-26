#!/usr/bin/env bash
# Builds a deployable copy of Driplock under your own address namespace and
# prints the gnokey commands to publish it on the Onyx testnet (onyx-1).
#
# Usage: scripts/prepare-deploy.sh <your g1 address> [--with-tests]
#
# It never signs or sends anything. You run the printed commands yourself;
# gnokey asks for your key password.
set -euo pipefail

ADDR="${1:-}"
WITH_TESTS="${2:-}"
if [[ ! "$ADDR" =~ ^g1[02-9ac-hj-np-z]{38}$ ]]; then
  echo "usage: $0 <g1 address> [--with-tests]  (got: '${ADDR}')" >&2
  exit 1
fi

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
OUT="$ROOT/build/$ADDR"
rm -rf "$OUT"
mkdir -p "$OUT"
cp "$ROOT/gnowork.toml" "$OUT/"

for pkg in p/schedule r/dripdemo r/driplock; do
  mkdir -p "$OUT/$pkg"
  for f in "$ROOT/$pkg"/*.gno "$ROOT/$pkg/gnomod.toml"; do
    [[ -e "$f" ]] || continue
    if [[ "$f" == *_test.gno && "$WITH_TESTS" != "--with-tests" ]]; then continue; fi
    cp "$f" "$OUT/$pkg/"
  done
done

# Replace the placeholder namespace in module paths, imports and test constants.
find "$OUT" -type f \( -name '*.gno' -o -name 'gnomod.toml' \) -print0 |
  xargs -0 sed -i.bak -e "s#/p/zdev/#/p/$ADDR/#g" -e "s#/r/zdev/#/r/$ADDR/#g"
find "$OUT" -name '*.bak' -delete
if grep -rq "zdev" "$OUT"; then echo "placeholder namespace left in build:" >&2; grep -rn zdev "$OUT" >&2; exit 1; fi

echo "== Checking the build"
(cd "$OUT" && gno lint ./... && { [[ "$WITH_TESTS" == "--with-tests" ]] && gno test ./... || true; })

REMOTE="https://rpc.onyx.testnets.gno.land:443"
cat <<CMDS

Build ready: $OUT

Publish in this order. After each one, wait until its page opens on
https://onyx.testnets.gno.land/<path> (the gpao oracle enables new packages
after it type-checks them; a package that imports one not yet enabled fails).

1) gnokey maketx addpkg -pkgdir "$OUT/p/schedule" -pkgpath gno.land/p/$ADDR/driplock/schedule \\
     -gas-fee 1000000ugnot -gas-wanted 100000000 -max-deposit 20000000ugnot \\
     -broadcast -chainid onyx-1 -remote $REMOTE <your-key-name>

2) gnokey maketx addpkg -pkgdir "$OUT/r/dripdemo" -pkgpath gno.land/r/$ADDR/dripdemo \\
     -gas-fee 1000000ugnot -gas-wanted 100000000 -max-deposit 20000000ugnot \\
     -broadcast -chainid onyx-1 -remote $REMOTE <your-key-name>

3) gnokey maketx addpkg -pkgdir "$OUT/r/driplock" -pkgpath gno.land/r/$ADDR/driplock \\
     -gas-fee 1000000ugnot -gas-wanted 100000000 -max-deposit 50000000ugnot \\
     -broadcast -chainid onyx-1 -remote $REMOTE <your-key-name>

Check a package is live:
  curl -s -o /dev/null -w '%{http_code}\n' https://onyx.testnets.gno.land/r/$ADDR/driplock
CMDS
