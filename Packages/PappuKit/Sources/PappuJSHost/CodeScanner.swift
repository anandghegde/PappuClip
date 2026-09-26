import Foundation
import JavaScriptCore
import PappuJSBridge
import Synchronization

/// The reachable-method scan (EXM-5f, SEC-7c, architecture §9.3): which gated host methods an
/// extension's JavaScript names, and whether it reaches `popclip` in a way no reading can follow.
///
/// **The tooling world.** Like `Transpiler`, acorn runs in a virtual machine of its own, made the first
/// time a scan is asked for and kept for the life of the helper. An extension's source reaches it only
/// as a string that acorn parses; nothing in it is evaluated, which is why the app may ask for a scan
/// before the extension is approved.
///
/// **What is looked for.** The walk is over every node, not a list of the shapes a script is expected
/// to take, so a shape nobody thought of is still visited:
///
/// - `popclip.name` and `popclip["name"]`: the method `name`, when it is a sensitive one.
/// - `popclip[expression]`: a computed access, and the reach is unbounded.
/// - `popclip` anywhere else — assigned, passed, spread, destructured, returned — is an alias, and
///   unbounded. `typeof popclip` is not.
/// - `eval`, `Function`, a call to `.constructor`, and `with` are unbounded: each runs or looks up code
///   by a name the text does not hold.
/// - `globalThis`, `window`, `self` and `global` alone are unbounded; a member of one is read as the
///   global it names (`globalThis.popclip` is `popclip`, and `globalThis[x]` is unbounded).
/// - `$` and `XMLHttpRequest` are the shell tag and the network. `require('axios')`, or a `require`
///   whose name is not written out, is the network too, since that is what axios uses.
///
/// A file that does not parse is unbounded, rather than skipped: it may be exactly the file that does
/// the thing. TypeScript is transpiled first, which removes types and nothing else (JS-14).
final class CodeScanner: Sendable {
    static let shared = CodeScanner()

    private struct State {
        var context: JSContext?
        var scan: JSValue?
        var failure: String?
    }

    private let state = Mutex<State>(State())

    /// The sensitive methods, as `CodeScan` names them. The helper does not import the app's model, so
    /// they are written out here too; `CodeScanTests` checks the two lists agree.
    static let sensitive = [
        "pressKey", "pressKeys", "performService", "share",
        "runAppleScript", "runAppleScriptFile", "runShortcut", "runShellScript", "runShellScriptFile", "$",
        "XMLHttpRequest",
    ]

    func scan(_ request: JSScan) -> JSScanReport {
        var methods: Set<String> = []
        var unbounded: [String] = []
        func note(_ reason: String) {
            if !unbounded.contains(reason) { unbounded.append(reason) }
        }
        for source in request.sources {
            var text = source.text
            if source.typeScript || source.name.hasSuffix(".ts") {
                guard case .success(let plain) = Transpiler.shared.transform(text, as: .typeScript) else {
                    note("unreadable")
                    continue
                }
                text = plain
            }
            guard let found = parse(text) else {
                note("unreadable")
                continue
            }
            methods.formUnion(found.methods)
            found.unbounded.forEach(note)
        }
        return JSScanReport(methods: methods.sorted(), unbounded: unbounded)
    }

    /// One file's findings, or nil when it did not parse or acorn is missing.
    private func parse(_ text: String) -> (methods: [String], unbounded: [String])? {
        state.withLock { state in
            guard let scan = Self.prepare(&state),
                  let result = scan.call(withArguments: [text]), result.isObject,
                  result.objectForKeyedSubscript("error")?.isUndefined != false
            else { return nil }
            let methods = result.objectForKeyedSubscript("methods")?.toArray() as? [String] ?? []
            let unbounded = result.objectForKeyedSubscript("unbounded")?.toArray() as? [String] ?? []
            return (methods, unbounded)
        }
    }

    private static func prepare(_ state: inout State) -> JSValue? {
        if let scan = state.scan { return scan }
        if state.failure != nil { return nil }
        guard let acorn = JavaScriptResources.tool("acorn"), let context = JSContext(virtualMachine: JSVirtualMachine()) else {
            state.failure = "acorn is missing from the helper."
            return nil
        }
        context.name = "CodeScanner"
        var thrown: String?
        context.exceptionHandler = { _, value in thrown = value.map(ExtensionVM.describe) }
        let wrapper = context.evaluateScript(Self.wrapper, withSourceURL: URL(string: "pappuclip:scanner"))
        let scan = wrapper?.call(withArguments: [acorn, sensitive])
        guard thrown == nil, let scan, scan.isObject else {
            state.failure = "The scanner would not load: \(thrown ?? "no function")"
            return nil
        }
        context.exceptionHandler = { _, _ in }
        state.context = context
        state.scan = scan
        return scan
    }

