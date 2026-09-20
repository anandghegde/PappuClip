// A population function in its commonest shape: look at the text, offer an action or two.
module.exports = {
    actions: function (input, options, context) {
        var text = input.text;
        if (!text || !text.trim()) { return []; }
        var result = [];
        if (text !== text.toUpperCase()) {
            result.push({ title: "Uppercase", code: function (input) { return input.text.toUpperCase(); } });
        }
        if (text !== text.toLowerCase()) {
            result.push({ title: "Lowercase", code: function (input) { return input.text.toLowerCase(); } });
        }
        if (context.canPaste && text.length < 200) {
            result.push({ title: "Title Case", code: function (input) {
                return input.text.replace(/\w\S*/g, function (w) { return w.charAt(0).toUpperCase() + w.slice(1).toLowerCase(); });
            } });
        }
        return result;
    }
};
