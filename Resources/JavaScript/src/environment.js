// The globals every extension's world gets beyond the language itself (JS-2), evaluated once per
// world before the prelude. JavaScriptCore on its own is the language and nothing else: these are
// Web and Node APIs that a browser or Node would supply and a bare `JSContext` does not.
//
// Evaluated as a CommonJS module. Its side effect is the globals; its export is what the prelude
// needs to know that is not a global, which is the `buffer` module that `require("buffer")` returns
// (the same `Buffer` as the global, as in PopClip).
//
// Timers, `sleep`, `window`, `print` and the module system are the prelude's, because they need the
// host or the world's own state; see ExtensionVM.prelude.

// Standard behaviour, from core-js: each is installed only where the engine lacks it.
import 'core-js/modules/web.dom-exception.constructor.js';
import 'core-js/modules/web.dom-exception.stack.js';
import 'core-js/modules/web.dom-exception.to-string-tag.js';
import 'core-js/modules/web.url.constructor.js';
import 'core-js/modules/web.url.to-json.js';
import 'core-js/modules/web.url.can-parse.js';
import 'core-js/modules/web.url.parse.js';
import 'core-js/modules/web.url-search-params.constructor.js';
import 'core-js/modules/web.url-search-params.delete.js';
import 'core-js/modules/web.url-search-params.has.js';
import 'core-js/modules/web.url-search-params.size.js';
import 'core-js/modules/web.structured-clone.js';
import 'core-js/modules/web.atob.js';
import 'core-js/modules/web.btoa.js';

import * as buffer from 'buffer';
import { Blob } from './blob.js';
import { TextEncoder } from './text-encoder.js';

function install(name, value) {
  Object.defineProperty(globalThis, name, { value, writable: true, configurable: true, enumerable: false });
}

install('Buffer', buffer.Buffer);
install('TextEncoder', TextEncoder);
install('Blob', Blob);

// core-js keeps its internal state in a global of its own. Every module above already holds a
// reference to that object, so the name can go: an extension has no use for it.
delete globalThis['__core-js_shared__'];

export { buffer };
