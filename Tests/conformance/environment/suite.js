// The conformance suite's environment section (implementation plan, M3 week 2): the globals, the
// bundled libraries and the module system that every extension's world has (JS-2, JS-9, JS-10,
// JS-14), checked from inside a world as an extension would see them.
//
// This folder is a package. `suite.js` is an action's script: it runs every check and returns "ok",
// or one line per failure. PappuJSHostTests runs it in the helper's own code (JSHostTests,
// `theEnvironmentSectionOfTheConformanceSuitePasses`), and `pappuclip run` will run it as it stands.
// The other files are what it requires.
//
// Not here yet, because their weeks have not come: `util`, `pasteboard`, `RichString`, `$` and the
// `popclip` methods (week 3), and `XMLHttpRequest` (week 4). Where this differs from what PopClip's
// type definitions describe, the check says so.

const failures = [];

function format(value) {
  try {
    return JSON.stringify(value);
  } catch (error) {
    return String(value);
  }
}

async function check(name, body) {
  try {
    const result = await body();
    if (result !== true) failures.push(name + ': ' + format(result));
  } catch (error) {
    failures.push(name + ': threw ' + (error && error.message ? error.message : String(error)));
  }
}

function same(actual, expected) {
  return format(actual) === format(expected) ? true : { actual: actual, expected: expected };
}

function thrown(body, property) {
  try {
    body();
    return 'nothing was thrown';
  } catch (error) {
    return error[property];
  }
}

// JS-2

await check('JS-2: the globals', () => {
  const kinds = {
    popclip: typeof popclip, pappuclip: typeof pappuclip, print: typeof print, sleep: typeof sleep,
    defineExtension: typeof defineExtension, require: typeof require, module: typeof module,
    exports: typeof exports, define: typeof define, Buffer: typeof Buffer, URL: typeof URL,
    URLSearchParams: typeof URLSearchParams, structuredClone: typeof structuredClone,
    setTimeout: typeof setTimeout, clearTimeout: typeof clearTimeout, setInterval: typeof setInterval,
    clearInterval: typeof clearInterval, Blob: typeof Blob, TextEncoder: typeof TextEncoder,
    atob: typeof atob, btoa: typeof btoa, window: typeof window,
  };
  return same(Object.keys(kinds).filter((name) => kinds[name] === 'undefined'), []);
});

await check('JS-2: popclip and pappuclip are one object, and window is the global', () =>
  same([popclip === pappuclip, window === globalThis], [true, true]));

await check('JS-1: no fetch, DOM, process, storage or TextDecoder', () =>
  same([typeof fetch, typeof document, typeof process, typeof localStorage, typeof TextDecoder], Array(5).fill('undefined')));

await check('JS-2: sleep waits', async () => {
  const start = Date.now();
  await sleep(20);
  return Date.now() - start >= 19 || 'woke after ' + (Date.now() - start) + ' ms';
});

await check('JS-2: timers fire in the order of their deadlines', async () => {
  const order = [];
  await new Promise((done) => {
    setTimeout(() => order.push('later'), 10);
    setTimeout(() => order.push('sooner'), 0);
    setTimeout(done, 30);
  });
  return same(order, ['sooner', 'later']);
});

await check('JS-2: clearTimeout, setInterval and clearInterval', async () => {
  let fired = false;
  clearTimeout(setTimeout(() => { fired = true; }, 0));
  let count = 0;
  await new Promise((done) => {
    const id = setInterval(() => {
      count += 1;
      if (count === 3) {
        clearInterval(id);
        done();
      }
    }, 1);
  });
  await sleep(15);
  return same([fired, count], [false, 3]);
});

await check('JS-2: a timer id is a positive integer, and a callback must be a function', () => {
  const id = setTimeout(() => {}, 0);
  clearTimeout(id);
  return same([Number.isInteger(id) && id > 0, thrown(() => setTimeout('1 + 1', 0), 'name')], [true, 'TypeError']);
});

await check('JS-2: Buffer and its encodings, base64url included', () => same([
  Buffer.from('hello').toString('base64'),
  Buffer.from('aGVsbG8=', 'base64').toString(),
  Buffer.from('68656c6c6f', 'hex').toString(),
  Buffer.from([0xfb, 0xef, 0xff]).toString('base64url'),
  Buffer.from('--__', 'base64url').toString('hex'),
  Buffer.isEncoding('base64url'),
  Buffer.byteLength('héllo'),
  Buffer.from('hi', 'utf16le').length,
  Buffer.from('é', 'latin1')[0],
], ['aGVsbG8=', 'hello', 'hello', '--__', 'fbefff', true, 6, 4, 0xe9]));

