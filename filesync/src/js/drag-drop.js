    // ===== Upload =====
    window.toggleUploadZone = function() {
        uploadZoneVisible = !uploadZoneVisible;
        document.getElementById('dropzone').classList.toggle('visible', uploadZoneVisible);
    };

    // The plugin's HTTP server handles a single request at a time, so every
    // upload path funnels through one queue: a second drop landing mid
    // transfer, or loose files racing a folder, would just stall on timeouts.
    var uploadQueue = Promise.resolve();

    function enqueueUpload(task) {
        var next = uploadQueue.then(task);
        // One failure must not poison the queue for later uploads.
        uploadQueue = next.catch(function() {});
        return next;
    }

    // jobs: [{file}] for a plain file, [{tree}] for a whole folder tree.
    async function runUploadJobs(jobs) {
        for (var i = 0; i < jobs.length; i++) {
            if (jobs[i].tree) {
                await uploadTree(jobs[i].tree);
            } else {
                await uploadFile(jobs[i].file);
            }
        }
    }

    window.handleFileSelect = function(files) {
        if (!files || files.length === 0) return;
        var jobs = [];
        for (var fi = 0; fi < files.length; fi++) {
            jobs.push({ file: files[fi] });
        }
        enqueueUpload(function() { return runUploadJobs(jobs); });
        document.getElementById('fileInput').value = '';
    };

    // Folder picker (<input webkitdirectory>): every File carries a
    // webkitRelativePath like "myplugin/sub/main.lua". Group them by top-level
    // folder so each selected folder gets a single progress row.
    window.handleFolderSelect = function(files) {
        var input = document.getElementById('folderInput');
        if (files && files.length > 0) {
            // Object.create(null), not {}: a folder named "constructor" or
            // "toString" would otherwise hit the inherited Object.prototype
            // member and never get its own entry.
            var trees = Object.create(null);
            var jobs = [];
            for (var i = 0; i < files.length; i++) {
                var file = files[i];
                var relPath = file.webkitRelativePath || file.name;
                var slash = relPath.indexOf('/');
                if (slash <= 0) {
                    // No folder component — treat it as a plain file upload
                    jobs.push({ file: file });
                    continue;
                }
                var root = relPath.substring(0, slash);
                if (!trees[root]) {
                    trees[root] = { name: root, files: [], dirs: [root] };
                    jobs.push({ tree: trees[root] });
                }
                trees[root].files.push({ file: file, relPath: relPath });
            }
            enqueueUpload(function() { return runUploadJobs(jobs); });
        }
        if (input) input.value = '';
    };

    // Folder picking needs webkitdirectory; hide the CTA where it is missing
    // (notably Android browsers) rather than opening a picker that can't
    // select a folder. Drag and drop still covers desktop browsers.
    if (!('webkitdirectory' in document.createElement('input'))) {
        var folderCta = document.getElementById('btnUploadFolderCta');
        if (folderCta) folderCta.style.display = 'none';
    }

    // ===== Upload progress rows =====
    function newUploadId() {
        return 'upload-' + Date.now() + '-' + Math.random().toString(36).substring(2, 8);
    }

    function createUploadItem(id, name, typeClass) {
        var icon = icons[typeClass] || icons.file;
        var item = document.createElement('div');
        item.className = 'upload-item';
        item.id = id;
        item.innerHTML = '<div class="upload-item-main">' +
            '<span class="upload-item-icon ' + typeClass + '" aria-hidden="true">' + icon + '</span>' +
            '<span class="upload-item-name">' + escapeHtml(name) + '</span>' +
            '</div>' +
            '<div class="progress-bar"><div class="progress-bar-fill" id="' + id + '-bar"></div></div>' +
            '<span class="upload-item-status" id="' + id + '-status">0%</span>';
        document.getElementById('uploadProgress').prepend(item);
    }

    function setUploadProgress(id, fraction, statusText) {
        var pct = Math.max(0, Math.min(100, Math.round(fraction * 100)));
        var bar = document.getElementById(id + '-bar');
        var status = document.getElementById(id + '-status');
        if (bar) bar.style.width = pct + '%';
        if (status) status.textContent = statusText || (pct + '%');
    }

    // Terminal state for a row: successful rows fade out, failed ones stay put
    // so the user can read what went wrong.
    function finishUploadItem(id, ok, statusText) {
        var bar = document.getElementById(id + '-bar');
        var status = document.getElementById(id + '-status');
        if (bar) { bar.style.width = '100%'; bar.classList.add(ok ? 'complete' : 'error'); }
        if (status) { status.textContent = statusText; status.classList.add(ok ? 'success' : 'error'); }
        if (!ok) return;
        setTimeout(function() {
            var el = document.getElementById(id);
            if (el) el.remove();
        }, 3000);
    }

    // ===== Transfer =====
    /**
     * POST one file to destPath. onProgress receives bytes uploaded so far.
     * Rejects with an Error carrying the server's message when it has one.
     */
    function sendUpload(file, destPath, onProgress) {
        var formData = new FormData();
        formData.append('file', file);

        var xhr = new XMLHttpRequest();
        xhr.open('POST', '/api/upload?path=' + encodeURIComponent(destPath));

        if (onProgress) {
            xhr.upload.onprogress = function(e) {
                if (e.lengthComputable) onProgress(e.loaded, e.total);
            };
        }

        return new Promise(function(resolve, reject) {
            xhr.onload = function() {
                if (xhr.status >= 200 && xhr.status < 300) {
                    resolve();
                } else {
                    try {
                        var d = JSON.parse(xhr.responseText);
                        reject(new Error(d.error || t('Upload failed:')));
                    } catch (e) {
                        reject(new Error(t('Upload failed:')));
                    }
                }
            };
            xhr.onerror = function() { reject(new Error(t('Network error'))); };
            xhr.send(formData);
        });
    }

    async function uploadFile(file) {
        var id = newUploadId();
        createUploadItem(id, file.name, getTypeClassFromFilename(file && file.name) || 'file');

        try {
            await sendUpload(file, currentPath, function(loaded, total) {
                setUploadProgress(id, total ? loaded / total : 0);
            });
            finishUploadItem(id, true, t('Done'));
            showToast(file.name + ' ' + t('uploaded'), 'success');
            loadFiles();
        } catch (err) {
            finishUploadItem(id, false, t('Failed'));
            showToast(t('Upload failed:') + ' ' + err.message, 'error');
        }
    }

    /**
     * Upload a whole folder tree into the current directory.
     * tree: {name, files: [{file, relPath}], dirs: [relPath]} where every
     * relPath is relative to the current directory and starts with tree.name.
     */
    async function uploadTree(tree) {
        var id = newUploadId();
        createUploadItem(id, tree.name, 'dir');

        var basePath = currentPath === '/' ? '' : currentPath;
        var totalFiles = tree.files.length;

        // Lay down the directory tree first so every file has somewhere to land.
        var dirs = collectUploadDirs(tree);
        for (var d = 0; d < dirs.length; d++) {
            try {
                await api('POST', '/api/mkdir', { path: basePath + '/' + dirs[d], recursive: true });
            } catch (err) {
                finishUploadItem(id, false, t('Failed'));
                showToast(t('Failed to create folder:') + ' ' + err.message, 'error');
                // Earlier mkdirs in this loop may already have landed.
                loadFiles();
                return;
            }
        }

        var totalBytes = 0;
        for (var b = 0; b < totalFiles; b++) totalBytes += tree.files[b].file.size;

        // One file at a time: the plugin's HTTP server handles a single request
        // at a time, so firing a whole folder at once just stalls on timeouts.
        var doneBytes = 0;
        var failed = 0;
        var lastError = null;
        for (var i = 0; i < totalFiles; i++) {
            var entry = tree.files[i];
            var slash = entry.relPath.lastIndexOf('/');
            var destPath = basePath + '/' + entry.relPath.substring(0, slash);
            var countText = (i + 1) + '/' + totalFiles;
            try {
                await sendUpload(entry.file, destPath, function(loaded) {
                    setUploadProgress(id, totalBytes ? (doneBytes + loaded) / totalBytes : 0, countText);
                });
            } catch (err) {
                failed++;
                lastError = err;
            }
            doneBytes += entry.file.size;
            setUploadProgress(id, totalBytes ? doneBytes / totalBytes : 0, countText);
        }

        if (failed === 0) {
            finishUploadItem(id, true, t('Done'));
            showToast(tree.name + ' ' + t('uploaded'), 'success');
        } else {
            finishUploadItem(id, false, t('Failed'));
            var summary = t('{n} of {m} files failed to upload')
                .replace('{n}', failed).replace('{m}', totalFiles);
            showToast(summary + (lastError ? ' — ' + lastError.message : ''), 'error');
        }
        loadFiles();
    }

    /**
     * Directories to create for a tree, ancestors of other entries removed —
     * a recursive mkdir on the deepest path creates them anyway.
     */
    function collectUploadDirs(tree) {
        var seen = Object.create(null);
        var dirs = [];
        function add(dir) {
            if (dir && !seen[dir]) { seen[dir] = true; dirs.push(dir); }
        }
        for (var i = 0; i < tree.dirs.length; i++) add(tree.dirs[i]);
        for (var j = 0; j < tree.files.length; j++) {
            var rel = tree.files[j].relPath;
            var slash = rel.lastIndexOf('/');
            if (slash > 0) add(rel.substring(0, slash));
        }
        dirs.sort();
        var leaves = [];
        for (var k = 0; k < dirs.length; k++) {
            var next = dirs[k + 1];
            if (next && next.substring(0, dirs[k].length + 1) === dirs[k] + '/') continue;
            leaves.push(dirs[k]);
        }
        return leaves;
    }

    // ===== Drag and drop =====
    var dropzone = document.getElementById('dropzone');
    var dropContainer = document.getElementById('dropzoneContainer');

    // Dropped folders arrive as FileSystemEntry objects via the non-standard
    // but universally supported webkitGetAsEntry(); dataTransfer.files alone
    // cannot describe a directory.
    function entryToFile(entry) {
        return new Promise(function(resolve, reject) { entry.file(resolve, reject); });
    }

    // readEntries() returns at most 100 children per call and signals the end
    // with an empty batch, so it has to be drained in a loop.
    function readAllEntries(reader) {
        return new Promise(function(resolve, reject) {
            var all = [];
            (function readBatch() {
                reader.readEntries(function(batch) {
                    if (!batch || batch.length === 0) {
                        resolve(all);
                        return;
                    }
                    all = all.concat(Array.prototype.slice.call(batch));
                    readBatch();
                }, reject);
            })();
        });
    }

    async function walkEntry(entry, prefix, tree) {
        if (entry.isFile) {
            tree.files.push({ file: await entryToFile(entry), relPath: prefix + entry.name });
            return;
        }
        var dirPath = prefix + entry.name;
        tree.dirs.push(dirPath);
        var children = await readAllEntries(entry.createReader());
        for (var i = 0; i < children.length; i++) {
            await walkEntry(children[i], dirPath + '/', tree);
        }
    }

    async function handleDroppedEntries(entries) {
        for (var i = 0; i < entries.length; i++) {
            var entry = entries[i];
            if (entry.isFile) {
                try {
                    await uploadFile(await entryToFile(entry));
                } catch (err) {
                    showToast(t('Upload failed:') + ' ' + err.message, 'error');
                }
                continue;
            }
            var tree = { name: entry.name, files: [], dirs: [] };
            try {
                await walkEntry(entry, '', tree);
            } catch (err) {
                showToast(t('Upload failed:') + ' ' + entry.name, 'error');
                continue;
            }
            await uploadTree(tree);
        }
    }

    document.addEventListener('dragover', function(e) {
        e.preventDefault();
        if (!uploadZoneVisible) {
            uploadZoneVisible = true;
            dropzone.classList.add('visible');
        }
        dropzone.classList.add('active');
    });

    document.addEventListener('dragleave', function(e) {
        if (e.relatedTarget === null || !document.contains(e.relatedTarget)) {
            dropzone.classList.remove('active');
        }
    });

    document.addEventListener('drop', function(e) {
        e.preventDefault();
        dropzone.classList.remove('active');

        // dataTransfer.items is emptied as soon as this handler returns, so the
        // entries have to be pulled out synchronously before any await.
        var items = e.dataTransfer.items;
        var entries = [];
        if (items && items.length > 0 && typeof items[0].webkitGetAsEntry === 'function') {
            for (var i = 0; i < items.length; i++) {
                var entry = items[i].webkitGetAsEntry();
                if (entry) entries.push(entry);
            }
        }

        if (entries.length > 0) {
            enqueueUpload(function() { return handleDroppedEntries(entries); });
        } else if (e.dataTransfer.files.length > 0) {
            handleFileSelect(e.dataTransfer.files);
        }
    });
