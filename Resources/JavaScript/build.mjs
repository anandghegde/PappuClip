// Builds the JavaScript that PappuClipJSHost.xpc gives every extension (architecture §10.1, JS-2,
// JS-9). Run through Scripts/update-js-environment.sh, which installs the pinned packages first.
//
// Writes, into the PappuJSHost target's resources:
//   environment.js           the globals (see src/environment.js)
//   libraries/<name>.js      one self-contained CommonJS module per library `require()` can load
//   libraries.json           each library's version and licence, and every package inside it
//   tooling/<name>.js        the helper's own tools, which no extension can require (acorn)
//   THIRD-PARTY-NOTICES.txt  the licence text of every package in any of the above
//
// Everything is CommonJS text that the helper wraps and evaluates itself, so none of it is ever
// fetched, and nothing here runs at app build time: the output is checked in, and this script is
// how it is remade when a version changes.
import * as esbuild from 'esbuild';
import { readFileSync, writeFileSync, mkdirSync, rmSync, existsSync, readdirSync } from 'node:fs';
import { dirname, join, relative, sep } from 'node:path';
import { fileURLToPath } from 'node:url';

const here = dirname(fileURLToPath(import.meta.url));
const output = join(here, '../../Packages/PappuKit/Sources/PappuJSHost/JavaScript');
const manifest = JSON.parse(readFileSync(join(here, 'package.json'), 'utf8'));

// JS-9, in the order the specification lists them. `buffer` is not built on its own: it is the
// environment's, so that `require("buffer").Buffer` is the global `Buffer`.
const libraries = [
  'axios', 'buffer', 'case-anything', 'content-type', 'dom-serializer', 'emoji-regex', 'entities',
  'fast-json-stable-stringify', 'fast-plist', 'htmlparser2', 'js-yaml', 'linkedom', 'linkifyjs',
  'oauth-1.0a', 'rot13-cipher', 'sanitize-html', 'sucrase', 'turndown', 'valibot',
];
const sharedWithTheEnvironment = new Set(['buffer']);

// The helper's own tools. They run in its tooling virtual machine, beside sucrase, and never in an
// extension's world, so `require()` does not find them: acorn parses an extension's source for the
// reachable-method scan (EXM-5f, architecture §9.3) and evaluates none of it.
const tooling = ['acorn'];

// Built for the browser, a library that needs a DOM expects `document`, and there is none. turndown's
// Node build brings its own (domino), which is what makes `turndown(htmlString)` work.
const overrides = {
  turndown: { platform: 'neutral', mainFields: ['main'] },
};

// Every macOS the app supports (15 and later) has at least Safari 18's JavaScriptCore, so nothing
// newer than that is lowered.
const common = {
  bundle: true,
  write: false,
  metafile: true,
  format: 'cjs',
  target: 'safari18',
  charset: 'utf8',
  legalComments: 'none',
  minifySyntax: true,
  minifyWhitespace: true,
  logLevel: 'warning',
  define: { 'process.env.NODE_ENV': '"production"' },
};

// PopClip's `Buffer` is "a modified version of the buffer npm package (6.0.3)", and the modification
// that shows is `base64url`, which 6.0.3 does not know. Decoding it already works, because buffer's
// base64 decoder accepts `-` and `_`; these add the name and the encoder. Each edit must apply
// exactly once, so a different buffer fails the build rather than quietly losing the encoding.
const bufferEdits = [
  [
    "    case 'base64':\n    case 'ucs2':",
    "    case 'base64':\n    case 'base64url':\n    case 'ucs2':",
  ],
  [
    "      case 'base64':\n        return base64ToBytes(string).length",
    "      case 'base64':\n      case 'base64url':\n        return base64ToBytes(string).length",
  ],
  [
    "      case 'base64':\n        return base64Slice(this, start, end)\n",
    "      case 'base64':\n        return base64Slice(this, start, end)\n\n      case 'base64url':\n" +
      "        return base64Slice(this, start, end).replace(/\\+/g, '-').replace(/\\//g, '_').replace(/=+$/, '')\n",
  ],
  [
    "      case 'base64':\n        // Warning: maxLength not taken into account in base64Write",
    "      case 'base64':\n      case 'base64url':\n        // Warning: maxLength not taken into account in base64Write",
  ],
];

