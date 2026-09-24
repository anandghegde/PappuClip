// JS-2: `TextEncoder`, as narrow as PopClip's: UTF-8 only, and `encode()` returns a `Buffer` (which
// is a `Uint8Array`, so code expecting the Web API's return type still works). There is no
// `TextDecoder`, as there is none in PopClip; `Buffer#toString()` is the way back.
import { Buffer } from 'buffer';

export class TextEncoder {
  get encoding() {
    return 'utf-8';
  }

  encode(input = '') {
    // Buffer's UTF-8 encoder replaces a lone surrogate with U+FFFD, as the Web API does.
    return Buffer.from(String(input), 'utf8');
  }

  get [Symbol.toStringTag]() {
    return 'TextEncoder';
  }
}
