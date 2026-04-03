    // ===== State =====
    var THEME_STORAGE_KEY = "filesync_theme";
    var VIEW_MODE_STORAGE_KEY = "filesync_view_mode";
    var currentThemePreference = "light";

    var currentPath = '/';
    var currentSort = 'name';
    var currentOrder = 'asc';
    var currentFilter = '';
    var uploadZoneVisible = false;
    var modalCallback = null;
    var confirmCallback = null;
    var filterTimer = null;
    var currentEntries = [];
    var currentDetailEntry = null;
    var viewMode = 'list';
    try {
        var storedViewMode = localStorage.getItem(VIEW_MODE_STORAGE_KEY);
        if (storedViewMode === 'grid' || storedViewMode === 'grid-large') {
            viewMode = storedViewMode;
        }
    } catch (e) {}

    // ===== Icons =====
    var icons = {
        home: '<svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round"><path d="M3 11.5L12 4l9 7.5"/><path d="M5 10.5V20h14v-9.5"/><path d="M10 20v-6h4v6"/></svg>',
        viewList: '<svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round"><line x1="8" y1="6" x2="21" y2="6"/><line x1="8" y1="12" x2="21" y2="12"/><line x1="8" y1="18" x2="21" y2="18"/><line x1="3" y1="6" x2="3.01" y2="6"/><line x1="3" y1="12" x2="3.01" y2="12"/><line x1="3" y1="18" x2="3.01" y2="18"/></svg>',
        viewGrid: '<svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round"><rect x="3" y="4" width="8" height="6" rx="1.4"/><rect x="13" y="4" width="8" height="6" rx="1.4"/><rect x="3" y="13" width="8" height="8" rx="1.4"/><rect x="13" y="13" width="8" height="8" rx="1.4"/></svg>',
        viewGridLarge: '<svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round"><rect x="4" y="4" width="6" height="6" rx="1.2"/><rect x="14" y="4" width="6" height="6" rx="1.2"/><rect x="4" y="14" width="6" height="6" rx="1.2"/><rect x="14" y="14" width="6" height="6" rx="1.2"/></svg>',
        dir: '<svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2.05" stroke-linecap="round" stroke-linejoin="round"><path d="M3 7.5A2.5 2.5 0 015.5 5H10l2 2h6.5A2.5 2.5 0 0121 9.5v7A2.5 2.5 0 0118.5 19h-13A2.5 2.5 0 013 16.5z"/></svg>',
        ebook: '<svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round"><path d="M4 19.5A2.5 2.5 0 016.5 17H20"/><path d="M6.5 2H20v20H6.5A2.5 2.5 0 014 19.5v-15A2.5 2.5 0 016.5 2z"/></svg>',
        pdf: '<svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.8" stroke-linecap="round" stroke-linejoin="round"><path d="M6 2h8.5L19 6.5V20a2 2 0 01-2 2H6a2 2 0 01-2-2V4a2 2 0 012-2z" fill="currentColor" fill-opacity="0.13" stroke="currentColor"/><path d="M14 2v5h5"/><text x="5" y="17" font-family="system-ui,sans-serif" font-size="5.2" font-weight="800" fill="currentColor" stroke="none" letter-spacing="0.3">PDF</text></svg>',
        reader: '<svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round"><rect x="6" y="2.5" width="12" height="19" rx="2"/><path d="M9 6.5h6"/><path d="M9 16.5h6"/><path d="M12 19h.01"/></svg>',
        comic: '<svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round"><rect x="3" y="4" width="18" height="16" rx="2"/><path d="M8 4v16"/><path d="M13 4v16"/><path d="M3 10h18"/></svg>',
        document: '<svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round"><path d="M14 2H6a2 2 0 00-2 2v16a2 2 0 002 2h12a2 2 0 002-2V8z"/><polyline points="14 2 14 8 20 8"/><line x1="16" y1="13" x2="8" y2="13"/><line x1="16" y1="17" x2="8" y2="17"/></svg>',
        text: '<svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.8" stroke-linecap="round" stroke-linejoin="round"><rect x="2.5" y="4" width="19" height="16" rx="3" fill="currentColor" fill-opacity="0.13" stroke="currentColor"/><path d="M7 8.2h10"/><text x="4.25" y="16.1" font-family="system-ui,sans-serif" font-size="6.1" font-weight="800" fill="currentColor" stroke="none" letter-spacing="0.25">TXT</text></svg>',
        markdown: '<svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.8" stroke-linecap="round" stroke-linejoin="round"><rect x="2.5" y="4" width="19" height="16" rx="3" fill="currentColor" fill-opacity="0.13" stroke="currentColor"/><text x="4.4" y="15.8" font-family="system-ui,sans-serif" font-size="7.4" font-weight="800" fill="currentColor" stroke="none">M&#x2193;</text></svg>',
        image: '<svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round"><rect x="3" y="3" width="18" height="18" rx="2" ry="2"/><circle cx="8.5" cy="8.5" r="1.5"/><polyline points="21 15 16 10 5 21"/></svg>',
        archive: '<svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round"><path d="M21 8v11a2 2 0 01-2 2H5a2 2 0 01-2-2V8"/><path d="M1 8h22"/><path d="M10 12h4"/><path d="M10 16h4"/><path d="M9 3h6v5H9z"/></svg>',
        audio: '<svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round"><path d="M9 18V6l10-2v12"/><circle cx="6" cy="18" r="3"/><circle cx="16" cy="16" r="3"/></svg>',
        video: '<svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round"><rect x="3" y="5" width="18" height="14" rx="2"/><path d="M10 9l5 3-5 3z"/></svg>',
        code: '<svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.95" stroke-linecap="round" stroke-linejoin="round"><rect x="3.5" y="5.5" width="17" height="13" rx="2.6"/><path d="M7.1 10.2l2.4 1.8-2.4 1.8"/><path d="M12.1 14.1h4.8"/></svg>',
        file: '<svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round"><path d="M13 2H6a2 2 0 00-2 2v16a2 2 0 002 2h12a2 2 0 002-2V9z"/><polyline points="13 2 13 9 20 9"/></svg>',
        download: '<svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round"><path d="M21 15v4a2 2 0 01-2 2H5a2 2 0 01-2-2v-4"/><polyline points="7 10 12 15 17 10"/><line x1="12" y1="15" x2="12" y2="3"/></svg>',
        rename: '<svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round"><path d="M17 3a2.83 2.83 0 114 4L7.5 20.5 2 22l1.5-5.5L17 3z"/></svg>',
        trash: '<svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round"><polyline points="3 6 5 6 21 6"/><path d="M19 6v14a2 2 0 01-2 2H7a2 2 0 01-2-2V6m3 0V4a2 2 0 012-2h4a2 2 0 012 2v2"/></svg>',
        empty: '<svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round"><path d="M22 19a2 2 0 01-2 2H4a2 2 0 01-2-2V5a2 2 0 012-2h5l2 3h9a2 2 0 012 2z"/></svg>'
    };

    // ===== File Type Maps =====
    var FILE_TYPE_BY_COMPOUND_EXTENSION = {
        'fb2.zip': 'ebook',
        'epub.zip': 'ebook',
        'cbz.zip': 'comic'
    };

    var FILE_TYPE_BY_FILENAME = {
        'dockerfile': 'code',
        'makefile': 'code',
        'justfile': 'code',
        'cmakelists.txt': 'code',
        '.bashrc': 'code',
        '.zshrc': 'code',
        '.profile': 'code',
        '.gitignore': 'code',
        '.gitattributes': 'code',
        '.gitmodules': 'code',
        '.editorconfig': 'code',
        '.env': 'code'
    };

    var FILE_TYPE_BY_EXTENSION = {
        epub: 'ebook',
        fb2: 'ebook',
        lit: 'ebook',
        pdb: 'ebook',
        prc: 'ebook',
        mobi: 'reader',
        azw: 'reader',
        azw3: 'reader',
        kfx: 'reader',
        pdf: 'pdf',
        djvu: 'pdf',
        cbz: 'comic',
        cbr: 'comic',
        txt: 'text',
        md: 'markdown',
        markdown: 'markdown',
        mkd: 'markdown',
        mdown: 'markdown',
        rtf: 'text',
        doc: 'document',
        docx: 'document',
        chm: 'document',
        html: 'code',
        htm: 'code',
        png: 'image',
        jpg: 'image',
        jpeg: 'image',
        gif: 'image',
        svg: 'image',
        bmp: 'image',
        webp: 'image',
        zip: 'archive',
        gz: 'archive',
        tar: 'archive',
        bz2: 'archive',
        xz: 'archive',
        rar: 'archive',
        '7z': 'archive',
        mp3: 'audio',
        m4a: 'audio',
        aac: 'audio',
        wav: 'audio',
        ogg: 'audio',
        flac: 'audio',
        mp4: 'video',
        mkv: 'video',
        avi: 'video',
        mov: 'video',
        webm: 'video',
        lua: 'code',
        js: 'code',
        ts: 'code',
        jsx: 'code',
        tsx: 'code',
        mjs: 'code',
        cjs: 'code',
        json: 'code',
        xml: 'code',
        yml: 'code',
        yaml: 'code',
        toml: 'code',
        ini: 'code',
        cfg: 'code',
        conf: 'code',
        log: 'code',
        sh: 'code',
        bash: 'code',
        zsh: 'code',
        py: 'code',
        rb: 'code',
        php: 'code',
        go: 'code',
        rs: 'code',
        c: 'code',
        cpp: 'code',
        h: 'code',
        hpp: 'code',
        java: 'code',
        css: 'code',
        scss: 'code',
        sass: 'code',
        less: 'code',
        sql: 'code'
    };
