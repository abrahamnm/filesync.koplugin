    // ===== Navigation =====
    // Internal navigation: sets state and loads files WITHOUT pushing history
    function _navigateInternal(path) {
        currentPath = path || '/';
        currentFilter = '';
        document.getElementById('searchInput').value = '';
        loadFiles();
    }

    function getParentPath(path) {
        path = path || '/';
        if (path === '/') return '/';
        var normalized = path.replace(/\/+$/, '') || '/';
        if (normalized === '/') return '/';
        var lastSlash = normalized.lastIndexOf('/');
        return lastSlash > 0 ? normalized.substring(0, lastSlash) : '/';
    }

    function updateParentNav() {
        var btn = document.getElementById('btnParentNav');
        if (!btn) return;
        var atRoot = currentPath === '/';
        btn.classList.toggle('hidden', atRoot);
        btn.disabled = atRoot;
    }

    window.navigateUp = function() {
        if (currentPath === '/') return;
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
            renderBreadcrumbs(data.breadcrumbs);
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

    function renderBreadcrumbs(crumbs) {
        var el = document.getElementById('breadcrumbs');
        if (!crumbs || !crumbs.length) { el.innerHTML = ''; return; }
        var html = '';
        for (var i = 0; i < crumbs.length; i++) {
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
                html += '<div class="file-actions file-actions-chevron"><span class="file-chevron"><svg viewBox="0 0 24 24" width="16" height="16" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round"><polyline points="9 18 15 12 9 6"/></svg></span></div>';
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