const patchBuffer = {
  name: 'buffer-base64url',
  setup(build) {
    build.onLoad({ filter: /[\\/]node_modules[\\/]buffer[\\/]index\.js$/ }, (args) => {
      let text = readFileSync(args.path, 'utf8');
      for (const [from, to] of bufferEdits) {
        const count = text.split(from).length - 1;
        if (count !== 1) throw new Error(`buffer: expected one match for ${JSON.stringify(from)}, found ${count}`);
        text = text.replace(from, () => to);
      }
      return { contents: text, loader: 'js' };
    });
  },
};

function packageOf(input) {
  // node_modules/@scope/name/... or node_modules/name/..., innermost node_modules wins.
  const parts = input.split(/[\\/]/);
  const at = parts.lastIndexOf('node_modules');
  if (at < 0) return null;
  const name = parts[at + 1].startsWith('@') ? `${parts[at + 1]}/${parts[at + 2]}` : parts[at + 1];
  const root = parts.slice(0, at + 1 + name.split('/').length).join(sep);
  return { name, root };
}

// For a package that ships no licence file, the licence its package.json names, with the author it
// names as the copyright holder. Only the licences that turn up are here; any other stops the build.
function standardText(license, author) {
  const holder = typeof author === 'string' ? author : author?.name;
  if (!holder) throw new Error(`a ${license} package with no licence file and no author`);
  const texts = {
    ISC: `ISC License\n\nCopyright (c) ${holder}\n\nPermission to use, copy, modify, and/or distribute this software for any purpose with or without fee is hereby granted, provided that the above copyright notice and this permission notice appear in all copies.\n\nTHE SOFTWARE IS PROVIDED "AS IS" AND THE AUTHOR DISCLAIMS ALL WARRANTIES WITH REGARD TO THIS SOFTWARE INCLUDING ALL IMPLIED WARRANTIES OF MERCHANTABILITY AND FITNESS. IN NO EVENT SHALL THE AUTHOR BE LIABLE FOR ANY SPECIAL, DIRECT, INDIRECT, OR CONSEQUENTIAL DAMAGES OR ANY DAMAGES WHATSOEVER RESULTING FROM LOSS OF USE, DATA OR PROFITS, WHETHER IN AN ACTION OF CONTRACT, NEGLIGENCE OR OTHER TORTIOUS ACTION, ARISING OUT OF OR IN CONNECTION WITH THE USE OR PERFORMANCE OF THIS SOFTWARE.`,
  };
  if (!texts[license]) throw new Error(`no standard text for ${license}`);
  return `${texts[license]}\n\n(The package ships no licence file; this is the standard ${license} text with the author its package.json names.)`;
}

// Anything else is a licence someone has to read before it ships (JS-9: "confirm each licence").
const permissive = new Set(['MIT', 'ISC', 'BSD-2-Clause', 'BSD-3-Clause', 'Apache-2.0', '0BSD']);

const notices = new Map();

function audit(metafile) {
  const packages = new Map();
  for (const input of Object.keys(metafile.inputs)) {
    const found = packageOf(input);
    if (!found || packages.has(found.root)) continue;
    const info = JSON.parse(readFileSync(join(here, found.root, 'package.json'), 'utf8'));
    const license = typeof info.license === 'string' ? info.license : info.license?.type ?? 'UNKNOWN';
    const file = readdirSync(join(here, found.root)).find((name) => /^(licen[cs]e|copying)([.-]|$)/i.test(name));
    const text = file ? readFileSync(join(here, found.root, file), 'utf8').trim() : standardText(license, info.author);
    if (!permissive.has(license)) throw new Error(`${info.name}@${info.version} is ${license}, which is not on the permissive list`);
    packages.set(found.root, { name: info.name, version: info.version, license, text });
  }
  const list = [...packages.values()].sort((a, b) => a.name.localeCompare(b.name) || a.version.localeCompare(b.version));
  for (const entry of list) notices.set(`${entry.name}@${entry.version}`, entry);
  return list;
}

