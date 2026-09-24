// JS-2: `Blob`, as narrow as PopClip's, which is the shape of the `node-blob` package: the contents
// are a `Buffer` in `buffer`, and there is no `text()`, `arrayBuffer()` or `stream()`. It exists so
// that libraries probing for it (axios among them) find one, and so that a blob can be an
// `XMLHttpRequest` body.
import { Buffer } from 'buffer';

function bytesOf(part) {
  if (part instanceof Blob) return part.buffer;
  if (Buffer.isBuffer(part)) return part;
  if (ArrayBuffer.isView(part)) return Buffer.from(part.buffer, part.byteOffset, part.byteLength);
  if (part instanceof ArrayBuffer) return Buffer.from(part);
  return Buffer.from(String(part), 'utf8');
}

export class Blob {
  #type;
  #closed = false;

  constructor(blobParts = [], options = {}) {
    if (blobParts === null || typeof blobParts !== 'object' || typeof blobParts[Symbol.iterator] !== 'function') {
      throw new TypeError("Failed to construct 'Blob': The provided value cannot be converted to a sequence.");
    }
    // Copied, so that changing a part afterwards does not change the blob.
    this.buffer = Buffer.concat(Array.from(blobParts, (part) => Buffer.from(bytesOf(part))));
    const type = options === null || options === undefined || options.type === undefined ? '' : String(options.type);
    // The Web API's rule: a type with anything outside printable ASCII is no type at all.
    this.#type = /^[\x20-\x7e]*$/.test(type) ? type.toLowerCase() : '';
  }

  get size() {
    return this.#closed ? 0 : this.buffer.length;
  }

  get type() {
    return this.#type;
  }

  get isClosed() {
    return this.#closed;
  }

  slice(start, end, type) {
    const length = this.size;
    const clamp = (value, fallback) => {
      if (value === undefined) return fallback;
      const n = Math.trunc(Number(value)) || 0;
      return n < 0 ? Math.max(length + n, 0) : Math.min(n, length);
    };
    const from = clamp(start, 0);
    const to = Math.max(clamp(end, length), from);
    return new Blob([this.buffer.subarray(from, to)], { type: type === undefined ? '' : type });
  }

  close() {
    this.#closed = true;
  }

  get [Symbol.toStringTag]() {
    return 'Blob';
  }
}
