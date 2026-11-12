'use strict';
const assert = require('node:assert/strict');
function extract(swift) {
    const match = swift.match(/static let bootstrapSource: String = """\r?\n([\s\S]*?)\r?\n    """/);
    assert.ok(match, 'extract actual production bootstrap');
    const raw = match[1].replace(/^    /gm, '');
    assert.ok(!raw.replace(/\\\\/g, '').includes('\\'), 'unsupported Swift escape/interpolation: extend decoder explicitly');
    const source = raw.replace(/\\\\/g, '\\');
    function css(pattern) {
        const found = swift.match(pattern);
        assert.ok(found, 'extract actual production CSS');
        let result = found[1];
        for (const [key, value] of Object.entries({'colors.bg':'white','colors.fg':'black','fontSize':'20','lineHeight':'30','max(8, spacing + 6)':'10'})) {
            result = result.split('\\(' + key + ')').join(value);
        }
        assert.ok(!result.includes('\\('), 'unresolved Swift CSS interpolation');
        return result;
    }
    return {source,
        base: css(/let base = """\r?\n([\s\S]*?)\r?\n        """/),
        author: css(/let authorBase = """\r?\n([\s\S]*?)\r?\n        """/),
        paged: css(/return effectiveBase \+ """\r?\n([\s\S]*?)\r?\n        """/)};
}
module.exports = {extract};
