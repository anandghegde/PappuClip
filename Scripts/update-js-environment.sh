#!/bin/bash
# Regenerates the JavaScript that PappuClipJSHost.xpc gives every extension (JS-2, JS-9): the
# environment's globals and the libraries `require()` can load, with their licences.
#
# The versions are pinned in Resources/JavaScript/package.json and package-lock.json. The output is
# checked in under Packages/PappuKit/Sources/PappuJSHost/JavaScript, so neither a build of the app
# nor CI needs Node; this is how that output is remade when a version changes. The build refuses a
# package whose licence is not on its permissive list, and a buffer it cannot patch.
#
# Needs Node 18 or later. Commit package-lock.json and the regenerated files together.

set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT/Resources/JavaScript"

npm ci --no-audit --no-fund
node build.mjs