    /// Evaluates acorn as a CommonJS module and returns a function that never throws: it answers
    /// `{ methods, unbounded }`, or `{ error }` for text that does not parse.
    private static let wrapper = #"""
    (function (text, sensitiveNames) {
      'use strict';
      const module = { exports: {} };
      (0, eval)('(function (exports, require, module) {' + text + '\n})\n//# sourceURL=pappuclip:tooling/acorn')
        .call(module.exports, module.exports, function (name) { throw new Error("Cannot find module '" + name + "'"); }, module);
      const acorn = module.exports;
      const POPCLIP = new Set(['popclip', 'pappuclip']);
      const GLOBALS = new Set(['globalThis', 'window', 'self', 'global']);
      const SENSITIVE = new Set(sensitiveNames);
      const NETWORK_MODULES = new Set(['axios']);

      function parse(source) {
        const options = { ecmaVersion: 'latest', allowHashBang: true, allowReturnOutsideFunction: true, allowAwaitOutsideFunction: true };
        try {
          return acorn.parse(source, Object.assign({ sourceType: 'script' }, options));
        } catch (first) {
          return acorn.parse(source, Object.assign({}, options, { sourceType: 'module', allowReturnOutsideFunction: false }));
        }
      }

      return function (source) {
        let tree;
        try { tree = parse(source); } catch (error) { return { error: String(error && error.message || error) }; }
        const methods = new Set();
        const unbounded = [];
        const note = (reason) => { if (unbounded.indexOf(reason) < 0) unbounded.push(reason); };
        const method = (name) => { if (SENSITIVE.has(name)) methods.add(name); };
        const keyName = (node) => node.computed
          ? (node.property.type === 'Literal' && typeof node.property.value === 'string' ? node.property.value : null)
          : (node.property.type === 'Identifier' ? node.property.name : null);

        // A name read as a value. Bindings and property keys never get here.
        function reference(name, parent, key) {
          if (parent && parent.type === 'UnaryExpression' && parent.operator === 'typeof') return;
          if (POPCLIP.has(name)) note('aliased-popclip');
          else if (name === 'eval') note('eval');
          else if (name === 'Function') {
            if (!(parent && parent.type === 'BinaryExpression' && parent.operator === 'instanceof' && key === 'right')) note('function-constructor');
          } else if (GLOBALS.has(name)) note('global-object');
          else method(name);
        }

        // A member of `popclip`, or of the global object, which is the global it names.
        function member(node) {
          const object = node.object;
          if (object.type !== 'Identifier') return false;
          const name = keyName(node);
          if (POPCLIP.has(object.name)) {
            if (name === null) note('computed-access'); else method(name);
            if (node.computed) visit(node.property, node, 'property');
            return true;
          }
          if (GLOBALS.has(object.name)) {
            if (name === null) note('global-object'); else reference(name, node, 'property');
            if (node.computed) visit(node.property, node, 'property');
            return true;
          }
          return false;
        }

        function isBinding(parent, key) {
          switch (parent.type) {
            case 'VariableDeclarator': return key === 'id';
            case 'FunctionDeclaration': case 'FunctionExpression': case 'ArrowFunctionExpression': return key === 'id' || key === 'params';
            case 'ClassDeclaration': case 'ClassExpression': return key === 'id';
            case 'CatchClause': return key === 'param';
            case 'LabeledStatement': case 'BreakStatement': case 'ContinueStatement': return key === 'label';
            case 'ImportSpecifier': case 'ImportDefaultSpecifier': case 'ImportNamespaceSpecifier': case 'ExportSpecifier': return true;
            case 'MetaProperty': return true;
            default: return false;
          }
        }

        function visit(node, parent, key) {
          if (!node || typeof node.type !== 'string') return;
          switch (node.type) {
            case 'Identifier':
              if (!parent || !isBinding(parent, key)) reference(node.name, parent, key);
              return;
            case 'MemberExpression':
              if (member(node)) return;
              visit(node.object, node, 'object');
              if (node.computed) visit(node.property, node, 'property');
              else if (node.property.type === 'Identifier' && node.property.name === 'constructor'
                       && parent && (parent.type === 'CallExpression' || parent.type === 'NewExpression') && key === 'callee') note('function-constructor');
              return;
            case 'Property': case 'MethodDefinition': case 'PropertyDefinition':
              // A key written out is a name, not a reference; `{ popclip }` is still one, as its value.
              if (node.computed) visit(node.key, node, 'key');
              visit(node.value, node, 'value');
              return;
            case 'WithStatement':
              note('with');
              break;
            case 'CallExpression':
              if (node.callee.type === 'Identifier' && node.callee.name === 'require') {
                const first = node.arguments[0];
                if (!first || first.type !== 'Literal' || NETWORK_MODULES.has(first.value)) method('XMLHttpRequest');
              }
              break;
            case 'ImportDeclaration':
              if (NETWORK_MODULES.has(node.source.value)) method('XMLHttpRequest');
              break;
            case 'ImportExpression':
              method('XMLHttpRequest');
              break;
          }
          for (const field in node) {
            if (field === 'type' || field === 'start' || field === 'end' || field === 'loc' || field === 'range') continue;
            const child = node[field];
            if (Array.isArray(child)) child.forEach((item) => visit(item, node, field));
            else if (child && typeof child.type === 'string') visit(child, node, field);
          }
        }

        visit(tree, null, null);
        return { methods: Array.from(methods), unbounded: unbounded };
      };
    })
    """#
}
