// PappuClipJSHost.xpc (architecture §10): extensions' JavaScript, one world per extension, in a
// sandbox with no network and no files. Everything it does is PappuJSHost.
import PappuJSHost

JSHostListener.run()