await check('JS-2: the global Buffer is require("buffer").Buffer, and a Uint8Array', () =>
  same([require('buffer').Buffer === Buffer, Buffer.alloc(2) instanceof Uint8Array, Buffer.isBuffer(Buffer.from('x'))], [true, true, true]));

await check('JS-2: URL and URLSearchParams', () => {
  const url = new URL('https://user:pw@EXAMPLE.com:8080/a/../b?q=hello world#top');
  url.searchParams.append('q', 'more');
  url.hash = '';
  return same([
    url.href,
    url.host,
    url.origin,
    url.searchParams.getAll('q'),
    new URL('../x', 'https://e.com/a/b/c').href,
    new URL('https://münchen.de/').hostname,
    new URLSearchParams({ a: '1', b: 'x y' }).toString(),
    JSON.stringify({ url }),
    thrown(() => new URL('not a url'), 'name'),
  ], [
    'https://user:pw@example.com:8080/b?q=hello+world&q=more',
    'example.com:8080',
    'https://example.com:8080',
    ['hello world', 'more'],
    'https://e.com/a/x',
    'xn--mnchen-3ya.de',
    'a=1&b=x+y',
    '{"url":"https://user:pw@example.com:8080/b?q=hello+world&q=more"}',
    'TypeError',
  ]);
});

await check('JS-2: structuredClone', () => {
  const cyclic = { list: [1] };
  cyclic.self = cyclic;
  const copy = structuredClone({ date: new Date(5), map: new Map([['k', new Set([1])]]), pattern: /a/gi, bytes: new Uint8Array([1, 2]), cyclic });
  return same([
    copy.date instanceof Date && copy.date.getTime(),
    copy.map.get('k').has(1),
    copy.pattern.flags,
    copy.bytes[1],
    copy.cyclic.self === copy.cyclic && copy.cyclic !== cyclic,
    thrown(() => structuredClone(() => 1), 'name'),
  ], [5, true, 'gi', 2, true, 'DataCloneError']);
});

await check('JS-2: atob and btoa', () => same([
  btoa('hello'),
  atob('aGVsbG8='),
  atob(' aGk= '),
  thrown(() => atob('*'), 'name'),
  thrown(() => btoa(String.fromCharCode(0x100)), 'name'),
], ['aGVsbG8=', 'hello', 'hi', 'InvalidCharacterError', 'InvalidCharacterError']));

await check('JS-2: TextEncoder is UTF-8 into a Buffer', () => {
  const encoder = new TextEncoder();
  const bytes = encoder.encode('é\uD800');
  return same([encoder.encoding, Buffer.isBuffer(bytes), Array.from(bytes)], ['utf-8', true, [0xc3, 0xa9, 0xef, 0xbf, 0xbd]]);
});

await check('JS-2: Blob has the node-blob shape', () => {
  const blob = new Blob(['ab', Buffer.from('c'), new Uint8Array([100]).buffer, new Blob(['e'])], { type: 'Text/Plain' });
  const tail = blob.slice(-2);
  blob.close();
  return same(
    [blob.buffer.toString(), blob.type, tail.buffer.toString(), tail.type, blob.size, blob.isClosed, Object.prototype.toString.call(blob), typeof blob.text],
    ['abcde', 'text/plain', 'de', '', 0, true, '[object Blob]', 'undefined'],
  );
});

// JS-9: each library by the name PopClip gives it, doing one thing it is for.

