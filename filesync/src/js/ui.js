    // ===== Helpers =====
    function escapeHtml(str) {
        if (!str) return '';
        return String(str).replace(/&/g, '&amp;').replace(/</g, '&lt;').replace(/>/g, '&gt;').replace(/"/g, '&quot;');
    }

    function escapeAttr(str) {
        if (!str) return '';
        return String(str).replace(/\\/g, '\\\\').replace(/'/g, "\\'").replace(/"/g, '&quot;');
    }

    function formatDate(timestamp) {
        if (!timestamp) return '';
        var d = new Date(timestamp * 1000);
        var now = new Date();
        var diff = now - d;
        if (diff < 60000) return t('Just now');
        if (diff < 3600000) return Math.floor(diff / 60000) + t('m ago');
        if (diff < 86400000) return Math.floor(diff / 3600000) + t('h ago');
        if (diff < 604800000) return Math.floor(diff / 86400000) + t('d ago');
        var months = ['Jan','Feb','Mar','Apr','May','Jun','Jul','Aug','Sep','Oct','Nov','Dec'];
        return months[d.getMonth()] + ' ' + d.getDate() + (d.getFullYear() !== now.getFullYear() ? ', ' + d.getFullYear() : '');
    }

    function getTypeClassFromFilename(name) {
        var lowerName = String(name || '').toLowerCase();
        if (!lowerName) return '';
        if (FILE_TYPE_BY_FILENAME[lowerName]) {
            return FILE_TYPE_BY_FILENAME[lowerName];
        }
        var compoundMatch = lowerName.match(/\.([^.]+\.[^.]+)$/);
        if (compoundMatch && FILE_TYPE_BY_COMPOUND_EXTENSION[compoundMatch[1]]) {
            return FILE_TYPE_BY_COMPOUND_EXTENSION[compoundMatch[1]];
        }
        var extMatch = lowerName.match(/\.([^.]+)$/);
        if (!extMatch) return '';
        return FILE_TYPE_BY_EXTENSION[extMatch[1]] || '';
    }

    function getFileDisplayParts(name) {
        var originalName = String(name || '');
        var lowerName = originalName.toLowerCase();
        if (!originalName) {
            return { baseName: '', extensionLabel: '' };
        }

        var compoundMatch = lowerName.match(/\.([^.]+\.[^.]+)$/);
        if (compoundMatch && FILE_TYPE_BY_COMPOUND_EXTENSION[compoundMatch[1]] && originalName.length > compoundMatch[1].length + 1) {
            return {
                baseName: originalName.slice(0, -(compoundMatch[1].length + 1)),
                extensionLabel: '.' + compoundMatch[1].toLowerCase()
            };
        }

        var lastDot = originalName.lastIndexOf('.');
        if (lastDot <= 0 || lastDot === originalName.length - 1) {
            return { baseName: originalName, extensionLabel: '' };
        }

        return {
            baseName: originalName.slice(0, lastDot),
            extensionLabel: originalName.slice(lastDot).toLowerCase()
        };
    }

    function resolveEntryTypeClass(entry) {
        if (!entry) return 'file';
        if (entry.is_dir) return 'dir';
        return getTypeClassFromFilename(entry.name) || entry.type || 'file';
    }

    // ===== Theme =====
    function normalizeThemePreference(theme) {
        return theme === "dark" || theme === "light" ? theme : null;
    }

    function getStoredThemePreference() {
        try {
            return normalizeThemePreference(localStorage.getItem(THEME_STORAGE_KEY));
        } catch (e) {
            return null;
        }
    }

    function setStoredThemePreference(theme) {
        var normalized = normalizeThemePreference(theme);
        if (!normalized) return;
        try {
            localStorage.setItem(THEME_STORAGE_KEY, normalized);
        } catch (e) {}
    }

    function getInitialThemePreference() {
        var storedTheme = getStoredThemePreference();
        if (storedTheme) return storedTheme;
        if (window.matchMedia && window.matchMedia("(prefers-color-scheme: dark)").matches) {
            return "dark";
        }
        return "light";
    }

    function getNextThemePreference(theme) {
        return theme === "dark" ? "light" : "dark";
    }

    function getThemeModeLabel(theme) {
        return theme === "dark" ? "Dark mode" : "Light mode";
    }

    function updateThemeToggleUI() {
        var button = document.getElementById("themeToggle");
        if (!button) return;

        var nextTheme = getNextThemePreference(currentThemePreference);
        var title = getThemeModeLabel(currentThemePreference) + ". Switch to " + getThemeModeLabel(nextTheme).toLowerCase() + ".";

        button.setAttribute("data-theme-state", currentThemePreference);
        button.title = title;
        button.setAttribute("aria-label", title);
    }

    function applyThemePreference(theme) {
        currentThemePreference = normalizeThemePreference(theme) || "light";
        document.documentElement.setAttribute("data-theme", currentThemePreference);
        updateThemeToggleUI();
    }

    function toggleThemePreference() {
        var nextTheme = getNextThemePreference(currentThemePreference);
        applyThemePreference(nextTheme);
        setStoredThemePreference(nextTheme);
    }

    function syncThemeWithSystemPreference(event) {
        if (getStoredThemePreference()) {
            return;
        }

        var prefersDark = !!(event && event.matches);
        if (!event && window.matchMedia) {
            prefersDark = window.matchMedia("(prefers-color-scheme: dark)").matches;
        }
        applyThemePreference(prefersDark ? "dark" : "light");
    }

    function initTheme() {
        applyThemePreference(getInitialThemePreference());

        var button = document.getElementById("themeToggle");
        if (button && !button._filesyncThemeBound) {
            button.addEventListener("click", toggleThemePreference);
            button._filesyncThemeBound = true;
        }

        if (window.matchMedia && !window._filesyncThemeMediaQueryBound) {
            var mediaQuery = window.matchMedia("(prefers-color-scheme: dark)");
            if (mediaQuery.addEventListener) {
                mediaQuery.addEventListener("change", syncThemeWithSystemPreference);
                window._filesyncThemeMediaQueryBound = true;
            }
        }
    }

    // ===== View Mode =====
    function getViewModeLabel(mode) {
        if (mode === "grid-large") return "Large grid view";
        if (mode === "grid") return "Grid view";
        return "List view";
    }

    function getViewModeIcon(mode) {
        if (mode === "grid-large") return icons.viewGridLarge;
        if (mode === "grid") return icons.viewGrid;
        return icons.viewList;
    }

    function getNextViewMode() {
        if (viewMode === "list") return "grid";
        if (viewMode === "grid") return "grid-large";
        return "list";
    }

    function setFileListViewMode() {
        var list = document.getElementById("fileList");
        if (!list) return;
        list.classList.toggle("view-grid", viewMode === "grid");
        list.classList.toggle("view-grid-large", viewMode === "grid-large");
    }

    function updateViewModeUI() {
        var button = document.getElementById("btnViewMode");
        var header = document.getElementById("fileListHeader");
        if (!button) return;

        var nextMode = getNextViewMode();
        var title = getViewModeLabel(viewMode) + ". Switch to " + getViewModeLabel(nextMode).toLowerCase() + ".";
        button.innerHTML = getViewModeIcon(viewMode);
        button.title = title;
        button.setAttribute("aria-label", title);
        setFileListViewMode();
        if (header) {
            header.classList.toggle("visible", viewMode === "list" && !!(currentEntries && currentEntries.length));
        }
    }

    window.toggleViewMode = function() {
        viewMode = getNextViewMode();
        try {
            localStorage.setItem(VIEW_MODE_STORAGE_KEY, viewMode);
        } catch (e) {}
        updateViewModeUI();
        renderFiles(currentEntries);
    };

    // ===== Toast =====
    function showToast(message, type) {
        type = type || 'info';
        var container = document.getElementById('toastContainer');
        var toast = document.createElement('div');
        toast.className = 'toast ' + type;
        toast.textContent = message;
        container.appendChild(toast);
        setTimeout(function() {
            toast.classList.add('hiding');
            setTimeout(function() { toast.remove(); }, 300);
        }, 3000);
    }

    // ===== Modal =====
    function showModal(title, defaultValue, confirmText, callback) {
        modalCallback = callback;
        document.getElementById('modalTitle').textContent = title;
        document.getElementById('modalInput').value = defaultValue;
        document.getElementById('modalConfirm').textContent = confirmText;
        document.getElementById('modalOverlay').classList.add('open');
        setTimeout(function() {
            var input = document.getElementById('modalInput');
            input.focus();
            input.select();
        }, 100);
    }

    window.hideModal = function() {
        document.getElementById('modalOverlay').classList.remove('open');
        modalCallback = null;
        restoreModalInput();
    };

    window.closeModal = function(e) {
        if (e.target === document.getElementById('modalOverlay')) hideModal();
    };

    window.closeModalButton = function(event) {
        if (event) event.stopPropagation();
        hideModal();
    };

    window.confirmModal = function() {
        var value = document.getElementById('modalInput').value.trim();
        var cb = modalCallback;
        hideModal();
        if (cb) {
            cb(value);
        }
    };

    function restoreModalInput() {
        var inputElem = document.getElementById('modalInput');
        var inputParent = inputElem.parentNode;
        if (inputParent.classList.contains('modal-input-with-ext')) {
            var grandParent = inputParent.parentNode;
            grandParent.insertBefore(inputElem, inputParent);
            inputParent.remove();
        }
    }

    // ===== Confirm Dialog =====
    function showConfirm(title, message, btnText, callback, showSdr, warningMsg) {
        confirmCallback = callback;
        document.getElementById('confirmTitle').textContent = title;
        document.getElementById('confirmMessage').textContent = message;
        document.getElementById('confirmBtn').textContent = btnText;
        var warningEl = document.getElementById('confirmWarning');
        if (warningMsg) {
            warningEl.textContent = warningMsg;
            warningEl.style.display = 'block';
        } else {
            warningEl.textContent = '';
            warningEl.style.display = 'none';
        }
        var sdrOption = document.getElementById('confirmSdrOption');
        var sdrCheckbox = document.getElementById('confirmSdrCheckbox');
        if (showSdr) {
            document.getElementById('confirmSdrLabel').textContent = t('Also delete reading metadata (.sdr)');
            sdrCheckbox.checked = true;
            sdrOption.style.display = 'flex';
        } else {
            sdrOption.style.display = 'none';
            sdrCheckbox.checked = false;
        }
        document.getElementById('confirmOverlay').classList.add('open');
    }

    window.hideConfirm = function() {
        document.getElementById('confirmOverlay').classList.remove('open');
        confirmCallback = null;
    };

    window.closeConfirm = function(e) {
        if (e.target === document.getElementById('confirmOverlay')) hideConfirm();
    };

    window.closeConfirmButton = function(event) {
        if (event) event.stopPropagation();
        hideConfirm();
    };

    window.doConfirm = function() {
        var cb = confirmCallback;
        hideConfirm();
        if (cb) {
            cb();
        }
    };
