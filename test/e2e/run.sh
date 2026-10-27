#!/usr/bin/env bash
# Runs each tape in test/e2e against a fresh nlockd on a private socket. A tape
# fails when one of its `Wait` commands times out. Requires vhs and tmux.
#
#   test/e2e/run.sh                 run every tape
#   test/e2e/run.sh queue rate      run only the tapes whose names match
#
# Run from anywhere; set SKIP_BUILD=1 to use the binaries already in zig-out.

set -euo pipefail

cd "$(dirname "$0")/../.."

for tool in vhs tmux; do
  command -v "$tool" >/dev/null || { echo "e2e: $tool is not installed" >&2; exit 1; }
done

[ -n "${SKIP_BUILD:-}" ] || zig build

export PATH="$PWD/zig-out/bin:$PATH"
# Run from inside tmux, the tapes' tmux would refuse to start a nested session.
unset TMUX

tapes=()
for tape in test/e2e/*.tape; do
  name="$(basename "$tape" .tape)"
  [ "$name" = setup ] && continue
  if [ $# -gt 0 ]; then
    match=
    for filter in "$@"; do [[ "$name" == *"$filter"* ]] && match=1; done
    [ -n "$match" ] || continue
  fi
  tapes+=("$tape")
done

daemon=
cleanup() {
  [ -n "${E2E_TMUX:-}" ] && tmux -S "$E2E_TMUX" kill-server 2>/dev/null || true
  [ -n "$daemon" ] && kill "$daemon" 2>/dev/null && wait "$daemon" 2>/dev/null || true
  [ -n "${E2E_DIR:-}" ] && rm -rf "$E2E_DIR"
  daemon=
}
trap cleanup EXIT

failed=()
for tape in "${tapes[@]}"; do
  name="$(basename "$tape" .tape)"

  # Under /tmp, as unix socket paths are limited to about 104 bytes.
  E2E_DIR="$(mktemp -d /tmp/nlock-e2e.XXXXXX)"
  export E2E_DIR E2E_TMUX="$E2E_DIR/tmux.sock" NLOCK_SOCKET="$E2E_DIR/nlock.sock"

  nlockd 2>"$E2E_DIR/nlockd.log" &
  daemon=$!
  for _ in $(seq 100); do [ -S "$NLOCK_SOCKET" ] && break; sleep 0.05; done

  printf '%-20s ' "$name"
  if vhs "$tape" >"$E2E_DIR/vhs.log" 2>&1; then
    echo ok
  else
    echo FAIL
    sed 's/[[:space:]]*$//' "$E2E_DIR/vhs.log" | grep -v '^$' | sed 's/^/    /'
    failed+=("$name")
  fi
  cleanup
done

if [ ${#failed[@]} -gt 0 ]; then
  echo "${#failed[@]} of ${#tapes[@]} e2e tests failed: ${failed[*]}"
  exit 1
fi
echo "all ${#tapes[@]} e2e tests passed"
