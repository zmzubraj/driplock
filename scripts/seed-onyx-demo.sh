#!/usr/bin/env bash
# Opens a few demo streams on the Onyx testnet so the live pages show real
# data. Every stream goes to RECIPIENT (by default the sender itself).
#
# Usage: scripts/seed-onyx-demo.sh <your g1 address> <gnokey key name> [recipient] [first step]
#
# Pass a first step (1 to 6) to resume after a failure without repeating
# the steps that already went through.
#
# gnokey asks for the key's password once per transaction (six in total);
# this script never reads or stores it. Testnet only.
set -euo pipefail

ADDR="${1:-}"; KEY="${2:-}"; RECIPIENT="${3:-$ADDR}"; FIRST="${4:-1}"
if [[ ! "$ADDR" =~ ^g1[02-9ac-hj-np-z]{38}$ || -z "$KEY" || ! "$RECIPIENT" =~ ^g1[02-9ac-hj-np-z]{38}$ ]]; then
  echo "usage: $0 <g1 address> <gnokey key name> [recipient g1 address]" >&2
  exit 1
fi

REMOTE="https://rpc.onyx.testnets.gno.land:443"
DL="gno.land/r/$ADDR/driplock"
DEMO="gno.land/r/$ADDR/dripdemo"
TOKEN="$DEMO.DRIP"
DAY=86400; MONTH=$((30 * DAY))
STEP=0; TOTAL=6

call() { # pkg func send args...
  local pkg="$1" fn="$2" send="$3"; shift 3
  local args=(); for a in "$@"; do args+=(-args "$a"); done
  local sendflag=(); [[ -n "$send" ]] && sendflag=(-send "$send")
  STEP=$((STEP + 1))
  if (( STEP < FIRST )); then echo "== [$STEP/$TOTAL] $fn: already done, skipping"; return 0; fi
  echo
  echo "== [$STEP/$TOTAL] $fn on ${pkg##*/} (gnokey will ask for your password)"
  gnokey maketx call -pkgpath "$pkg" -func "$fn" ${args[@]+"${args[@]}"} ${sendflag[@]+"${sendflag[@]}"} \
    -gas-fee 1000000ugnot -gas-wanted 50000000 -max-deposit 5000000ugnot \
    -broadcast -chainid onyx-1 -remote "$REMOTE" "$KEY"
}

REALM=$(gnokey query vm/qeval -data "$DL.Address()" -remote "$REMOTE" | grep -o 'g1[0-9a-z]\{38\}' | head -1)
[[ -n "$REALM" ]] || { echo "Could not read the Driplock realm address." >&2; exit 1; }
echo "Driplock realm address: $REALM"
echo "Recipient for every stream: $RECIPIENT"

# 1. Team grant: 12 GNOT, monthly steps over 12 months, 3-month cliff, cancelable only before the cliff.
call "$DL" CreateCoinStreamFor 12000000ugnot "$RECIPIENT" $((3 * MONTH)) $((12 * MONTH)) "$MONTH" $((3 * MONTH))
# 2. Advisor: 6 GNOT, continuous over 6 months, never cancelable.
call "$DL" CreateCoinStreamFor 6000000ugnot "$RECIPIENT" 0 $((6 * MONTH)) 0 0
# 3. Quick demo: 2 GNOT over 10 minutes, cancelable for the whole 10 minutes.
call "$DL" CreateCoinStreamFor 2000000ugnot "$RECIPIENT" 0 600 0 600
# 4 to 6. DRIP: faucet, approve the realm, then a 90-day monthly stream of 400 DRIP.
call "$DEMO" Faucet ""
call "$DEMO" Approve "" "$REALM" 400000000
call "$DL" CreateGRC20StreamFor "" "$RECIPIENT" "$TOKEN" 400000000 0 $((3 * MONTH)) "$MONTH" 0

echo
echo "Done. Open:"
echo "  https://onyx.testnets.gno.land/r/$ADDR/driplock"
echo "  https://onyx.testnets.gno.land/r/$ADDR/driplock:lock/coin:ugnot"
echo "  https://onyx.testnets.gno.land/r/$ADDR/driplock:statement/$RECIPIENT"
