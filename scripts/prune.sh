# shellcheck shell=bash
# CIRISCache LRU prune — sourced by save/action.yml and tests/prune_test.sh.
#
# cc_prune_lru DIR BUDGET_KB
#   Delete the OLDEST-mtime files under DIR until its `du -sk` total is within
#   BUDGET_KB (see the save action's `max-size-mb` input). Needs GNU find
#   (`-printf %T@`); the caller checks for it. Returns non-zero on failure.
#
# Why the sorted list goes through a FILE and not a pipe (CIRISCache#3): the
# loop `break`s as soon as the budget is met, long before the list is
# exhausted on a large target/. In `find | sort | while …; break` the reader
# then exits with sort still writing, so sort takes SIGPIPE — or, on the
# Actions runner, where SIGPIPE is ignored, EPIPE: "sort: write failed:
# 'standard output': Broken pipe", exit 2. Under `set -o pipefail` that fails
# the pipeline, `set -e` kills the step before tar/push, and a caller's
# `continue-on-error: true` hid it: nothing was published for every save that
# took this path. Reading from a file has no writer to break.
cc_prune_lru() {
  local dir="$1" budget_kb="$2" used_kb before_kb after_kb lru _mt kb path
  used_kb=$(du -sk "$dir" | cut -f1)
  if [ "$used_kb" -le "$budget_kb" ]; then
    echo "CIRISCache: target/ ${used_kb}KB within ${budget_kb}KB budget — no prune"
    return 0
  fi
  before_kb=$used_kb
  echo "CIRISCache: target/ ${used_kb}KB over ${budget_kb}KB budget — LRU prune"
  lru=$(mktemp "${TMPDIR:-/tmp}/ciriscache-lru.XXXXXX")
  # Oldest-mtime first; %T@ (GNU find) + a size column so we can stop exactly
  # at the line. Both stages run to completion before the loop reads a line.
  find "$dir" -type f -printf '%T@ %k %p\n' 2>/dev/null | sort -n > "$lru" \
    || { rm -f -- "$lru"; echo "CIRISCache: LRU listing of $dir failed"; return 1; }
  while read -r _mt kb path; do
    [ "$used_kb" -le "$budget_kb" ] && break
    rm -f -- "$path" 2>/dev/null || continue
    used_kb=$(( used_kb - kb ))
  done < "$lru"
  rm -f -- "$lru"
  # The running total is an estimate (%k vs du's directory blocks); report
  # the honest re-measure.
  after_kb=$(du -sk "$dir" | cut -f1)
  echo "CIRISCache: pruned target/ ${before_kb}KB→${after_kb}KB (budget ${budget_kb}KB)"
}
