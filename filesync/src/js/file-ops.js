    // ===== File Operations =====
    window.downloadFile = function(path) {
        var a = document.createElement('a');
        a.href = '/api/download?path=' + encodeURIComponent(path);
        a.download = '';
        document.body.appendChild(a);
        a.click();
        document.body.removeChild(a);
    };

    window.renameItem = function(path, oldName) {
        showModal(t('Rename'), oldName, t('Rename'), async function(newName) {
            if (!newName || newName === oldName) return;
            try {
                var parentPath = path.substring(0, path.lastIndexOf('/')) || '/';
                var newPath = parentPath + '/' + newName;
                await api('POST', '/api/rename', { old_path: path, new_path: newPath });
                showToast(t('Renamed successfully'), 'success');
                loadFiles();
            } catch (err) {
                showToast(t('Rename failed:') + ' ' + err.message, 'error');
            }
        });
    };

    window.deleteItem = async function(path, name, isDir, hasSdr, isDirEmpty) {
        var titleStr = isDir ? (isDirEmpty ? t('Delete empty folder') : t('Delete folder')) : t('Delete file');
        var msgStr = t('Are you sure you want to delete') + ' "' + escapeHtml(name) + '"?';
        var showSdrCheckbox = !isDir && hasSdr;
        var warningStr = '';
        if (isDir && !isDirEmpty) {
            try {
                var info = await api('GET', '/api/dirinfo?path=' + encodeURIComponent(path));
                warningStr = t('This directory contains {n} files. All files will be permanently deleted.').replace('{n}', info.file_count);
            } catch (err) {
                warningStr = t('This will delete all contents inside.');
            }
        }
        showConfirm(
            titleStr,
            msgStr,
            t('Delete'),
            async function() {
                try {
                    var body = { path: path };
                    if (showSdrCheckbox) {
                        body.delete_sdr = document.getElementById('confirmSdrCheckbox').checked;
                    }
                    await api('POST', '/api/delete', body);
                    showToast(t('Deleted successfully'), 'success');
                    loadFiles();
                } catch (err) {
                    showToast(t('Delete failed:') + ' ' + err.message, 'error');
                }
            },
            showSdrCheckbox,
            warningStr
        );
    };

    window.showNewFolderModal = function() {
        showModal(t('New Folder'), '', t('Create'), async function(name) {
            if (!name) return;
            try {
                var newPath = (currentPath === '/' ? '' : currentPath) + '/' + name;
                await api('POST', '/api/mkdir', { path: newPath });
                showToast(t('Folder created'), 'success');
                loadFiles();
            } catch (err) {
                showToast(t('Failed to create folder:') + ' ' + err.message, 'error');
            }
        });
    };

    // ===== File Detail View =====
    // Internal detail show: renders the detail view WITHOUT pushing history
    function _showDetailInternal(path) {
        var entry = null;
        for (var i = 0; i < currentEntries.length; i++) {
            if (currentEntries[i].path === path) {
                entry = currentEntries[i];
                break;
            }
        }
        if (!entry) return;
        currentDetailEntry = entry;

        var detail = document.getElementById('fileDetail');
        var coverEl = document.getElementById('detailCover');
        var titleEl = document.getElementById('detailTitle');
        var authorEl = document.getElementById('detailAuthor');
        var infoEl = document.getElementById('detailInfo');
        var actionsEl = document.getElementById('detailActions');

        // Show the detail overlay and lock body scroll (iOS needs position:fixed)
        detail.classList.add('open');
        detail.style.display = 'block';
        document.body.dataset.scrollY = window.scrollY;
        document.body.style.position = 'fixed';
        document.body.style.top = '-' + window.scrollY + 'px';
        document.body.style.left = '0';
        document.body.style.right = '0';
        document.body.style.overflow = 'hidden';

        // Determine if this is an image file
        var imageExts = {jpg:1, jpeg:1, png:1, gif:1, webp:1};
        var fileExt = (entry.name.split('.').pop() || '').toLowerCase();
        var isImage = imageExts[fileExt] === 1;

        var imagePreviewEl = document.getElementById('detailImagePreview');

        if (isImage) {
            // Show image preview, hide book cover
            coverEl.style.display = 'none';
            imagePreviewEl.style.display = 'flex';
            imagePreviewEl.innerHTML = '<div class="cover-spinner"></div>';
            var previewImg = document.createElement('img');
            previewImg.src = '/api/download?path=' + encodeURIComponent(path) + '&preview=1';
            previewImg.alt = t('Image preview');
            previewImg.onload = function() {
                imagePreviewEl.innerHTML = '';
                imagePreviewEl.appendChild(previewImg);
            };
            previewImg.onerror = function() {
                imagePreviewEl.innerHTML = buildCoverPlaceholder('image');
            };
        } else {
            // Hide image preview, show book cover
            imagePreviewEl.style.display = 'none';
            imagePreviewEl.innerHTML = '';
            coverEl.style.display = '';
            // Show loading spinner in cover area
            coverEl.innerHTML = '<div class="cover-spinner"></div>';
        }

        // Set title from filename (without extension)
        var nameWithoutExt = entry.name.replace(/\.[^.]+$/, '') || entry.name;
        titleEl.textContent = nameWithoutExt;

        // Clear author initially
        authorEl.textContent = '';
        authorEl.style.display = 'none';

        // File type info
        var typeClass = entry.type || 'file';
        var ext = entry.name.split('.').pop().toUpperCase();
        var dateStr = entry.modified ? formatDate(entry.modified) : t('Unknown');
        var sizeStr = entry.size_formatted || '0 B';

        var infoHtml = '';
        infoHtml += '<div class="detail-info-row"><span class="detail-info-label">' + escapeHtml(t('File type')) + '</span><span class="detail-info-value">' + escapeHtml(ext) + '</span></div>';
        infoHtml += '<div class="detail-info-row"><span class="detail-info-label">' + escapeHtml(t('Size')) + '</span><span class="detail-info-value">' + escapeHtml(sizeStr) + '</span></div>';
        infoHtml += '<div class="detail-info-row"><span class="detail-info-label">' + escapeHtml(t('Modified')) + '</span><span class="detail-info-value">' + escapeHtml(dateStr) + '</span></div>';
        infoEl.innerHTML = infoHtml;

        // Build action buttons
        var actHtml = '';
        actHtml += '<button class="btn btn-primary" onclick="detailDownload()">' + icons.download + '<span>' + escapeHtml(t('Download')) + '</span></button>';
        actHtml += '<button class="btn btn-secondary" onclick="detailRename()">' + icons.rename + '<span>' + escapeHtml(t('Rename')) + '</span></button>';
        actHtml += '<button class="btn btn-danger" onclick="detailDelete()">' + icons.trash + '<span>' + escapeHtml(t('Delete')) + '</span></button>';
        actionsEl.innerHTML = actHtml;

        // For image files, skip metadata fetch (no book metadata to show)
        if (isImage) {
            coverEl.innerHTML = '';
            coverEl.style.display = 'none';
        } else {
            // Fetch metadata asynchronously for non-image files
            fetch('/api/metadata?path=' + encodeURIComponent(path))
                .then(function(res) { return res.json(); })
                .then(function(meta) {
                    if (!currentDetailEntry || currentDetailEntry.path !== path) return;

                    // Update title if metadata has one
                    if (meta.title) {
                        titleEl.textContent = meta.title;
                    }

                    // Show author if available
                    if (meta.author) {
                        authorEl.textContent = meta.author;
                        authorEl.style.display = 'block';
                    }

                    // Handle cover image
                    if (meta.has_cover) {
                        var img = document.createElement('img');
                        img.src = '/api/cover?path=' + encodeURIComponent(path);
                        img.alt = 'Book cover';
                        img.onerror = function() {
                            coverEl.innerHTML = buildCoverPlaceholder(typeClass);
                        };
                        coverEl.innerHTML = '';
                        coverEl.appendChild(img);
                    } else {
                        coverEl.innerHTML = buildCoverPlaceholder(typeClass);
                    }
                })
                .catch(function() {
                    if (!currentDetailEntry || currentDetailEntry.path !== path) return;
                    coverEl.innerHTML = buildCoverPlaceholder(typeClass);
                });
        }
    }

    // Public showFileDetail: shows detail and pushes a history entry
    window.showFileDetail = function(path) {
        _showDetailInternal(path);
        var currentHash;
        try { currentHash = decodeURIComponent(window.location.hash); } catch(e) { currentHash = window.location.hash; }
        var hashTarget = '#' + path + '!detail';
        if (currentHash !== hashTarget) {
            history.pushState({path: path, detail: true}, '', '#' + encodeURI(path) + '!detail');
        }
    };

    function buildCoverPlaceholder(typeClass) {
        var icon = icons[typeClass] || icons.file;
        return '<div class="cover-placeholder">' + icon + '</div>';
    }

    // Internal hide detail: does the DOM work without touching history
    function _hideDetailInternal() {
        var detail = document.getElementById('fileDetail');
        detail.classList.remove('open');
        detail.style.display = 'none';
        var scrollY = parseInt(document.body.dataset.scrollY || '0', 10);
        document.body.style.position = '';
        document.body.style.top = '';
        document.body.style.left = '';
        document.body.style.right = '';
        document.body.style.overflow = '';
        window.scrollTo(0, scrollY);
        currentDetailEntry = null;
    }

    // Public hideFileDetail: called by the Back button — uses history.back()
    // so the popstate handler will call _hideDetailInternal
    window.hideFileDetail = function() {
        history.back();
    };

    window.detailDownload = function() {
        if (currentDetailEntry) {
            showToast(t('Downloading') + ' ' + currentDetailEntry.name, 'info');
            downloadFile(currentDetailEntry.path);
        }
    };

    window.detailRename = function() {
        if (!currentDetailEntry) return;
        var entry = currentDetailEntry;
        var fullName = entry.name;
        var dotIndex = fullName.lastIndexOf('.');
        var namePart = dotIndex > 0 ? fullName.substring(0, dotIndex) : fullName;
        var extPart = dotIndex > 0 ? fullName.substring(dotIndex) : '';

        // Show the modal with extension suffix
        var overlay = document.getElementById('modalOverlay');
        var titleElem = document.getElementById('modalTitle');
        var inputElem = document.getElementById('modalInput');
        var confirmBtn = document.getElementById('modalConfirm');

        titleElem.textContent = t('Rename');
        confirmBtn.textContent = t('Rename');

        // Wrap input with extension suffix
        var inputParent = inputElem.parentNode;
        var hasExtWrapper = inputParent.classList.contains('modal-input-with-ext');
        if (extPart) {
            if (!hasExtWrapper) {
                var wrapper = document.createElement('div');
                wrapper.className = 'modal-input-with-ext';
                inputParent.insertBefore(wrapper, inputElem);
                wrapper.appendChild(inputElem);
                var extSpan = document.createElement('span');
                extSpan.className = 'detail-ext-suffix';
                extSpan.id = 'modalExtSuffix';
                wrapper.appendChild(extSpan);
            }
            document.getElementById('modalExtSuffix').textContent = extPart;
        } else if (hasExtWrapper) {
            // Remove the wrapper if no extension
            var wrapper2 = inputParent;
            var grandParent = wrapper2.parentNode;
            grandParent.insertBefore(inputElem, wrapper2);
            wrapper2.remove();
        }

        inputElem.value = namePart;
        overlay.classList.add('open');
        setTimeout(function() {
            inputElem.focus();
            inputElem.select();
        }, 100);

        modalCallback = async function(newName) {
            if (!newName || (newName + extPart) === fullName) {
                restoreModalInput();
                return;
            }
            var finalName = newName + extPart;
            try {
                var parentPath = entry.path.substring(0, entry.path.lastIndexOf('/')) || '/';
                var newPath = parentPath + '/' + finalName;
                await api('POST', '/api/rename', { old_path: entry.path, new_path: newPath });
                showToast(t('Renamed successfully'), 'success');
                restoreModalInput();
                _hideDetailInternal();
                history.replaceState({path: currentPath}, '', '#' + encodeURI(currentPath));
                loadFiles();
            } catch (err) {
                showToast(t('Rename failed:') + ' ' + err.message, 'error');
                restoreModalInput();
            }
        };
    };

    window.detailDelete = function() {
        if (!currentDetailEntry) return;
        var entry = currentDetailEntry;
        var showSdrCheckbox = !entry.is_dir && entry.has_sdr;
        showConfirm(
            t('Delete file'),
            t('Are you sure you want to delete') + ' "' + escapeHtml(entry.name) + '"?',
            t('Delete'),
            async function() {
                try {
                    var body = { path: entry.path };
                    if (showSdrCheckbox) {
                        body.delete_sdr = document.getElementById('confirmSdrCheckbox').checked;
                    }
                    await api('POST', '/api/delete', body);
                    showToast(t('Deleted successfully'), 'success');
                    _hideDetailInternal();
                    history.replaceState({path: currentPath}, '', '#' + encodeURI(currentPath));
                    loadFiles();
                } catch (err) {
                    showToast(t('Delete failed:') + ' ' + err.message, 'error');
                }
            },
            showSdrCheckbox
        );
    };
