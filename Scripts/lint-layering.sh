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

# The Accessibility seam is below both of its readers and knows about neither.
forbid PappuAX "Pappu[A-Za-z]+" "must depend on no other module"

# ContextProbe and BrowserMetadata take a ReadPermit and reach AX through PappuAX (architecture §3.1).
forbid PappuAnalysis "PappuSelection" "must not depend on the selection machinery"

# The helper is the sandboxed side. Anything it can import, extension code is one bug away from.
forbid PappuJSHost "PappuSelection|PappuRuntime|PappuExtensions|PappuSurfaces|PappuSettings|PappuRegistry|PappuDiagnostics|AppKit|Cocoa" \
  "must not import an app-side module"

# The Runner is told values and runs them. It must not be able to reach the rules that decide them.
forbid PappuRunnerBridge "Pappu[A-Za-z]+" "must depend on no other module"
forbid PappuRunnerHost "PappuCore|PappuAX|PappuSelection|PappuAnalysis|PappuRuntime|PappuExtensions|PappuSurfaces|PappuSettings|PappuRegistry|PappuDiagnostics|PappuJS[A-Za-z]+" \
  "must not import an app-side module"

# PappuApp is the top of the tree: the one module allowed to hold a surface and the runtime at once,
# and therefore the one nothing else may reach for. A module that imported it would be asking the
# assembly to depend on it and it to depend on the assembly.
for module in PappuCore PappuAX PappuSelection PappuAnalysis PappuExtensions PappuJSBridge PappuJSHost PappuRuntime \
              PappuRunnerBridge PappuRunnerHost PappuSurfaces PappuSettings PappuRegistry PappuDiagnostics; do
  forbid "$module" "PappuApp" "must not import the app assembly"
done

# Neither the bar nor the runtime may reach for the other; the bridge between them is PappuApp's
# (architecture §6.3, §15).
forbid PappuSurfaces "PappuRuntime" "must not depend on the runtime"
forbid PappuRuntime "PappuSurfaces" "must not depend on the surfaces"

# Shipping modules never link the development tooling (it names apps; DIA-4).
for module in PappuCore PappuAX PappuSelection PappuAnalysis PappuExtensions PappuJSBridge PappuJSHost PappuRuntime \
              PappuRunnerBridge PappuRunnerHost PappuSurfaces PappuSettings PappuRegistry PappuDiagnostics PappuApp; do
  forbid "$module" "PappuHarness|PappuDevTools|PappuTestSupport" "must not import development tooling"
done

[[ $FAILED -eq 0 ]] && echo "Layering rules hold."
exit $FAILED
