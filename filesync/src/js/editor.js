// ===== In-browser Text Editor =====
// Controller for the editor overlay. Opens a text-like file via /api/read,
// renders it with syntax highlighting, and supports in-place save via
// /api/save. Read-only when in safe mode or for unknown/binary files.
//
// Exposes globals used by inline HTML handlers:
//   openEditor(path, name)
//   editorClose()
//   editorSave()
//   editorIsOpen()

var _editorState = {
    open: false,
    path: null,
    name: null,
    originalContent: null,
    content: null,
    editable: false,   // can the user modify (safe mode off + server ok)
    readonly: false,   // server / file says view-only
    error: null,       // non-null when the file could not be opened
    language: null,
    saving: false,
    dirty: false,
    typeClass: 'text',
};

var _editorEls = {};
var _editorDebounce = null;

function _editorCacheEls() {
    _editorEls.view = document.getElementById('editorView');
    _editorEls.icon = document.getElementById('editorIcon');
    _editorEls.filename = document.getElementById('editorFilename');
    _editorEls.badge = document.getElementById('editorBadge');
    _editorEls.status = document.getElementById('editorStatus');
    _editorEls.saveBtn = document.getElementById('editorSaveBtn');
    _editorEls.scroll = document.getElementById('editorScroll');
    _editorEls.highlight = document.getElementById('editorHighlight');
    _editorEls.input = document.getElementById('editorInput');
    _editorEls.lines = document.getElementById('editorLines');
    _editorEls.dirty = document.getElementById('editorDirty');
    _editorEls.size = document.getElementById('editorSize');
}

function _formatEditorBytes(bytes) {
    if (typeof bytes !== 'number' || bytes < 0) return '';
    if (bytes < 1024) return bytes + ' B';
    if (bytes < 1024 * 1024) return (bytes / 1024).toFixed(1) + ' KB';
    return (bytes / (1024 * 1024)).toFixed(1) + ' MB';
}

// Byte length of a JS string as UTF-8 (JS .length counts UTF-16 code units).
function _utf8ByteLength(str) {
    if (typeof TextEncoder !== 'undefined') {
        return new TextEncoder().encode(str).length;
    }
    try { return new Blob([str]).size; } catch (e) { }
    try { return unescape(encodeURIComponent(str)).length; } catch (e) { }
    return str.length;
}

// Detect the icon type class from the file type maps already in state.js.
function _editorTypeClass(name) {
    var cls = getTypeClassFromFilename(name);
    if (cls === 'code' || cls === 'text' || cls === 'markdown') return cls;
    return 'text';
}

function _applyEditorHighlight() {
    if (!_editorEls.highlight) return;
    var lang = _editorState.language;
    var code = _editorState.content || '';
    // EditorHighlight.highlight escapes its input internally, and returns
    // plain escaped text when no rules exist for the language (or when the
    // language is null), so this single call covers both cases.
    _editorEls.highlight.innerHTML = EditorHighlight.highlight(code, lang);
}

// Re-highlight after edits (debounced so typing stays smooth).
function _editorQueueHighlight() {
    clearTimeout(_editorDebounce);
    _editorDebounce = setTimeout(function () {
        if (_editorState.open) _applyEditorHighlight();
    }, 60);
}

// The textarea is absolutely positioned over the .editor-layer and fills it
// (top/left 0, width/height 100%), so its size tracks the highlighted <pre>
// that drives the layer. For very short files the layer is shorter than the
// viewport; give the textarea at least the visible height so the whole area
// below the last line stays clickable/typeable.
function _editorResize() {
    var ta = _editorEls.input;
    var scroll = _editorEls.scroll;
    if (!ta || !scroll) return;
    ta.style.minHeight = scroll.clientHeight + 'px';
}

function _editorUpdateFooter() {
    var content = _editorState.content || '';
    var lines = content === '' ? 0 : content.split('\n').length;
    if (_editorEls.lines) {
        _editorEls.lines.textContent = lines + ' ' + t('lines');
    }
    if (_editorEls.size) {
        // Count UTF-8 bytes (not UTF-16 code units) so the label is accurate.
        _editorEls.size.textContent = _formatEditorBytes(_utf8ByteLength(content));
    }
    if (_editorEls.dirty) {
        _editorEls.dirty.style.display = _editorState.dirty ? '' : 'none';
    }
    var status = _editorEls.status;
    if (status) {
        if (_editorState.error) {
            status.textContent = _editorState.error;
        } else if (_editorState.readonly) {
            status.textContent = t('Read-only');
        } else {
            status.textContent = '';
        }
    }
}

