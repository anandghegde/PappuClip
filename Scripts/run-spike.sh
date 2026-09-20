#!/bin/bash
# Runs one SpikeLab spike without its window and prints the log.
#
# Usage: Scripts/run-spike.sh <spike-id> [--state "<permission state>"] [--enable a,b] [--out <dir>]
#        Scripts/run-spike.sh --list
#
# The app is started with `open`, not by running the binary. A binary started from a shell has the
# terminal as its "responsible process", and macOS then answers every permission question about the
# terminal instead of SpikeLab, which would make the permission results meaningless.

set -euo pipefail

ROOT=$(cd "$(dirname "$0")/.." && pwd)
APP="$ROOT/build/DerivedData/Build/Products/Debug/SpikeLab.app"

if [[ ! -d "$APP" ]]; then
  echo "SpikeLab is not built. Run Scripts/build.sh first." >&2
  exit 1
fi

if [[ "${1:-}" == "--list" || $# -eq 0 ]]; then
  "$APP/Contents/MacOS/SpikeLab" --list
  exit 0
fi

SPIKE="$1"; shift
LOG=$(mktemp -t spikelab)
trap 'rm -f "$LOG"' EXIT

# -n: a new instance even if the window is open. -W: wait for it to exit. -g: stay in the background,
# so launching a spike does not take focus from the app being tested.
open -n -g -W --stdout "$LOG" --stderr "$LOG" "$APP" --args --run "$SPIKE" "$@" || true
cat "$LOG"
