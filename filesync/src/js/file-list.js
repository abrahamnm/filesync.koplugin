    // ===== Navigation =====
    // Internal navigation: sets state and loads files WITHOUT pushing history
    function _navigateInternal(path) {
        currentPath = path || '/';
        currentFilter = '';
        document.getElementById('searchInput').value = '';
        loadFiles();
    }

    // Root of a path: "/" for the internal storage, "/@<id>" for another storage
    // location the server reported (and "/@internal" for the internal one when
    // spelled out). Paths under an unknown "@name" are ordinary folders.
    function getRootOf(path) {
        var match = /^\/(@[^\/]+)(?=\/|$)/.exec(path || '');
        if (match) {
            for (var i = 0; i < availableRoots.length; i++) {
                if ('@' + availableRoots[i].id === match[1]) return '/' + match[1];
            }
        }
        return '/';
    }

    function isRootPath(path) {
        var normalized = (path || '/').replace(/\/+$/, '') || '/';
        return normalized === '/' || normalized === getRootOf(normalized);
    }

    function getParentPath(path) {
        path = path || '/';
        var normalized = path.replace(/\/+$/, '') || '/';
        if (isRootPath(normalized)) return normalized;
        var lastSlash = normalized.lastIndexOf('/');
        return lastSlash > 0 ? normalized.substring(0, lastSlash) : '/';
    }

    function updateParentNav() {
        var btn = document.getElementById('btnParentNav');
        if (!btn) return;
        var atRoot = isRootPath(currentPath);
        btn.classList.toggle('hidden', atRoot);
        btn.disabled = atRoot;
    }

    window.navigateUp = function() {
        if (isRootPath(currentPath)) return;
        navigate(getParentPath(currentPath));
    };

    // Public navigate: updates state and pushes a history entry
    window.navigate = function(path) {
        path = path || '/';
        _navigateInternal(path);
        // Only push if the hash actually changed (decode to handle %20 etc.)
        var currentHash;
        try { currentHash = decodeURIComponent(window.location.hash); } catch(e) { currentHash = window.location.hash; }
        if (currentHash !== '#' + path) {
            history.pushState({path: path}, '', '#' + encodeURI(path));
        }
    };

    // A request failed while an SD card folder is shown: if the server no
    // longer lists the card (it was removed), go back to the internal storage.
    // The caller still shows its own error notification. replaceState so that
    // "back" does not return to the missing card.
    var _sdCheckRunning = false;
    window.checkSdCard = function() {
        if (_sdCheckRunning || !/^\/@sd(\/|$)/.test(currentPath || '')) return;
        _sdCheckRunning = true;
        fetch('/api/files?' + new URLSearchParams({path: '/'}))
            .then(function(res) { return res.json(); })
            .then(function(data) {
                var roots = (data && data.roots) || [];
                for (var i = 0; i < roots.length; i++) {
                    if (roots[i].id === 'sd') return;
                }
                history.replaceState({path: '/'}, '', '#/');
                _navigateInternal('/');
            })
            .catch(function() { /* keep the error as shown */ })
            .then(function() { _sdCheckRunning = false; });
    };

    // Title link: open KOReader's home folder (which may be on the SD card),
    // like loading the bare URL does; the internal root when home is unset,
    // outside every storage location, or the request fails.
    window.goHome = function() {
        fetch('/api/home')
            .then(function(res) { return res.json(); })
            .then(function(data) {
                navigate(data && typeof data.home === 'string' && data.home ? data.home : '/');
            })
            .catch(function() { navigate('/'); });
    };

    async function loadFiles() {
        var list = document.getElementById('fileList');
        list.innerHTML = '<div class="loading"><div class="spinner"></div><div class="loading-text">' + escapeHtml(t('Loading...')) + '</div></div>';

        try {
            var params = new URLSearchParams({
                path: currentPath,
                sort: currentSort,
                order: currentOrder,
                filter: currentFilter
            });
            var data = await api('GET', '/api/files?' + params);
            renderBreadcrumbs(data.breadcrumbs, data.roots);
            renderFiles(data.entries);
            updateParentNav();
        } catch (err) {
            currentEntries = [];
            list.innerHTML = '<div class="empty-state">' + icons.empty +
                '<div class="empty-state-text">' + escapeHtml(t('Failed to load files')) + '</div>' +
                '<div class="empty-state-sub">' + escapeHtml(err.message) + '</div></div>';
            updateViewModeUI();
            updateParentNav();
            showToast(err.message, 'error');
        }
    }

    function rootLabel(id) {
        if (id === 'internal') return t('Internal storage');
        if (id === 'sd') return t('SD card');
        return id;
    }

    // With several storage locations the first breadcrumb is split in two:
    // the storage icon with an arrow opens a selector that switches location,
    // and the location name next to it is an ordinary breadcrumb that leads
    // back to the root of the current location. With a single location it
    // stays the plain "Home" item.
    function renderRootSelector(crumb, isLast) {
        var currentRoot = crumb.root;
        var options = '';
        for (var i = 0; i < availableRoots.length; i++) {
            var root = availableRoots[i];
            options += '<option value="' + escapeAttr(root.path) + '"' +
                (root.id === currentRoot ? ' selected' : '') + '>' +
                escapeHtml(rootLabel(root.id)) + '</option>';
        }
        var label = escapeHtml(t('Storage location'));
        var switcher = '<span class="root-switch">' +
            (currentRoot === 'sd' ? icons.sdcard : icons.home) +
            '<select class="root-select" onchange="navigate(this.value)" title="' +
            label + '" aria-label="' + label + '">' + options + '</select></span>';
        var name = '<span class="breadcrumb-item' + (isLast ? ' active' : '') + '"' +
            (isLast ? '' : ' onclick="navigate(\'' + escapeAttr(crumb.path) + '\')"') + '>' +
            escapeHtml(rootLabel(currentRoot)) + '</span>';
        return switcher + name;
    }

    function renderBreadcrumbs(crumbs, roots) {
        var el = document.getElementById('breadcrumbs');
        availableRoots = roots || [];
        if (!crumbs || !crumbs.length) { el.innerHTML = ''; return; }
        var html = '';
        for (var i = 0; i < crumbs.length; i++) {
            if (i === 0 && crumbs[0].root && availableRoots.length > 1) {
                html += renderRootSelector(crumbs[0], crumbs.length === 1);
                continue;
            }
            if (i > 0) html += '<span class="breadcrumb-sep">/</span>';
            var isLast = i === crumbs.length - 1;
            var displayName = crumbs[i].name;
            var classes = 'breadcrumb-item' + (isLast ? ' active' : '');
            var attrs = isLast ? '' : ' onclick="navigate(\'' + escapeAttr(crumbs[i].path) + '\')"';
            if (displayName === "Home") {
                html += '<span class="' + classes + ' breadcrumb-home"' + attrs + ' title="' + escapeHtml(t('Home')) + '" aria-label="' + escapeHtml(t('Home')) + '">' +
                    icons.home + '<span class="breadcrumb-home-label">' + escapeHtml(t('Home')) + '</span></span>';
                continue;
            }
            html += '<span class="' + classes + '"' + attrs + '>' + escapeHtml(displayName) + '</span>';
        }
        el.innerHTML = html;
    }

    function renderFiles(entries) {
        currentEntries = entries || [];
        var list = document.getElementById('fileList');
        if (!entries || entries.length === 0) {
            list.innerHTML = '<div class="empty-state">' + icons.empty +
                '<div class="empty-state-text">' + escapeHtml(t('This folder is empty')) + '</div>' +
                '<div class="empty-state-sub">' + escapeHtml(t('Upload files or create a new folder')) + '</div></div>';
            updateViewModeUI();
            return;
        }

        var html = '';
        for (var idx = 0; idx < entries.length; idx++) {
            var entry = entries[idx];
            var typeClass = resolveEntryTypeClass(entry);
            var icon = icons[typeClass] || icons.file;
            var date = entry.modified ? formatDate(entry.modified) : '';
            var size = entry.is_dir ? '' : (entry.size_formatted || '');
            var meta = [size, date].filter(Boolean).join(' &middot; ');
            var tableSize = entry.is_dir ? '' : size;
            var tableDate = date || '';
            var displayParts = entry.is_dir ? { baseName: entry.name, extensionLabel: '' } : getFileDisplayParts(entry.name);
            var typeLabel = entry.is_dir ? t('Folder label') : (displayParts.extensionLabel || t('Unknown'));
            var tableTypeLabel = entry.is_dir ? t('Folder label') : (displayParts.extensionLabel || t('Unknown'));
            var itemClass = 'file-item ' + (entry.is_dir ? 'is-dir' : 'is-file');
            if (entry.name && entry.name.charAt(0) === '.') itemClass += ' is-hidden';

            html += '<div class="' + itemClass + '" onclick="onFileClick(event, ' + (entry.is_dir ? 'true' : 'false') + ', \'' + escapeAttr(entry.path) + '\')">';
            html += '<div class="file-main">';
            html += '<div class="file-icon ' + typeClass + '">' + icon + '</div>';
            html += '<div class="file-info">';
            html += '<div class="file-name">' + escapeHtml(displayParts.baseName) + '</div>';
            html += '<div class="file-meta">';
            if (typeLabel) html += '<span>' + escapeHtml(typeLabel) + '</span>';
            if (meta) html += '<span>' + meta + '</span>';
            html += '</div></div>';
            html += '</div>';
            html += '<div class="file-table-cell file-table-size">' + escapeHtml(tableSize) + '</div>';
            html += '<div class="file-table-cell file-table-date">' + escapeHtml(tableDate) + '</div>';
            html += '<div class="file-table-cell file-table-type">' + escapeHtml(tableTypeLabel) + '</div>';
            if (entry.is_dir) {
                html += '<div class="file-actions">';
                html += '<button class="btn-icon" onclick="event.stopPropagation(); renameItem(\'' + escapeAttr(entry.path) + '\', \'' + escapeAttr(entry.name) + '\')" title="' + escapeHtml(t('Rename')) + '">' + icons.rename + '</button>';
                html += '<button class="btn-icon" onclick="event.stopPropagation(); deleteItem(\'' + escapeAttr(entry.path) + '\', \'' + escapeAttr(entry.name) + '\', true, false, ' + (entry.is_empty ? 'true' : 'false') + ')" title="' + escapeHtml(t('Delete')) + '">' + icons.trash + '</button>';
                html += '</div>';
            } else {
                // Row list keeps the strict allow-list (known text type + size
                // cap); unknown or oversized files are still editable from the
                // detail view. The server content-sniffs as a backstop.
                var rowIsEditable = isPotentiallyEditableFile(entry.name, entry.size);
                html += '<div class="file-actions' + (rowIsEditable ? '' : ' file-actions-chevron') + '">';
                if (rowIsEditable) {
                    html += '<button class="btn-icon" onclick="event.stopPropagation(); openEditor(\'' + escapeAttr(entry.path) + '\', \'' + escapeAttr(entry.name) + '\')" title="' + escapeHtml(t('Edit')) + '">' + icons.edit + '</button>';
                }
                html += '<span class="file-chevron"><svg viewBox="0 0 24 24" width="16" height="16" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round"><polyline points="9 18 15 12 9 6"/></svg></span>';
                html += '</div>';
            }
            html += '</div>';
        }
        list.innerHTML = html;
        updateViewModeUI();
    }

    window.onFileClick = function(event, isDir, path) {
        if (isDir) {
            navigate(path);
        } else {
            showFileDetail(path);
        }
    };

    // ===== Sort & Filter =====
    window.onSortChange = function() {
        var val = document.getElementById('sortSelect').value;
        var parts = val.split('-');
        currentSort = parts[0];
        currentOrder = parts[1] || 'asc';
        loadFiles();
    };

    window.onFilterChange = function() {
        clearTimeout(filterTimer);
        filterTimer = setTimeout(function() {
            currentFilter = document.getElementById('searchInput').value;
            loadFiles();
        }, 250);
    };