async function build(contents, resolveDir, extra = {}) {
  const result = await esbuild.build({
    ...common,
    ...extra,
    stdin: { contents, resolveDir, sourcefile: 'entry.js', loader: 'js' },
  });
  return { text: result.outputFiles[0].text, packages: audit(result.metafile) };
}

rmSync(output, { recursive: true, force: true });
mkdirSync(join(output, 'libraries'), { recursive: true });
mkdirSync(join(output, 'tooling'), { recursive: true });

const environment = await build(
  readFileSync(join(here, 'src/environment.js'), 'utf8'),
  join(here, 'src'),
  { platform: 'neutral', mainFields: ['module', 'main'], plugins: [patchBuffer] },
);
writeFileSync(join(output, 'environment.js'), environment.text);

const record = {};
for (const name of libraries) {
  const version = manifest.dependencies[name];
  if (sharedWithTheEnvironment.has(name)) {
    const own = environment.packages.find((entry) => entry.name === name);
    record[name] = { version, license: own.license, file: 'environment.js', packages: [`${own.name}@${own.version}`] };
    continue;
  }
  // `require` rather than `import`, so the module is what Node's `require` would return: axios is the
  // axios function, and an ES module is its namespace object.
  const library = await build(`module.exports = require(${JSON.stringify(name)});`, here, {
    platform: 'browser',
    external: [...sharedWithTheEnvironment],
    ...overrides[name],
  });
  const file = `libraries/${name}.js`;
  writeFileSync(join(output, file), library.text);
  const own = library.packages.find((entry) => entry.name === name);
  if (own.version !== version) throw new Error(`${name} resolved to ${own.version}, not the pinned ${version}`);
  record[name] = {
    version,
    license: own.license,
    file,
    packages: library.packages.map((entry) => `${entry.name}@${entry.version}`),
  };
}

const tools = {};
for (const name of tooling) {
  const version = manifest.dependencies[name];
  const tool = await build(`module.exports = require(${JSON.stringify(name)});`, here, { platform: 'neutral', mainFields: ['main'] });
  const file = `tooling/${name}.js`;
  writeFileSync(join(output, file), tool.text);
  const own = tool.packages.find((entry) => entry.name === name);
  if (own.version !== version) throw new Error(`${name} resolved to ${own.version}, not the pinned ${version}`);
  tools[name] = { version, license: own.license, file, packages: tool.packages.map((entry) => `${entry.name}@${entry.version}`) };
}

const environmentPackages = environment.packages.map((entry) => `${entry.name}@${entry.version}`);
writeFileSync(
  join(output, 'libraries.json'),
  JSON.stringify({ environment: { packages: environmentPackages }, libraries: record, tooling: tools }, null, 2) + '\n',
);

const lines = [
  'Third-party software in the JavaScript that PappuClip gives extensions.',
  'Generated by Resources/JavaScript/build.mjs; do not edit.',
  '',
];
for (const [id, entry] of [...notices.entries()].sort(([a], [b]) => a.localeCompare(b))) {
  lines.push('='.repeat(78), `${id} (${entry.license})`, '='.repeat(78), '', entry.text, '');
}
writeFileSync(join(output, 'THIRD-PARTY-NOTICES.txt'), lines.join('\n'));

const sizes = readdirSync(join(output, 'libraries')).map((file) => [file, readFileSync(join(output, 'libraries', file)).length]);
console.log(`environment.js ${environment.text.length} bytes, ${environmentPackages.length} packages`);
for (const [file, size] of sizes) console.log(`libraries/${file} ${size} bytes`);
for (const name of tooling) console.log(`tooling/${name}.js ${readFileSync(join(output, 'tooling', `${name}.js`)).length} bytes`);
const licences = [...new Set([...notices.values()].map((entry) => entry.license))].sort().join(', ');
console.log(`${notices.size} packages in all, under ${licences}`);
