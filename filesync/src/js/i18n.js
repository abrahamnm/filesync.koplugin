    // ===== i18n =====
    // TRANSLATIONS is injected at build time from .po files via po2json.sh
    // Keys are English msgid strings (gettext convention).
    // The t() function returns the translation for the current language,
    // falling back to: exact locale -> base language -> English -> raw key.
    var currentLang = "en";

    function t(key) {
        var lang = currentLang;
        // Try exact locale (e.g. "zh_CN")
        if (typeof TRANSLATIONS !== "undefined" && TRANSLATIONS[lang] && TRANSLATIONS[lang][key]) {
            return TRANSLATIONS[lang][key];
        }
        // Try base language (e.g. "zh")
        var base = lang.split("_")[0];
        if (base !== lang && typeof TRANSLATIONS !== "undefined" && TRANSLATIONS[base] && TRANSLATIONS[base][key]) {
            return TRANSLATIONS[base][key];
        }
        // Fallback to English — for English, the key IS the English text,
        // so if there's no explicit en.po translation, the raw key is correct.
        if (typeof TRANSLATIONS !== "undefined" && TRANSLATIONS.en && TRANSLATIONS.en[key]) {
            return TRANSLATIONS.en[key];
        }
        // Return raw key (which is the English text by convention)
        return key;
    }

    function applyStaticTranslations() {
        document.querySelectorAll('[data-i18n]').forEach(function(el) {
            el.textContent = t(el.dataset.i18n);
        });
        // Placeholder
        document.getElementById('searchInput').placeholder = t('Filter files...');
        // Button titles
        document.getElementById('btnUpload').title = t('Upload files');
        document.getElementById('btnUpload').setAttribute('aria-label', t('Upload files'));
        document.getElementById('btnFolder').title = t('New folder');
        document.getElementById('btnFolder').setAttribute('aria-label', t('New folder'));
        document.getElementById('btnUploadFilesCta').title = t('Choose Files');
        document.getElementById('btnUploadFilesCta').setAttribute('aria-label', t('Choose Files'));
        // Dropzone text
        var dzText = document.getElementById('dropzoneText');
        dzText.innerHTML = t('Drag and drop files here, or') + ' <strong onclick="document.getElementById(\'fileInput\').click()">' + t('browse') + '</strong>';
        document.getElementById('modalCloseBtn').title = t('Cancel');
        document.getElementById('modalCloseBtn').setAttribute('aria-label', t('Cancel'));
        document.getElementById('confirmCloseBtn').title = t('Cancel');
        document.getElementById('confirmCloseBtn').setAttribute('aria-label', t('Cancel'));
        updateThemeToggleUI();
        updateViewModeUI();
    }
