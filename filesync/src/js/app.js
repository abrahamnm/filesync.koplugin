    // ===== History / popstate =====
    // Parse the current hash and return {path, detail} without modifying state
    function _parseHash() {
        var hash = window.location.hash;
        if (!hash || hash === '#' || hash === '#/') {
            return {path: '/', detail: false};
        }
        // Strip leading '#' and decode URL-encoded characters (spaces, parens, etc.)
        var raw;
        try { raw = decodeURIComponent(hash.substring(1)); } catch(e) { raw = hash.substring(1); }
        if (raw.endsWith('!detail')) {
            return {path: raw.substring(0, raw.length - 7), detail: true};
        }
        return {path: raw || '/', detail: false};
    }

    window.addEventListener('popstate', function() {
        var state = _parseHash();
        if (state.detail) {
            // If navigating to a detail view and we're already showing it, skip
            if (currentDetailEntry && currentDetailEntry.path === state.path) return;
            // We might need to navigate to the parent directory first to load entries
            var parentPath = state.path.substring(0, state.path.lastIndexOf('/')) || '/';
            if (currentPath !== parentPath) {
                // Need to load the directory first, then show detail once loaded
                currentPath = parentPath;
                currentFilter = '';
                document.getElementById('searchInput').value = '';
                var params = new URLSearchParams({
                    path: currentPath,
                    sort: currentSort,
                    order: currentOrder,
                    filter: currentFilter
                });
                api('GET', '/api/files?' + params).then(function(data) {
                    renderBreadcrumbs(data.breadcrumbs);
                    renderFiles(data.entries);
                    _showDetailInternal(state.path);
                }).catch(function() {
                    // If loading fails, just navigate to the directory
                    _navigateInternal(parentPath);
                });
            } else {
                _showDetailInternal(state.path);
            }
        } else {
            // Navigating to a directory — close detail if open
            if (currentDetailEntry) {
                _hideDetailInternal();
            }
            _navigateInternal(state.path);
        }
    });

    // ===== Init =====
    // Read hash to determine initial state before loading
    var initState = _parseHash();
    if (initState.detail) {
        // For detail view, start at the parent directory
        var initParent = initState.path.substring(0, initState.path.lastIndexOf('/')) || '/';
        currentPath = initParent;
    } else {
        currentPath = initState.path;
    }
    // Set the initial history entry (replaceState so we don't add an extra entry)
    history.replaceState(
        initState.detail ? {path: initState.path, detail: true} : {path: currentPath},
        '',
        window.location.hash || '#/'
    );

    // Fetch language setting from server, then apply translations and load files
    var _initDetailPath = initState.detail ? initState.path : null;
    // When the user lands on the bare URL (no hash deep-link), prefer KOReader's
    // configured home folder over filesystem root. Single attempt; on failure or
    // when home is unset/outside root, keep currentPath ("/") as the fallback.
    var _hasDeepLink = !!window.location.hash && window.location.hash !== '#' && window.location.hash !== '#/';
    var _homeFetch = (_hasDeepLink || _initDetailPath)
        ? Promise.resolve()
        : fetch('/api/home')
            .then(function(res) { return res.json(); })
            .then(function(data) {
                if (data && typeof data.home === 'string' && data.home) {
                    currentPath = data.home;
                    history.replaceState({path: currentPath}, '', '#' + encodeURI(currentPath));
                }
            })
            .catch(function() { /* fall back silently */ });

    _homeFetch
        .then(function() { return fetch('/api/lang'); })
        .then(function(res) { return res.json(); })
        .then(function(data) {
            if (data && data.lang) {
                // Try exact match first, then prefix match (e.g. "zh_CN" -> "zh")
                if (typeof TRANSLATIONS !== "undefined" && TRANSLATIONS[data.lang]) {
                    currentLang = data.lang;
                } else {
                    var prefix = data.lang.split('_')[0];
                    if (typeof TRANSLATIONS !== "undefined" && TRANSLATIONS[prefix]) {
                        currentLang = prefix;
                    }
                }
            }
        })
        .catch(function() {
            // Keep English as default
        })
        .then(function() {
            // Set document direction and language
            document.documentElement.setAttribute("lang", currentLang.replace("_", "-"));
            document.documentElement.setAttribute("dir", isRTLLanguage(currentLang) ? "rtl" : "ltr");
            initTheme();
            applyStaticTranslations();
            return loadFiles();
        })
        .then(function() {
            // After files are loaded, open detail view if hash indicated one
            if (_initDetailPath) {
                _showDetailInternal(_initDetailPath);
            }
        });
