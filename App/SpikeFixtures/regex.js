// A detector: several regular expressions over the whole selection, one action per kind of thing found.
var detectors = [
    { title: "Open Links", pattern: /\bhttps?:\/\/[^\s<>"')\]]+/gi },
    { title: "Email", pattern: /\b[A-Z0-9._%+-]+@[A-Z0-9.-]+\.[A-Z]{2,}\b/gi },
    { title: "Call", pattern: /(?:\+?\d{1,3}[\s.-]?)?(?:\(\d{2,4}\)|\d{2,4})[\s.-]?\d{3,4}[\s.-]?\d{3,4}\b/g },
    { title: "Add to Calendar", pattern: /\b(?:\d{1,2}[\/.-]\d{1,2}[\/.-]\d{2,4}|\d{4}-\d{2}-\d{2}|(?:Jan|Feb|Mar|Apr|May|Jun|Jul|Aug|Sep|Oct|Nov|Dec)[a-z]*\.?\s+\d{1,2}(?:st|nd|rd|th)?(?:,?\s+\d{4})?)\b/gi },
    { title: "Convert", pattern: /(?:[$€£¥]\s?\d[\d,]*(?:\.\d+)?|\b\d[\d,]*(?:\.\d+)?\s?(?:USD|EUR|GBP|JPY|km|mi|kg|lb|°[CF])\b)/g },
    { title: "Colour", pattern: /#(?:[0-9a-f]{3}){1,2}\b|\brgba?\(\s*\d{1,3}\s*,\s*\d{1,3}\s*,\s*\d{1,3}(?:\s*,\s*[\d.]+)?\s*\)/gi },
    { title: "Track Parcel", pattern: /\b(?:1Z[0-9A-Z]{16}|\d{12,22})\b/g },
    { title: "Hex to Decimal", pattern: /\b0x[0-9a-f]+\b/gi }
];

module.exports = {
    actions: function (input, options, context) {
        var text = input.text;
        var result = [];
        for (var i = 0; i < detectors.length; i++) {
            var matches = text.match(detectors[i].pattern);
            if (matches && matches.length) {
                result.push({ title: detectors[i].title, count: matches.length });
            }
        }
        var words = text.split(/\s+/).filter(function (w) { return w.length > 0; });
        result.push({ title: "Count", words: words.length, characters: text.length });
        return result;
    }
};
