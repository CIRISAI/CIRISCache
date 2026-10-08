#!/usr/bin/env bash
# Regression test for CIRISCache#3: the LRU prune must survive an early
# `break` under the save step's shell options (`bash -e -o pipefail`).
#
# Builds a target/ over budget with controlled mtimes, runs cc_prune_lru, and
# asserts: (a) exit 0, (b) the kept set is exactly the newest-mtime files and
# the total is within budget, (c) the loop broke EARLY with more than a pipe
# buffer of list still unread — the condition that killed `sort | while`.
# Runs twice: SIGPIPE default (sort dies by signal, 141) and SIGPIPE ignored
# (sort gets EPIPE, exit 2 — what the Actions runner showed).
#
# PRUNE_SH overrides the script under test (used to mutation-check this test
# against the old pipe-into-while form). Needs bash + coreutils + GNU find.
set -euo pipefail

ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
PRUNE_SH="${PRUNE_SH:-$ROOT/scripts/prune.sh}"
WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT

N=3000          # files of 4 KiB each: ~12 MB
BUDGET_KB=8192  # ~1/3 of the files must go; the rest stays unread
BASE=1700000000
FAIL=0

fail() { echo "FAIL: $*"; FAIL=1; }

# Built once; each case gets a `cp -a` copy (mtimes preserved).
make_template() {
  local t="$WORK/template" i f
  mkdir -p "$t/deps"
  for i in $(seq 1 "$N"); do
    # Long names, like real rlibs, so the unread list is well past 64 KiB.
    f="$t/deps/libsome_crate_with_a_reasonably_long_name_$(printf %05d "$i")-0123456789abcdef.rlib"
    head -c 4096 /dev/zero > "$f"
    touch -d "@$(( BASE + i ))" "$f"   # file i is the i-th oldest
  done
}
make_template

make_fixture() { rm -rf "$1"; cp -a "$WORK/template" "$1"; }

run_case() {
  local label="$1" sigpipe="$2" t="$WORK/target" out rc=0
  make_fixture "$t"
  local before_kb; before_kb=$(du -sk "$t" | cut -f1)
  [ "$before_kb" -gt "$BUDGET_KB" ] || { fail "$label: fixture not over budget"; return; }

  # Exactly the save step's options; `trap '' PIPE` reproduces the runner.
  out=$(bash -e -o pipefail -c "
    $sigpipe
    . '$PRUNE_SH'
    cc_prune_lru '$t' $BUDGET_KB
    echo REACHED-TAR
  " 2>&1) || rc=$?
  echo "--- $label: exit $rc"
  while IFS= read -r line; do echo "    $line"; done <<<"$out"

  # (a) the step survives and reaches tar.
  [ "$rc" -eq 0 ] || fail "$label: prune exited $rc (want 0)"
  grep -q REACHED-TAR <<<"$out" || fail "$label: step died before tar"
  grep -q 'Broken pipe' <<<"$out" && fail "$label: sort hit a broken pipe"

  # (b) within budget, and the survivors are exactly the newest files: a
  # contiguous run of indices ending at N.
  local after_kb kept oldest_kept
  after_kb=$(du -sk "$t" | cut -f1)
  [ "$after_kb" -le "$BUDGET_KB" ] || fail "$label: ${after_kb}KB still over ${BUDGET_KB}KB"
  kept=$(find "$t" -type f | wc -l)
  # awk reads to EOF: `sort | head -1` would SIGPIPE under pipefail — the
  # very bug this file tests.
  oldest_kept=$(find "$t" -type f -printf '%f\n' \
    | awk -F_ '{ n = substr($NF, 1, 5) + 0; if (m == "" || n < m) m = n } END { print m }')
  [ $(( N - oldest_kept + 1 )) -eq "$kept" ] \
    || fail "$label: kept $kept files but oldest kept is #$oldest_kept (not the newest $kept)"
  # Minimal deletion: putting back the newest deleted file (4 KiB) would
  # exceed the budget, so the loop did not delete past the line.
  [ $(( after_kb + 4 )) -gt "$BUDGET_KB" ] \
    || fail "$label: over-pruned (${after_kb}KB + 4KB still within ${BUDGET_KB}KB)"

  # (c) the early-break path ran: files were left unread, and their list
  # lines exceed a 64 KiB pipe buffer, so a piped sort would still be
  # writing when the reader quit.
  [ "$kept" -gt 0 ] && [ "$kept" -lt "$N" ] || fail "$label: no early break (kept $kept of $N)"
  local unread_bytes
  unread_bytes=$(find "$t" -type f -printf '%T@ %k %p\n' | wc -c)
  [ "$unread_bytes" -gt 65536 ] \
    || fail "$label: unread list ${unread_bytes}B fits a pipe buffer; fixture too small to catch SIGPIPE"
  echo "    kept $kept/$N (oldest kept #$oldest_kept), ${before_kb}KB→${after_kb}KB, unread list ${unread_bytes}B"
}

run_case "SIGPIPE default" ""
run_case "SIGPIPE ignored (runner)" "trap '' PIPE"

# Within budget: no prune, no deletion.
t="$WORK/small"; rm -rf "$t"; mkdir -p "$t"; head -c 4096 /dev/zero > "$t/a"
out=$(bash -e -o pipefail -c ". '$PRUNE_SH'; cc_prune_lru '$t' $BUDGET_KB" 2>&1) \
  || fail "within-budget: exited non-zero"
grep -q 'no prune' <<<"$out" && [ -f "$t/a" ] || fail "within-budget: pruned or wrong message: $out"

# The action must actually call this function (a test of a function the
# action no longer uses would pass forever). Comments stripped; captured to
# a variable because `grep | grep -q` can SIGPIPE the first grep.
code=$(grep -v '^[[:space:]]*#' "$ROOT/save/action.yml")
grep -q 'scripts/prune\.sh' <<<"$code" || fail "save/action.yml does not source scripts/prune.sh"
grep -q 'cc_prune_lru ' <<<"$code" || fail "save/action.yml does not call cc_prune_lru"

if [ "$FAIL" -ne 0 ]; then echo "prune_test: FAILED"; exit 1; fi
echo "prune_test: OK"