// Debounced footer refresh: avoids re-splitting the whole doc per keystroke.
var _editorFooterDebounce = null;
function _editorQueueFooter() {
    clearTimeout(_editorFooterDebounce);
    _editorFooterDebounce = setTimeout(function () {
        if (_editorState.open) _editorUpdateFooter();
    }, 80);
}

function _editorRefresh() {
    _applyEditorHighlight();
    _editorUpdateFooter();
    _editorResize();
    // Keep scroll at top when opening
    if (_editorEls.scroll) _editorEls.scroll.scrollTop = 0;
    _editorEls.scroll.scrollLeft = 0;
}

// Public: open the editor for a file path.
window.openEditor = function (path, name) {
    _editorCacheEls();
    if (!_editorEls.view) return;

    // Reset state
    _editorState.open = true;
    _editorState.path = path;
    _editorState.name = name || (path ? path.split('/').pop() : 'file');
    _editorState.originalContent = null;
    _editorState.content = null;
    _editorState.dirty = false;
    _editorState.saving = false;
    _editorState.error = null;
    _editorState.language = EditorHighlight.detectLanguage(_editorState.name);
    _editorState.typeClass = _editorTypeClass(_editorState.name);

    // If the file detail view locked body scroll, release it — the editor
    // is a fullscreen overlay with its own scroll container.
    document.body.style.position = '';
    document.body.style.top = '';
    document.body.style.left = '';
    document.body.style.right = '';
    document.body.style.overflow = '';

    // Icon + filename
    _editorEls.icon.className = 'file-icon ' + _editorState.typeClass;
    _editorEls.icon.innerHTML = icons[_editorState.typeClass] || icons.text;
    _editorEls.filename.textContent = _editorState.name;
    _editorEls.filename.title = _editorState.path || '';

    // Show the view with a loading state
    _editorEls.view.classList.add('open');
    _editorEls.view.classList.remove('readonly');
    _editorEls.saveBtn.style.display = 'none';
    _editorEls.badge.style.display = 'none';
    _editorEls.status.textContent = t('Loading...');
    _editorEls.input.value = '';
    _editorEls.highlight.innerHTML = '';
    _editorEls.input.disabled = true;

    // Keep the detail view (if open) hidden behind the editor
    var detail = document.getElementById('fileDetail');
    if (detail) { detail.classList.remove('open'); detail.style.display = 'none'; }

    _editorFetch(path);
};

function _editorFetch(path) {
    fetch('/api/read?path=' + encodeURIComponent(path))
        .then(function (res) {
            return res.json().then(function (data) {
                return { ok: res.ok, data: data };
            });
        })
        .then(function (r) {
            if (!_editorState.open || _editorState.path !== path) return; // closed meanwhile
            if (!r.ok) {
                _editorShowError(r.data && r.data.error ? r.data.error : t('Failed to open file'));
                return;
            }
            var data = r.data;
            _editorState.originalContent = data.content || '';
            _editorState.content = data.content || '';
            _editorState.editable = data.editable === true;
            _editorState.readonly = data.editable !== true;

            _editorEls.input.value = _editorState.content;
            _editorEls.input.disabled = _editorState.readonly;

            if (_editorState.readonly) {
                _editorEls.view.classList.add('readonly');
                _editorEls.saveBtn.style.display = 'none';
                _editorEls.badge.style.display = '';
                _editorEls.badge.textContent = t('Read-only');
                _editorEls.badge.className = 'editor-badge readonly';
            } else {
                _editorEls.view.classList.remove('readonly');
                _editorEls.saveBtn.style.display = '';
                _editorEls.badge.style.display = 'none';
                // Focus for immediate typing on desktop browsers
                try { _editorEls.input.focus(); } catch (e) { }
            }
            _editorRefresh();
        })
        .catch(function () {
            if (_editorState.open && _editorState.path === path) {
                _editorShowError(t('Failed to open file'));
            }
        });
}