const libraries = {
  axios: (axios) => typeof axios.get === 'function' && typeof axios.create === 'function' && axios.default === axios,
  buffer: (buffer) => buffer.Buffer === Buffer,
  'case-anything': (c) => c.camelCase('hello big world') === 'helloBigWorld' && c.kebabCase('HelloWorld') === 'hello-world',
  'content-type': (c) => c.parse('text/html; charset=utf-8').parameters.charset === 'utf-8',
  'dom-serializer': (d) => d.default(require('htmlparser2').parseDocument('<p>hi <b>there</b></p>')) === '<p>hi <b>there</b></p>',
  'emoji-regex': (e) => 'a 👍 b'.match(e())[0] === '👍',
  entities: (e) => e.decodeHTML('&lt;a&gt; &amp; &eacute;') === '<a> & é',
  'fast-json-stable-stringify': (f) => f({ b: 1, a: [2, { d: 1, c: 2 }] }) === '{"a":[2,{"c":2,"d":1}],"b":1}',
  'fast-plist': (p) => p.parse('<plist><dict><key>a</key><string>b</string></dict></plist>').a === 'b',
  htmlparser2: (h) => {
    let text = '';
    new h.Parser({ ontext: (s) => { text += s; } }).end('<a>x</a><b>y</b>');
    return text === 'xy';
  },
  'js-yaml': (y) => y.load('a: [1, 2]').a[1] === 2 && y.dump({ x: 1 }) === 'x: 1\n',
  linkedom: (l) => l.parseHTML('<html><body><p class="x">hi</p></body></html>').document.querySelector('.x').textContent === 'hi',
  linkifyjs: (l) => l.find('see example.com and a@b.io').map((link) => link.type).join() === 'url,email',
  'oauth-1.0a': (OAuth) => OAuth({ consumer: { key: 'k', secret: 's' }, signature_method: 'PLAINTEXT', hash_function: (base, key) => key })
    .authorize({ url: 'https://example.com/', method: 'GET' }, { key: 't', secret: 'u' }).oauth_signature === 's&u',
  'rot13-cipher': (r) => r('Hello') === 'Uryyb',
  'sanitize-html': (s) => s('<p onclick="x()">ok<script>bad()</script></p>') === '<p>ok</p>',
  sucrase: (s) => s.transform('const x: number = 1; export default x', { transforms: ['typescript', 'imports'] }).code.includes('exports. default = x'),
  turndown: (Turndown) => new Turndown().turndown('<h1>Hi</h1><p><em>there</em></p>') === 'Hi\n==\n\n_there_',
  valibot: (v) => v.safeParse(v.object({ a: v.number() }), { a: 1 }).success && !v.safeParse(v.string(), 1).success,
};

for (const name of Object.keys(libraries)) {
  await check('JS-9: ' + name, () => libraries[name](require(name)));
}

// JS-10

await check('JS-10: ./ and ../ are relative to the requiring file', () =>
  same(require('./lib/greet')('there'), 'hi pappu there'));

await check('JS-10: other paths are from the package root, with index files and .ts', () =>
  same([require('lib/greet.js')('x'), require('./folder').where, require('folder').where], ['hi pappu x', 'folder/index.ts', 'folder/index.ts']));

await check('JS-10: a module is evaluated once, whatever it was called', () => {
  const first = require('./counted');
  const second = require('counted.js');
  return same([first === second, globalThis.counted], [true, 1]);
});

// PopClip: "Returns undefined if nothing is found."
await check('JS-10: what is not found is undefined', () =>
  same([require('no-such-library') === undefined, require('./no/such/file') === undefined], [true, true]));

await check('JS-10: a path that is absolute or leaves the package is refused', () => same([
  thrown(() => require('../outside'), 'code'),
  thrown(() => require('/etc/passwd'), 'code'),
  thrown(() => require('lib/../../outside'), 'code'),
  thrown(() => require('./lib/escape'), 'code'),
], Array(4).fill('MODULE_NOT_FOUND')));

// JS-14, and ES module syntax (JS-10: "import and export are converted to require")

await check('JS-14: TypeScript is transpiled and its types removed', () => {
  const util = require('./util');
  return same([util.shout('ts'), util.default], ['TS', 42]);
});

await check('JS-10: import and export become require, and CommonJS is left alone', () =>
  same([require('./esm').loud, require('./module.mjs').default, require('./plain').value, require('./plain').imports], ['ESM', 'mjs', 'cjs', 'still cjs']));

await check('JS-14: a syntax error names its file', () => {
  try {
    require('./bad');
    return 'it loaded';
  } catch (error) {
    return same([error.name, error.message.startsWith('bad.ts: ')], ['SyntaxError', true]);
  }
});

await check('JS-10: a file may declare module, define and exports itself', () => {
  require('./shadows');
  return same(globalThis.shadowed, 'module,define,function');
});

// define and defineExtension (JS-2, JS-12)

await check('JS-12: define and defineExtension are one partial AMD', () => same(
  [require('./amd-a').value, require('./amd-named'), require('./extension'), defineExtension === define, typeof define.amd],
  ['a+b', 'named', { last: true }, true, 'object'],
));

return failures.length === 0 ? 'ok' : failures.join('\n');
