#!/usr/bin/env bash
# The save step's failure paths must be LOUD (CIRISCache#3). Extracts the
# `push` step's script from save/action.yml verbatim, runs it under the
# runner's shell (`bash -e -o pipefail`) with a stub `oras`, and asserts the
# exit code, the annotation, and the `published` / `reason` outputs for: a
# good save through the prune, each failing stage (login, prune, push, a
# push timeout is the same path), strict mode, nothing to cache, and a retag
# failure after the blob is up.
set -euo pipefail

ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
WORK=$(mktemp -d)
trap 'chmod -R u+rwx "$WORK" 2>/dev/null; rm -rf "$WORK"' EXIT
FAIL=0
fail() { echo "FAIL: $*"; FAIL=1; }

# The run block of `- id: push`: the lines after `run: |` indented past it.
awk '
  /^    - id: push$/ { inpush = 1; next }
  inpush && /^    - / { exit }
  inpush && /^      run: \|$/ { inrun = 1; next }
  inrun { if ($0 == "") { print ""; next } if (substr($0, 1, 8) != "        ") exit; print substr($0, 9) }
' "$ROOT/save/action.yml" > "$WORK/step.sh"
[ -s "$WORK/step.sh" ] || { echo "FAIL: could not extract the push step"; exit 1; }
# shellcheck disable=SC2016  # a literal ${{, not an expansion
grep -q '\${{' "$WORK/step.sh" && { echo "FAIL: push step splices \${{ }} into the script"; exit 1; }

# Stub oras: logs each call; ORAS_FAIL=login|push|tag makes that verb exit 1.
mkdir -p "$WORK/bin"
cat > "$WORK/bin/oras" <<'EOF'
#!/usr/bin/env bash
echo "oras $*" >> "$ORAS_LOG"
[ "$1" = login ] && cat > /dev/null
[ "${ORAS_FAIL:-}" = "$1" ] && { echo "stub oras: $1 failed" >&2; exit 1; }
exit 0
EOF
chmod +x "$WORK/bin/oras"

# run_step NAME [VAR=VALUE ...] — fresh workspace with a target/ over a 1 MB
# budget (400 x 4 KiB, oldest first), then the step. Sets RC, OUT, OUTPUTS.
run_step() {
  local name="$1"; shift
  local ws="$WORK/$name"
  mkdir -p "$ws/target/deps" "$ws/tmp"
  local i
  for i in $(seq 1 400); do
    head -c 4096 /dev/zero > "$ws/target/deps/f$i"
    touch -d "@$(( 1700000000 + i ))" "$ws/target/deps/f$i"
  done
  : > "$ws/gh_output"; : > "$ws/oras.log"
  RC=0
  OUT=$(cd "$ws" && env PATH="$WORK/bin:$PATH" HOME="$ws" \
      GITHUB_WORKSPACE="$ws" GITHUB_OUTPUT="$ws/gh_output" RUNNER_TEMP="$ws/tmp" \
      GITHUB_ACTION_PATH="$ROOT/save" RUNNER_OS=Linux ORAS_LOG="$ws/oras.log" \
      CIRISCACHE_TOKEN=tok CC_REF="ghcr.io/x/y:k1" CC_ACTOR=bot CC_PATHS="target" \
      CC_ALIAS_KEYS="" CC_MAX_SIZE_MB="1" CC_STRICT="false" "$@" \
      bash -e -o pipefail "$WORK/step.sh" 2>&1) || RC=$?
  OUTPUTS=$(cat "$ws/gh_output")
  echo "--- $name: exit $RC"
  while IFS= read -r line; do echo "    $line"; done <<<"$OUT"
}
# The last value written for KEY (GITHUB_OUTPUT is last-wins).
output() { awk -F= -v k="$1" '$1 == k { v = substr($0, length(k) + 2) } END { print v }' <<<"$OUTPUTS"; }
expect() {  # expect NAME RC PUBLISHED REASON-SUBSTRING ANNOTATION-REGEX
  [ "$RC" -eq "$2" ] || fail "$1: exit $RC, want $2"
  [ "$(output published)" = "$3" ] || fail "$1: published='$(output published)', want '$3'"
  case "$(output reason)" in *"$4"*) ;; *) fail "$1: reason='$(output reason)', want *$4*";; esac
  if [ -n "$5" ]; then grep -Eq "$5" <<<"$OUT" || fail "$1: no annotation matching /$5/"; fi
}

# A good save through the over-budget prune, with SIGPIPE ignored as on the
# runner: pruned, pushed, published.
(trap '' PIPE; run_step ok_ignored_sigpipe; declare -p RC OUT OUTPUTS > "$WORK/ok.env")
# shellcheck disable=SC1091
. "$WORK/ok.env"
expect ok_ignored_sigpipe 0 true "" ""
grep -q 'LRU prune' <<<"$OUT" || fail "ok_ignored_sigpipe: prune did not run"
grep -q 'oras push ghcr.io/x/y:k1' "$WORK/ok_ignored_sigpipe/oras.log" || fail "ok_ignored_sigpipe: no push"
[ "$(du -sk "$WORK/ok_ignored_sigpipe/target" | cut -f1)" -le 1024 ] || fail "ok_ignored_sigpipe: target/ over budget"
grep -q '::' <<<"$OUT" && fail "ok_ignored_sigpipe: unexpected annotation"

run_step login_fails ORAS_FAIL=login
expect login_fails 0 false "oras login failed (exit 1)" '^::warning::CIRISCache: save NOT published for ghcr.io/x/y:k1'

run_step push_fails ORAS_FAIL=push
expect push_fails 0 false "oras push failed (exit 1)" '^::warning::CIRISCache: save NOT published'

run_step push_fails_strict ORAS_FAIL=push CC_STRICT=true
expect push_fails_strict 1 false "oras push failed (exit 1)" '^::error::CIRISCache: save NOT published'

# Prune failure: an unreadable directory makes du/find fail.
mkdir -p "$WORK/prune_fails/target/locked"; chmod 000 "$WORK/prune_fails/target/locked"
run_step prune_fails
expect prune_fails 0 false "prune failed" '^::warning::CIRISCache: save NOT published'
grep -q 'oras push' "$WORK/prune_fails/oras.log" && fail "prune_fails: pushed after a failed prune"

run_step nothing_to_cache CC_PATHS="no-such-dir"
expect nothing_to_cache 0 false "nothing to cache" '^::warning::CIRISCache: nothing to cache'

# A retag failure after the push: still published, warning only.
run_step tag_fails ORAS_FAIL=tag CC_ALIAS_KEYS="k1-alias"
expect tag_fails 0 true "" '^::warning::CIRISCache: alias retag failed'

# A non-conditional failure AFTER the push (here the alias-key normalization,
# via a `tr` that fails): the trap must not overwrite published=true.
mkdir -p "$WORK/badtr"; printf '#!/bin/sh\nexit 1\n' > "$WORK/badtr/tr"; chmod +x "$WORK/badtr/tr"
run_step post_publish_fails CC_ALIAS_KEYS="k1-alias" PATH="$WORK/badtr:$WORK/bin:$PATH"
expect post_publish_fails 0 true "" '^::warning::CIRISCache: alias retag failed \(exit 1\) after ghcr.io/x/y:k1 was published'

if [ "$FAIL" -ne 0 ]; then echo "save_step_test: FAILED"; exit 1; fi
echo "save_step_test: OK"
