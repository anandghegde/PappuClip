# The JavaScript environment's sources

What `PappuClipJSHost.xpc` gives every extension beyond the language itself: the globals of JS-2 that a bare `JSContext` lacks, and the libraries of JS-9 that `require()` can load by name. `Scripts/update-js-environment.sh` builds them from here into `Packages/PappuKit/Sources/PappuJSHost/JavaScript/`, and that output is checked in, so building the app never needs Node.

| File | What it is |
|---|---|
| `package.json`, `package-lock.json` | The pinned versions. Change a version here, run the script, commit both with the output |
| `build.mjs` | esbuild: one CommonJS bundle for the environment and one per library, the licence check, and the notices |
| `src/environment.js` | The globals: `URL`, `URLSearchParams`, `structuredClone`, `atob`, `btoa` and `DOMException` from core-js; `Buffer`; `TextEncoder`; `Blob` |
| `src/blob.js`, `src/text-encoder.js` | Written here, as narrow as PopClip's (see below) |

The build output is `environment.js`, `libraries/<name>.js`, `libraries.json`, which lists each library's version, licence and every package inside it, and `THIRD-PARTY-NOTICES.txt`. The build is deterministic: running it twice gives the same bytes.

Timers, `sleep`, `window`, `print`, `define` and the module system are not here. They need the host or the world's own state, so they are in `ExtensionVM`'s prelude.

## Matching PopClip

PopClip's type definitions (`@popclip/types`, the version the corpus pins) describe this environment. They are read for behaviour and never copied (DEV-3).

- **`Buffer`** is the `buffer` package at 6.0.3, which PopClip says it ships "modified". The modification that can be seen is the `base64url` encoding, which 6.0.3 lacks, and `build.mjs` adds it. Each of its four edits must apply exactly once, so a different `buffer` fails the build instead of quietly losing the encoding. `require("buffer").Buffer` is the global `Buffer`. Every library that uses `buffer` is built with it external, so they all share that one.
- **`Blob`** has the shape of the `node-blob` package: the contents are a `Buffer` in `buffer`, with `size`, `type`, `isClosed`, `slice()` and `close()`, and no `text()`, `arrayBuffer()` or `stream()`.
- **`TextEncoder`** is UTF-8 only and `encode()` returns a `Buffer`. There is no `TextDecoder`, as in PopClip.
- **`URL`, `URLSearchParams`, `structuredClone`, `atob`, `btoa`** are the standard APIs, from core-js. It also installs `DOMException`, because `structuredClone` and `atob` throw one. core-js's own global, `__core-js_shared__`, is deleted once everything is installed.
- **Libraries** are built for the browser, so axios uses `XMLHttpRequest` (JS-8, M3 week 4). The exception is turndown, which is built from its Node entry: that brings its own DOM (domino) and so works on an HTML string, where the browser build expects a `document` that does not exist here.

## Licence audit (JS-9)

Every package in any bundle is checked as the build runs. A licence outside MIT, ISC, BSD-2-Clause, BSD-3-Clause, Apache-2.0 and 0BSD stops the build. So does a package that ships no licence file unless its licence has a standard text in `build.mjs`: only boolbase (ISC) needs that, and its notice names the author its package.json gives. The one Apache-2.0 package, ts-interface-checker inside sucrase, ships no NOTICE file. Across the environment and the 18 bundles there are 48 packages.

| Library | Version | Licence | Other packages in its bundle | Major version checked against PopClip |
|---|---|---|---|---|
| axios | 1.12.2 | MIT | 0 | Yes |
| buffer | 6.0.3 | MIT | 0 (in `environment.js`) | Yes |
| case-anything | 2.1.13 | MIT | 0 | Yes |
| content-type | 1.0.5 | MIT | 0 | No |
| dom-serializer | 2.0.0 | MIT | 2 | Yes |
| emoji-regex | 10.6.0 | MIT | 0 | No |
| entities | 7.0.0 | BSD-2-Clause | 0 | Yes |
| fast-json-stable-stringify | 2.1.0 | MIT | 0 | No |
| fast-plist | 0.1.3 | MIT | 0 | No |
| htmlparser2 | 10.0.0 | MIT | 6 | Yes |
| js-yaml | 4.1.0 | MIT | 0 | Yes |
| linkedom | 0.18.12 | ISC | 13 | Yes |
| linkifyjs | 4.3.3 | MIT | 0 | No |
| oauth-1.0a | 2.2.6 | MIT | 0 | Yes |
| rot13-cipher | 1.0.0 | MIT | 0 | Yes |
| sanitize-html | 2.17.0 | MIT | 14 | Yes |
| sucrase | 3.35.1 | MIT | 6 | No |
| turndown | 7.2.1 | MIT | 1 | Yes |
| valibot | 1.1.0 | MIT | 0 | Yes |

**The last column is the open item.** JS-9 asks for the major versions PopClip bundles, and PopClip lists them on a documentation page that could not be reached when this was written. "Yes" means the version is the one the PopClip-Extensions corpus (`Tests/corpus/package.json`) pins as a dependency. PopClip tells extension authors to install the bundled version to type-check against, so that pin stands for the bundled one. "No" means the corpus does not pin the library and the long-standing major was chosen. For content-type that is 1.x, not the 2.x and 3.x rewrites of 2026, and for emoji-regex it is 10.x, not the 11.0 released in September 2026. Check the six "No" rows against https://www.popclip.app/dev/js-environment#bundled-libraries before the beta.
