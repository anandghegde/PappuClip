// A file may declare the names every file is given, as it may shadow PopClip's globals.
const module = 'module';
let define = 'define';
class exports {}
globalThis.shadowed = [module, define, typeof exports].join();
