// Runs unchanged in the helper (interpreter only) and in the jsc tool (JIT), and answers with
// "name=milliseconds" pairs. Date.now() is all a bare JSContext has, so each part runs long enough for it.
var benchResult = (function () {
    function time(body) { var start = Date.now(); body(); return Date.now() - start; }
    function fib(n) { return n < 2 ? n : fib(n - 1) + fib(n - 2); }

    var parts = [];
    parts.push("calls=" + time(function () { fib(32); }));

    parts.push("regex=" + time(function () {
        var line = "Mail ada@example.org or see https://example.org/path?q=1 before 2026-09-20, ref 0x1F and $1,250.00. ";
        var text = ""; for (var i = 0; i < 2000; i++) { text += line; }
        var total = 0;
        for (var round = 0; round < 20; round++) {
            total += (text.match(/\bhttps?:\/\/[^\s<>"')\]]+/gi) || []).length;
            total += (text.match(/\b[A-Z0-9._%+-]+@[A-Z0-9.-]+\.[A-Z]{2,}\b/gi) || []).length;
            total += text.replace(/\d{4}-\d{2}-\d{2}/g, "date").length;
        }
        if (!total) { throw new Error("regex found nothing"); }
    }));

    parts.push("strings=" + time(function () {
        var words = [];
        for (var i = 0; i < 600000; i++) { words.push("w" + (i % 977).toString(36)); }
        var joined = words.join(" ");
        var count = {};
        joined.split(" ").forEach(function (w) { count[w] = (count[w] || 0) + 1; });
        if (Object.keys(count).length !== 977) { throw new Error("strings miscounted"); }
    }));

    parts.push("json=" + time(function () {
        var items = [];
        for (var i = 0; i < 20000; i++) { items.push({ id: i, name: "item " + i, tags: ["a", "b", i % 7], nested: { on: i % 2 === 0, score: i / 3 } }); }
        for (var round = 0; round < 5; round++) { items = JSON.parse(JSON.stringify(items)); }
        if (items.length !== 20000) { throw new Error("json lost items"); }
    }));

    parts.push("sort=" + time(function () {
        var seed = 42, values = [];
        for (var i = 0; i < 300000; i++) { seed = (seed * 1103515245 + 12345) % 2147483648; values.push(seed); }
        values.sort(function (a, b) { return a - b; });
        if (values[0] > values[values.length - 1]) { throw new Error("sort failed"); }
    }));

    return parts.join(";");
})();
if (typeof print === "function") { print(benchResult); }
benchResult;
