'use strict';
'require baseclass';
'require ui';

var luciUi = ui;

function errorMessage(error, fallback) {
    var message = error;

    if (error && error.message)
        message = error.message;
    else if (error && error.error)
        message = error.error;

    if (message === undefined || message === null || String(message) === '')
        message = fallback || _('The request failed.');

    return String(message);
}

function requireOk(result, fallback) {
    if (!result || result.ok !== true)
        throw new Error(errorMessage(result, fallback));

    return result;
}

function notifyFatal(error, fallback) {
    var message = errorMessage(error, fallback);
    luciUi.addNotification(null, E('p', {}, message), 'error');
    return message;
}

function formatBytes(value) {
    var size = Number(value);
    var units = [ 'B', 'KiB', 'MiB', 'GiB' ];
    var index = 0;

    if (!isFinite(size) || size < 0)
        return _('Unknown');

    while (size >= 1024 && index < units.length - 1) {
        size /= 1024;
        index++;
    }

    return (index ? size.toFixed(1) : Math.round(size)) + ' ' + units[index];
}

function setText(node, value, fallback) {
    if (!node)
        return node;

    node.textContent = value === undefined || value === null || String(value) === ''
        ? (fallback === undefined || fallback === null ? '' : String(fallback))
        : String(value);
    return node;
}

function setState(node, state, value) {
    if (!node)
        return node;

    node.classList.remove('success', 'warning', 'error', 'notice');
    node.hidden = value === undefined || value === null || String(value) === '';
    node.style.maxWidth = '100%';
    node.style.whiteSpace = 'normal';
    node.style.overflowWrap = 'anywhere';
    setText(node, value);

    if (!node.hidden) {
        if (state === 'ok')
            node.classList.add('success');
        else if (state === 'warn')
            node.classList.add('warning');
        else if (state === 'error')
            node.classList.add('error');
        else if (state === 'notice')
            node.classList.add('notice');
    }

    return node;
}

function byteLength(value) {
    value = String(value === undefined || value === null ? '' : value);

    if (typeof TextEncoder === 'function')
        return new TextEncoder().encode(value).length;

    if (typeof Blob === 'function')
        return new Blob([ value ]).size;

    return encodeURIComponent(value).replace(/%[0-9A-F]{2}/g, 'x').length;
}

function truncateBytes(value, maxBytes) {
    value = String(value === undefined || value === null ? '' : value);
    maxBytes = Math.max(0, Number(maxBytes) || 0);

    if (byteLength(value) <= maxBytes)
        return value;

    var low = 0;
    var high = value.length;
    var best = '';

    while (low <= high) {
        var middle = Math.floor((low + high) / 2);
        var candidate = value.slice(0, middle);

        if (byteLength(candidate) <= maxBytes) {
            best = candidate;
            low = middle + 1;
        } else {
            high = middle - 1;
        }
    }

    return best;
}

function boundedLines(lines, maxLines, maxBytes) {
    var selected = [];
    var totalBytes = 0;
    var lineLimit = Math.max(0, Number(maxLines) || 0);
    var byteLimit = Math.max(0, Number(maxBytes) || 0);

    for (var index = lines.length - 1; index >= 0 && selected.length < lineLimit; index--) {
        var line = String(lines[index] === undefined || lines[index] === null ? '' : lines[index]);
        var separatorBytes = selected.length ? 1 : 0;
        var available = byteLimit - totalBytes - separatorBytes;

        if (available <= 0)
            break;

        if (byteLength(line) > available) {
            line = truncateBytes(line, available);
            selected.unshift(line);
            break;
        }

        selected.unshift(line);
        totalBytes += separatorBytes + byteLength(line);
    }

    return selected;
}

return baseclass.extend({
    boundedLines: boundedLines,
    byteLength: byteLength,
    errorMessage: errorMessage,
    formatBytes: formatBytes,
    notifyFatal: notifyFatal,
    requireOk: requireOk,
    setState: setState,
    setText: setText,
    truncateBytes: truncateBytes
});