function _editorShowError(message) {
    _editorEls.status.textContent = message;
    _editorEls.view.classList.add('readonly');
    _editorEls.saveBtn.style.display = 'none';
    _editorEls.badge.style.display = '';
    _editorEls.badge.textContent = t('Error');
    _editorEls.badge.className = 'editor-badge readonly';
    _editorEls.highlight.innerHTML = '<span class="tok-com">' + escapeHtml(message) + '</span>';
    _editorState.readonly = true;
    _editorState.editable = false;
    _editorState.error = message;
    _editorState.content = '';
    _editorState.dirty = false;
    _editorUpdateFooter();
}

window.editorClose = function () {
    if (!_editorState.open) return;

    // If there are unsaved changes, confirm before closing.
    if (_editorState.dirty && !_editorState.readonly) {
        var msg = t('Discard unsaved changes?');
        showConfirm(
            t('Unsaved changes'),
            msg,
            t('Discard'),
            function () {
                _editorHardClose();
            },
            false,
            null
        );
        return;
    }
    _editorHardClose();
};

function _editorHardClose() {
    _editorState.open = false;
    _editorState.path = null;
    clearTimeout(_editorDebounce);
    clearTimeout(_editorFooterDebounce);
    if (_editorEls.view) {
        _editorEls.view.classList.remove('open');
        _editorEls.view.classList.remove('readonly');
    }
    if (_editorEls.input) _editorEls.input.disabled = true;
    // Remove editor deep-link from hash if present
    var h = window.location.hash || '';
    var idx = h.indexOf('!edit');
    if (idx !== -1) {
        var clean = h.substring(0, idx);
        try { history.replaceState({}, '', clean || '#/'); } catch (e) { }
    }
    // Refresh the file list in case size/mtime changed after a save.
    loadFiles();
}

window.editorIsOpen = function () { return _editorState.open; };

window.editorSave = function () {
    if (_editorState.saving || _editorState.readonly || !_editorState.path) return;
    _editorState.saving = true;
    var btn = _editorEls.saveBtn;
    if (btn) btn.disabled = true;
    var status = _editorEls.status;
    if (status) status.textContent = t('Saving...');

    api('POST', '/api/save', {
        path: _editorState.path,
        content: _editorState.content
    }).then(function () {
        _editorState.saving = false;
        _editorState.originalContent = _editorState.content;
        _editorState.dirty = false;
        if (btn) btn.disabled = false;
        if (status) status.textContent = '';
        _editorUpdateFooter();
        showToast(t('Saved successfully'), 'success');
    }).catch(function (err) {
        _editorState.saving = false;
        if (btn) btn.disabled = false;
        if (status) status.textContent = err.message || t('Save failed:');
        showToast((t('Save failed:') + ' ' + (err.message || '')), 'error');
    });
};

// Keyboard input handler: update state content + live highlight.
function _editorOnInput() {
    if (!_editorState.open) return;
    _editorState.content = _editorEls.input.value;
    _editorState.dirty = _editorState.content !== _editorState.originalContent;
    _editorQueueFooter();
    _editorResize();
    _editorQueueHighlight();
}

// Tab inserts spaces (default focus-traversal is undesirable in a code
// editor). A full selection could later be re-indented; for now we insert
// four spaces at the caret, replacing any selection.
function _editorOnKeydown(e) {
    if (!_editorState.open || _editorState.readonly) return;
    if (e.key === 'Tab') {
        e.preventDefault();
        var ta = _editorEls.input;
        var start = ta.selectionStart;
        var end = ta.selectionEnd;
        var val = ta.value;
        ta.value = val.substring(0, start) + '    ' + val.substring(end);
        ta.selectionStart = ta.selectionEnd = start + 4;
        _editorOnInput();
    } else if ((e.metaKey || e.ctrlKey) && e.key === 's') {
        e.preventDefault();
        if (!_editorState.readonly) editorSave();
    }
}

// Wire up DOM events once.
function _editorBind() {
    _editorCacheEls();
    if (!_editorEls.view || _editorEls.view._filesyncEditorBound) return;
    _editorEls.view._filesyncEditorBound = true;

    if (_editorEls.input) {
        _editorEls.input.addEventListener('input', _editorOnInput);
        _editorEls.input.addEventListener('keydown', _editorOnKeydown);
    }
}

// Call after DOM ready.
function initEditor() {
    _editorBind();
}
