    // ===== Upload =====
    window.toggleUploadZone = function() {
        uploadZoneVisible = !uploadZoneVisible;
        document.getElementById('dropzone').classList.toggle('visible', uploadZoneVisible);
    };

    window.handleFileSelect = function(files) {
        if (!files || files.length === 0) return;
        for (var fi = 0; fi < files.length; fi++) {
            uploadFile(files[fi]);
        }
        document.getElementById('fileInput').value = '';
    };

    async function uploadFile(file) {
        var container = document.getElementById('uploadProgress');
        var id = 'upload-' + Date.now() + '-' + Math.random().toString(36).substring(2, 8);
        var uploadTypeClass = getTypeClassFromFilename(file && file.name) || 'file';
        var uploadIcon = icons[uploadTypeClass] || icons.file;

        var item = document.createElement('div');
        item.className = 'upload-item';
        item.id = id;
        item.innerHTML = '<div class="upload-item-main">' +
            '<span class="upload-item-icon ' + uploadTypeClass + '" aria-hidden="true">' + uploadIcon + '</span>' +
            '<span class="upload-item-name">' + escapeHtml(file.name) + '</span>' +
            '</div>' +
            '<div class="progress-bar"><div class="progress-bar-fill" id="' + id + '-bar"></div></div>' +
            '<span class="upload-item-status" id="' + id + '-status">0%</span>';
        container.prepend(item);

        try {
            var formData = new FormData();
            formData.append('file', file);

            var xhr = new XMLHttpRequest();
            xhr.open('POST', '/api/upload?path=' + encodeURIComponent(currentPath));

            xhr.upload.onprogress = function(e) {
                if (e.lengthComputable) {
                    var pct = Math.round((e.loaded / e.total) * 100);
                    var bar = document.getElementById(id + '-bar');
                    var status = document.getElementById(id + '-status');
                    if (bar) bar.style.width = pct + '%';
                    if (status) status.textContent = pct + '%';
                }
            };

            await new Promise(function(resolve, reject) {
                xhr.onload = function() {
                    if (xhr.status >= 200 && xhr.status < 300) {
                        resolve();
                    } else {
                        try {
                            var d = JSON.parse(xhr.responseText);
                            reject(new Error(d.error || t('Upload failed:')));
                        } catch(e) {
                            reject(new Error(t('Upload failed:')));
                        }
                    }
                };
                xhr.onerror = function() { reject(new Error(t('Network error'))); };
                xhr.send(formData);
            });

            var bar = document.getElementById(id + '-bar');
            var status = document.getElementById(id + '-status');
            if (bar) { bar.style.width = '100%'; bar.classList.add('complete'); }
            if (status) { status.textContent = t('Done'); status.classList.add('success'); }
            showToast(file.name + ' ' + t('uploaded'), 'success');
            loadFiles();

            setTimeout(function() {
                var el = document.getElementById(id);
                if (el) el.remove();
            }, 3000);

        } catch (err) {
            var bar2 = document.getElementById(id + '-bar');
            var status2 = document.getElementById(id + '-status');
            if (bar2) { bar2.style.width = '100%'; bar2.classList.add('error'); }
            if (status2) { status2.textContent = t('Failed'); status2.classList.add('error'); }
            showToast(t('Upload failed:') + ' ' + err.message, 'error');
        }
    }

    // Drag and drop
    var dropzone = document.getElementById('dropzone');
    var dropContainer = document.getElementById('dropzoneContainer');

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
        if (e.dataTransfer.files.length > 0) {
            handleFileSelect(e.dataTransfer.files);
        }
    });
