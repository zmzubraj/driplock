#!/usr/bin/env bash
# Publishes Driplock's three packages to the Onyx testnet, in order, waiting
# for each one to be enabled before sending the next.
#
# Usage: [REALM=driplock/v2] scripts/deploy-onyx.sh <your g1 address> <gnokey key name>
#
# Run scripts/prepare-deploy.sh <address> first. gnokey asks for the key's
# password once per package; this script never reads or stores it.
set -euo pipefail

ADDR="${1:-}"
KEY="${2:-}"
REALM="${REALM:-driplock}"
if [[ ! "$ADDR" =~ ^g1[02-9ac-hj-np-z]{38}$ || -z "$KEY" ]]; then
  echo "usage: $0 <g1 address> <gnokey key name>" >&2
  exit 1
fi

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
BUILD="$ROOT/build/$ADDR"
REMOTE="https://rpc.onyx.testnets.gno.land:443"
WEB="https://onyx.testnets.gno.land"
[[ -d "$BUILD" ]] || { echo "No build at $BUILD. Run scripts/prepare-deploy.sh $ADDR first." >&2; exit 1; }

wait_live() {
  local path="$1" code
  printf "Waiting for %s to go live" "$path"
  for _ in $(seq 1 60); do
    code=$(curl -s -o /dev/null -w '%{http_code}' "$WEB/$path" || true)
    if [[ "$code" == "200" ]]; then echo " ... live"; return 0; fi
    printf "."; sleep 10
  done
  echo; echo "Still not live after 10 minutes: $path. Stop here and tell Claude." >&2
  exit 1
}

publish() {
  local dir="$1" path="$2" deposit="$3" gas="${4:-100000000}"
  if [[ "$(curl -s -o /dev/null -w '%{http_code}' "$WEB/$path")" == "200" ]]; then
    echo "== $path is already live, skipping"
    return 0
  fi
  echo
  echo "== Publishing $path (gnokey will ask for your password)"
  gnokey maketx addpkg -pkgdir "$BUILD/$dir" -pkgpath "gno.land/$path" \
    -gas-fee 2000000ugnot -gas-wanted "$gas" -max-deposit "$deposit" \
    -broadcast -chainid onyx-1 -remote "$REMOTE" "$KEY"
  wait_live "$path"
}

publish p/schedule "p/$ADDR/driplock/schedule" 20000000ugnot
publish r/dripdemo "r/$ADDR/dripdemo" 20000000ugnot
publish r/driplock "r/$ADDR/$REALM" 50000000ugnot 150000000 # needed about 120M at v2

echo
echo "All three packages are live:"
echo "  $WEB/r/$ADDR/$REALM"
echo "  $WEB/r/$ADDR/dripdemo"
echo "  $WEB/p/$ADDR/driplock/schedule"
