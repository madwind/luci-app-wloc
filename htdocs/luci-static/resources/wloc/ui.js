'use strict';
'require baseclass';
'require ui';

var luciUi = ui;

function pageTitleSuffix() {
    if (typeof window === 'undefined')
        return null;

    var marker = '/admin/services/wloc/';
    var path = String(window.location && window.location.pathname || '');
    var offset = path.indexOf(marker);
    if (offset < 0)
        return null;

    var page = path.slice(offset + marker.length).split('/')[0];
    if (page === 'overview') return _('Overview');
    if (page === 'settings') return _('Settings');
    if (page === 'firewall') return _('Firewall');
    if (page === 'routing') return _('Routing');
    if (page === 'updates') return _('Updates');
    return null;
}

function brandPageTitles() {
    if (typeof document === 'undefined')
        return;

    var suffix = pageTitleSuffix();
    if (!suffix)
        return;

    var title = 'WLOC ' + suffix;
    document.querySelectorAll('.cbi-map-title').forEach(function(node) {
        if (node.textContent !== title)
            node.textContent = title;
    });
}

function installPageBranding() {
    if (typeof document === 'undefined' || typeof window === 'undefined')
        return;

    brandPageTitles();
    if (typeof MutationObserver !== 'function' || !document.documentElement)
        return;

    var observer = new MutationObserver(brandPageTitles);
    observer.observe(document.documentElement, { childList: true, subtree: true });
    window.addEventListener('pagehide', function() {
        observer.disconnect();
    }, { once: true });
}

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

installPageBranding();

return baseclass.extend({
    boundedLines: boundedLines,
    brandPageTitles: brandPageTitles,
    byteLength: byteLength,
    errorMessage: errorMessage,
    formatBytes: formatBytes,
    notifyFatal: notifyFatal,
    requireOk: requireOk,
    setState: setState,
    setText: setText,
    truncateBytes: truncateBytes
});
