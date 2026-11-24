#!/usr/bin/env bash
# Interop of EVERY op-based implementation of the course on one machine, each
# one UNCHANGED (copied to a temp dir and compiled there), 2 nodes of each:
#
#   ours      this repo (started WITHOUT --name, as on the Pi: Doc.Dist names it)
#   treedoc   fepecas/treedoc                  (TREEDOC_DIR)
#   nerves    treedoc-nerves, its Crdt.Replica (NERVES_DIR; on the host its app
#             starts nothing, so the replica is started as its Crdt.Boot does)
#   carla     distribution-project-, branch op-based, folder documento/ (CARLA_DIR)
#
# All nodes use a RANDOM private cookie and -connect_all false: nothing can join
# a real class cluster on this network, and the scenarios decide the topology.
#   TREEDOC_DIR=.. NERVES_DIR=.. CARLA_DIR=.. [CARLA_REF=origin/op-based] scripts/interop_all.sh
# (newer treedoc-nerves reads its data dir from config first: `log:` sets the file)
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
: "${TREEDOC_DIR:?}" "${NERVES_DIR:?}" "${CARLA_DIR:?}"
CARLA_REF=${CARLA_REF:-origin/op-based}
WORK="$(mktemp -d)"; ID=$$
COOKIE="interop$RANDOM$RANDOM"
export ERL_AFLAGS="-connect_all false -kernel prevent_overlapping_partitions false"
PIDS=()
cleanup() { [ ${#PIDS[@]} -gt 0 ] && kill "${PIDS[@]}" 2>/dev/null; wait 2>/dev/null; rm -rf "$WORK"; }
trap cleanup EXIT
epmd -daemon

echo "== copying and building the 4 implementations in $WORK"
rsync -a --exclude _build --exclude data --exclude tmp --exclude .git "$TREEDOC_DIR/" "$WORK/treedoc/"
mkdir -p "$WORK/treedoc/data"
rsync -a --exclude _build --exclude data --exclude .git "$NERVES_DIR/" "$WORK/nerves/"
mkdir -p "$WORK/carla" && git -C "$CARLA_DIR" archive "$CARLA_REF" documento | tar -x -C "$WORK/carla"
echo "   carla: $(git -C "$CARLA_DIR" log -1 --format='%h %s' "$CARLA_REF")"
(cd "$WORK/treedoc" && mix compile >/dev/null)
(cd "$WORK/nerves" && mix deps.get >/dev/null && mix compile >/dev/null 2>&1)
(cd "$WORK/carla/documento" && mix deps.get >/dev/null && mix compile >/dev/null 2>&1)
(cd "$ROOT" && source env.sh && mix compile >/dev/null)

start() { # start <log> <dir> <command...>
  local log=$1 dir=$2; shift 2
  (cd "$dir" && exec "$@") </dev/null >"$WORK/$log.log" 2>&1 &
  PIDS+=($!)
}

NERVES_BOOT='{:ok, sup} = DynamicSupervisor.start_link(name: Crdt.DynSup, strategy: :one_for_one); Process.unlink(sup)'
for k in 1 2; do
  start "ours$k" "$ROOT" env OPDOC_IP=127.0.0.1 OPDOC_NAME="ours$k" OPDOC_COOKIE="$COOKIE" OPDOC_MDNS=off \
    OPDOC_MULTICAST=off OPDOC_DATA_DIR="$WORK/d-ours$k" MIX_DEPS_PATH="$HOME/.cache/cpd/opdoc/deps" \
    MIX_BUILD_ROOT="$HOME/.cache/cpd/opdoc/_build" elixir -S mix run --no-compile --no-halt
  start "treedoc$k" "$WORK/treedoc" env DISCOVERY=off \
    elixir --name "treedoc$k-$ID@127.0.0.1" --cookie "$COOKIE" -S mix run --no-compile --no-halt
  start "nerves$k" "$WORK/nerves" elixir --name "nerves$k-$ID@127.0.0.1" --cookie "$COOKIE" -S mix run --no-compile --no-halt \
    -e "$NERVES_BOOT; File.mkdir_p!(\"$WORK/d-nerves$k\"); {:ok, _} = DynamicSupervisor.start_child(Crdt.DynSup, {Crdt.Replica, [data_dir: \"$WORK/d-nerves$k\", log: \"$WORK/d-nerves$k/nerves$k.log\"]})"
  start "carla$k" "$WORK/carla/documento" env CPD_DOC_DATOS="$WORK/d-carla$k" \
    elixir --name "carla$k-$ID@127.0.0.1" --cookie "$COOKIE" -S mix run --no-compile --no-halt
done

echo "== waiting for the 8 nodes"
name_of() { epmd -names | awk "/^name/{print \$2}" | grep -E "^$1(-|$)" | head -1 || true; }
NODES=""
for p in ours1 ours2 "treedoc1-$ID" "treedoc2-$ID" "nerves1-$ID" "nerves2-$ID" "carla1-$ID" "carla2-$ID"; do
  n=""; for _ in $(seq 1 150); do n=$(name_of "$p"); [ -n "$n" ] && break; sleep 0.2; done
  [ -z "$n" ] && { echo "node $p did not start"; tail -n 20 "$WORK"/*.log; exit 1; }
  NODES="$NODES${NODES:+,}$n@127.0.0.1"
done
sleep 4
cd "$ROOT"
set +e
elixir --name "ctl-$ID@127.0.0.1" --cookie "$COOKIE" --hidden scripts/interop_all.exs "$NODES"
rc=$?
echo "--- crashes / errors in the node logs (count, first 60 chars):"
for f in "$WORK"/*.log; do
  c=$(grep -ciE "\[error\]|crash|terminating|\*\* \(" "$f"); [ "$c" -gt 0 ] && echo "  $(basename "$f" .log): $c  $(grep -iE "\[error\]|crash|terminating|\*\* \(" "$f" | head -1 | cut -c1-110)"
done
exit $rc
