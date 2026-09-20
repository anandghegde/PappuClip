#!/bin/bash
# Module rules from architecture §15 that the compiler does not enforce.

set -euo pipefail

SOURCES="$(cd "$(dirname "$0")/.." && pwd)/Packages/PappuKit/Sources"
FAILED=0

forbid() { # <module> <import pattern> <reason>
  local hits
  hits=$(grep -rnE "^\s*(@testable\s+)?import\s+($2)\b" "$SOURCES/$1" || true)
  if [[ -n "$hits" ]]; then
    echo "error: $1 $3" >&2
    echo "$hits" >&2
    FAILED=1
  fi
}

# The CLI and the registry's CI link PappuCore on machines with no window server.
forbid PappuCore "AppKit|Cocoa|SwiftUI" "must not import a UI framework"

# The helper is the sandboxed side. Anything it can import, extension code is one bug away from.
forbid PappuJSHost "PappuSelection|PappuRuntime|PappuExtensions|PappuSurfaces|PappuSettings|PappuRegistry|PappuDiagnostics|AppKit|Cocoa" \
  "must not import an app-side module"

# Shipping modules never link the development tooling (it names apps; DIA-4).
for module in PappuCore PappuSelection PappuAnalysis PappuExtensions PappuJSBridge PappuJSHost PappuRuntime \
              PappuSurfaces PappuSettings PappuRegistry PappuDiagnostics; do
  forbid "$module" "PappuHarness|PappuDevTools|PappuTestSupport" "must not import development tooling"
done

[[ $FAILED -eq 0 ]] && echo "Layering rules hold."
exit $FAILED
