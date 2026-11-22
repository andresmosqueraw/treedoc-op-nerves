#!/usr/bin/env bash
# 6-node interop on one machine: 3 nodes of the op-based groups' code (UNCHANGED,
# copied to a temp dir and compiled there) + 3 of ours, then scripts/interop.exs.
#   TREEDOC_DIR=<path to fepecas/treedoc checkout> scripts/interop.sh
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
: "${TREEDOC_DIR:?set TREEDOC_DIR to their checkout}"
WORK="$(mktemp -d)"
# every node is started with `exec` and its own log: its PID is the BEAM, it
# does not hold this script's stdout, and it is killed on exit (even on failure)
PIDS=()
cleanup() { [ ${#PIDS[@]} -gt 0 ] && kill "${PIDS[@]}" 2>/dev/null; wait 2>/dev/null; rm -rf "$WORK"; }
trap cleanup EXIT
COOKIE=cpd2026; ID=$$
epmd -daemon

echo "== building their code (copy, unchanged) in $WORK/theirs"
rsync -a --exclude _build --exclude data --exclude tmp --exclude .git "$TREEDOC_DIR/" "$WORK/theirs/"
mkdir -p "$WORK/theirs/data"   # their replica does not create data_dir (their DESIGN.md §4.5)
(cd "$WORK/theirs" && MIX_ENV=dev mix compile >/dev/null)
echo "== building ours"
(cd "$ROOT" && source env.sh && mix compile >/dev/null)

THEIRS=""; OURS=""
for k in 1 2 3; do
  n="their$k-$ID@127.0.0.1"
  (cd "$WORK/theirs" && DISCOVERY=off exec elixir --name "$n" --cookie $COOKIE -S mix run --no-compile --no-halt) \
    </dev/null >"$WORK/their$k.log" 2>&1 &
  PIDS+=($!)
  THEIRS="$THEIRS${THEIRS:+,}$n"
  m="our$k-$ID@127.0.0.1"
  (cd "$ROOT" && source env.sh && OPDOC_IP=127.0.0.1 OPDOC_MDNS=off OPDOC_MULTICAST=off OPDOC_DATA_DIR="$WORK/our$k" \
     exec elixir --name "$m" --cookie $COOKIE -S mix run --no-compile --no-halt) </dev/null >"$WORK/our$k.log" 2>&1 &
  PIDS+=($!)
  OURS="$OURS${OURS:+,}$m"
done

echo "== waiting for the 6 nodes"
for n in ${THEIRS//,/ } ${OURS//,/ }; do
  for _ in $(seq 1 100); do epmd -names | grep -q " ${n%@*} " && break; sleep 0.2; done
done
sleep 3
cd "$ROOT"
elixir --name "ctl-$ID@127.0.0.1" --cookie $COOKIE --hidden scripts/interop.exs "$THEIRS" "$OURS" || { echo "--- logs"; tail -n 15 "$WORK"/*.log; exit 1; }
