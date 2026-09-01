'use strict';
'require baseclass';

function isStructuralBrace(prefix) {
    prefix = String(prefix || '').trim();
    return /^(?:table\s+\S+\s+\S+|chain\s+\S+|set\s+\S+|map\s+\S+|flowtable\s+\S+|counter\s+\S+|quota\s+\S+|limit\s+\S+|secmark\s+\S+|synproxy\s+\S+|ct\s+(?:helper|timeout|expectation)\s+\S+)$/i.test(prefix);
}

function matchingBrace(text, openPosition) {
    var depth = 0;
    var quoted = false;
    var escaped = false;
    var comment = false;

    for (var i = openPosition; i < text.length; i++) {
        var character = text.charAt(i);

        if (comment) {
            if (character === '\n')
                comment = false;
            continue;
        }

        if (quoted) {
            if (escaped)
                escaped = false;
            else if (character === '\\')
                escaped = true;
            else if (character === '"')
                quoted = false;
            continue;
        }

        if (character === '#') {
            comment = true;
        } else if (character === '"') {
            quoted = true;
        } else if (character === '{') {
            depth++;
        } else if (character === '}') {
            depth--;
            if (depth === 0)
                return i;
            if (depth < 0)
                return -1;
        }
    }

    return -1;
}

function listItems(body) {
    body = String(body || '');
    var items = [];
    var value = '';
    var quoted = false;
    var escaped = false;

    for (var i = 0; i < body.length; i++) {
        var character = body.charAt(i);

        if (quoted) {
            value += character;
            if (escaped)
                escaped = false;
            else if (character === '\\')
                escaped = true;
            else if (character === '"')
                quoted = false;
            continue;
        }

        if (character === '"') {
            quoted = true;
            value += character;
        } else if (character === '#' || character === ';' || character === '{' || character === '}') {
            return null;
        } else if (character === ',') {
            value = value.replace(/\s+/g, ' ').trim();
            if (!value)
                return null;
            items.push(value);
            value = '';
        } else {
            value += character;
        }
    }

    value = value.replace(/\s+/g, ' ').trim();
    if (value)
        items.push(value);
    else if (items.length)
        return null;

    return items;
}

function formatNftables(source) {
    var text = String(source || '').replace(/\r\n?/g, '\n');
    var lines = [];
    var line = '';
    var indent = 0;
    var quoted = false;
    var escaped = false;
    var comment = false;

    function flush() {
        var value = line.trim();
        if (value)
            lines.push('    '.repeat(indent) + value);
        line = '';
    }

    function space() {
        if (line && !/\s$/.test(line))
            line += ' ';
    }

    function openBlock() {
        space();
        line += '{';
        flush();
        indent++;
    }

    for (var i = 0; i < text.length; i++) {
        var character = text.charAt(i);

        if (comment) {
            if (character === '\n') {
                flush();
                comment = false;
            } else {
                line += character;
            }
            continue;
        }

        if (quoted) {
            line += character;
            if (escaped)
                escaped = false;
            else if (character === '\\')
                escaped = true;
            else if (character === '"')
                quoted = false;
            continue;
        }

        if (character === '#') {
            space();
            line += character;
            comment = true;
        } else if (character === '"') {
            line += character;
            quoted = true;
        } else if (character === '{') {
            if (isStructuralBrace(line)) {
                openBlock();
                continue;
            }

            var closePosition = matchingBrace(text, i);
            var items = closePosition >= 0 ? listItems(text.slice(i + 1, closePosition)) : null;
            if (items === null || closePosition < 0) {
                openBlock();
                continue;
            }

            if (items.length <= 2) {
                space();
                line += items.length ? '{ ' + items.join(', ') + ' }' : '{}';
            } else {
                space();
                line += '{';
                flush();
                indent++;
                for (var itemIndex = 0; itemIndex < items.length; itemIndex += 2) {
                    var pair = items.slice(itemIndex, itemIndex + 2).join(', ');
                    if (itemIndex + 2 < items.length)
                        pair += ',';
                    lines.push('    '.repeat(indent) + pair);
                }
                indent = Math.max(0, indent - 1);
                line = '}';
            }
            i = closePosition;
        } else if (character === '}') {
            flush();
            indent = Math.max(0, indent - 1);
            line = '}';
        } else if (character === ';') {
            line = line.replace(/\s+$/, '') + ';';
            flush();
        } else if (character === '\n') {
            flush();
        } else if (/\s/.test(character)) {
            space();
        } else {
            if (line === '}')
                line += ' ';
            line += character;
        }
    }

    flush();
    return lines.join('\n') + (lines.length ? '\n' : '');
}

return baseclass.extend({
    format: formatNftables
});
