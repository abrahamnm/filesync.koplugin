<objective>
Refactor the monolithic `filesync/static/index.html` (3,626 lines) into a modular, maintainable source structure — with separate files for HTML, CSS, JavaScript, and i18n — while keeping the final served output as a **single bundled HTML file** assembled by a lightweight shell build script.

Special focus: unify the web UI's i18n with the existing `.po` translation system used by the Lua backend, so there is a single source of truth for all translations.

The end goal is a codebase where contributors can work on CSS, JS, HTML structure, and translations independently without navigating a 3,600+ line monolith, while preserving the current single-request serving behavior that matters on resource-constrained e-reader devices.
</objective>

<context>
This is a KOReader plugin (Lua) that serves a web-based file manager UI over HTTP. Read these files to understand the current architecture:

- `filesync/static/index.html` — the monolithic SPA (HTML + inline CSS + inline JS + hardcoded i18n translations for en/es/zh)
- `filesync/httpserver.lua` — HTTP server; `_serveIndex` (lines ~367-391) loads and caches `index.html`; `/api/lang` endpoint returns the device language
- `filesync/filesync_i18n.lua` — Lua-side `.po` file parser for menu translations
- `filesync/i18n/*.po` — existing translation files (en, es, zh_CN, pt_BR)
- `main.lua` — plugin entry point, uses `_("string")` for Lua-side translations

Key constraints:
- KOReader runs on e-readers (Kindle, Kobo, PocketBook) with limited resources
- The HTTP server is a simple Lua socket server — no framework, no middleware
- The served output MUST remain a single HTML file (all CSS/JS inlined) to minimize network requests
- No Node.js or npm dependencies — the build tool must be a simple shell script
- The `.po` files are the single source of truth for translations across both Lua menus and the web UI
</context>

<research>
Before implementing, thoroughly analyze the current `index.html` to understand:
1. The CSS structure — identify logical sections (layout, components, themes, dark mode, view modes)
2. The JavaScript structure — identify modules (i18n, API client, file operations, UI rendering, event handlers, modals, drag-and-drop, sorting, search)
3. The HTML markup structure — identify semantic sections (header/toolbar, file list, modals, context menus, upload area)
4. The current i18n implementation — catalog all translation keys and their usage in both JS (`t("key")`) and HTML (`data-i18n="key"`)
5. Review all `.po` files to understand what translations already exist on the Lua side and what's missing for the web UI
</research>

<requirements>

## 1. Source Directory Structure

Create a new modular source structure under `filesync/src/` (the existing `filesync/static/index.html` stays as the build output):

```
filesync/src/
├── html/
│   └── index.html          # HTML skeleton with {{placeholders}} for CSS, JS, and i18n data
├── css/
│   ├── base.css             # Reset, variables, typography
│   ├── layout.css           # Main layout, header, sidebar
│   ├── components.css       # Buttons, inputs, badges, cards
│   ├── file-list.css        # File list views (list, grid, grid-large)
│   ├── modals.css           # Modal dialogs
│   └── themes.css           # Light/dark theme variables and overrides
├── js/
│   ├── i18n.js              # Translation loader and t() function
│   ├── api.js               # API client (fetch wrappers for all endpoints)
│   ├── state.js             # Application state management
│   ├── file-list.js         # File listing, sorting, rendering
│   ├── file-ops.js          # Upload, download, rename, delete, mkdir
│   ├── ui.js                # UI utilities, modals, toasts, context menus
│   ├── drag-drop.js         # Drag and drop handling
│   └── app.js               # Initialization, event binding, main entry point
└── i18n/
    └── po2json.sh           # Script to convert .po files → JSON for web UI embedding
```

Adapt this structure based on what you find in the actual code — the above is a starting point, not prescriptive. Split along natural module boundaries that exist in the code.

## 2. I18n Unification

The web UI currently has translations hardcoded in JavaScript. Refactor to use the existing `.po` files as the single source of truth:

1. **Audit translation keys**: Compare the web UI's JS translation keys with what exists in the `.po` files. Identify keys that are web-UI-only and need to be added to the `.po` files.

2. **Add web UI keys to `.po` files**: Add any missing web-UI translation keys to ALL existing `.po` files (`en.po`, `es.po`, `zh_CN.po`, `pt_BR.po`). Use a consistent prefix or comment block (e.g., `# Web UI translations`) to distinguish web UI strings from Lua menu strings. Preserve all existing Lua-side translations.

3. **Create a `.po` → JSON converter** (`filesync/src/i18n/po2json.sh`): A shell script that:
   - Reads each `.po` file from `filesync/i18n/`
   - Extracts `msgid`/`msgstr` pairs (skipping empty `msgstr` — those fall back to English)
   - Outputs a JSON object per language: `{"key": "translation", ...}`
   - The build script will embed these JSON objects into the HTML

4. **Update the i18n.js module** to:
   - Read translations from a JSON object injected into the HTML at build time (e.g., a `<script>` block with `var TRANSLATIONS = {...}`)
   - Keep the `t(key)` function interface and `data-i18n` attribute approach
   - Keep the `/api/lang` fetch for language detection
   - Support fallback chain: exact locale → base language → English → raw key

## 3. Build Script

Create `filesync/build.sh` — a POSIX-compatible shell script that:

1. Reads the HTML skeleton from `src/html/index.html`
2. Concatenates all CSS files (in order) and injects them into a `<style>` block
3. Concatenates all JS files (in order, respecting dependencies) and injects them into a `<script>` block
4. Runs `po2json.sh` to generate translation JSON, then injects it as a `<script>var TRANSLATIONS = {...};</script>` block
5. Writes the final bundled output to `filesync/static/index.html`
6. Reports the output file size

The script must:
- Be executable (`chmod +x`)
- Use only standard POSIX tools (`cat`, `sed`, `awk`, or similar) — no Node, Python, or Lua required
- Have a clear file inclusion order documented in the script itself
- Handle the case where `filesync/static/` doesn't exist (create it)
- Be idempotent — safe to run repeatedly

## 4. Server Changes

Update `filesync/httpserver.lua` if needed to ensure:
- `_serveIndex` still serves from `filesync/static/index.html` (the build output) — this should require minimal or no changes
- The `/api/lang` endpoint continues to work as-is

## 5. Quality Requirements

- The built `index.html` must be functionally identical to the current one — same features, same appearance, same behavior
- All existing translations must be preserved (no regressions)
- All 4 languages (en, es, zh_CN, pt_BR) must work in the web UI after the refactor
- The source modules should have clear, logical boundaries — a developer should be able to find any piece of functionality quickly
</requirements>

<implementation>

### Approach

1. **Start by reading and fully understanding** the current `index.html` — map out every section before splitting
2. **Extract CSS first** — this is the safest split since CSS order is the main concern
3. **Extract JS next** — identify the dependency graph between functions before splitting into modules; use an IIFE or namespace pattern to avoid global pollution if needed, but keep it simple (no ES modules, no bundler — this runs in mobile browsers on e-readers)
4. **Build the HTML skeleton** with clear placeholder markers (e.g., `<!-- BUILD:CSS -->`, `<!-- BUILD:JS -->`, `<!-- BUILD:I18N -->`)
5. **Implement the build script** and verify the output matches the original
6. **Refactor i18n last** — update `.po` files, create the converter, rewire the JS

### What to avoid and WHY

- **Do NOT use ES modules (`import`/`export`)** — the output is a single `<script>` block; module syntax would break without a bundler
- **Do NOT introduce any npm/Node dependencies** — KOReader plugin contributors shouldn't need a JavaScript toolchain
- **Do NOT change the public API endpoints or their behavior** — the Lua server and existing clients depend on them
- **Do NOT remove or rename existing `.po` translation keys** — Lua-side menus depend on them
- **Do NOT use template literals or modern JS features beyond ES5** — some e-reader browsers are old WebKit versions with limited ES6 support; check the current code's JS style and match it
- **Do NOT create a complex build system** — the script should be readable by someone unfamiliar with build tools; a sequence of `cat` and `sed` commands is perfectly fine
</implementation>

<output>
Create/modify these files:

**New files:**
- `filesync/src/html/index.html` — HTML skeleton with build placeholders
- `filesync/src/css/*.css` — Modular CSS files (as many as logical sections warrant)
- `filesync/src/js/*.js` — Modular JS files (as many as logical modules warrant)
- `filesync/src/i18n/po2json.sh` — .po to JSON converter script
- `filesync/build.sh` — Main build script

**Modified files:**
- `filesync/i18n/en.po` — Add any missing web UI translation keys
- `filesync/i18n/es.po` — Add any missing web UI translation keys
- `filesync/i18n/zh_CN.po` — Add any missing web UI translation keys
- `filesync/i18n/pt_BR.po` — Add any missing web UI translation keys (translate if possible, otherwise leave msgstr empty for English fallback)
- `filesync/static/index.html` — Rebuilt output (should be functionally identical)
- `filesync/httpserver.lua` — Only if changes are needed (likely none)
</output>

<verification>
Before declaring complete, verify your work:

1. **Run the build script**: Execute `! cd /Users/abrahamnm/Developer/filesync.koplugin && bash filesync/build.sh` and confirm it produces `filesync/static/index.html` without errors
2. **Compare output size**: The new built `index.html` should be roughly similar in size to the original (±10%)
3. **Check all translations**: Verify that all translation keys from the original JS `translations` object exist in the `.po` files and appear in the built output
4. **Verify HTML structure**: Read the built `index.html` and confirm it contains all CSS, JS, and i18n data inlined
5. **Check .po file integrity**: Ensure existing Lua-side translations in all `.po` files are preserved (not removed or modified)
6. **Test po2json.sh**: Run the converter independently and verify it produces valid JSON for each language
7. **Check JS compatibility**: Confirm no ES6+ features were introduced (no `let`/`const`, arrow functions, template literals, destructuring, etc. — unless the original code already uses them)
</verification>

<success_criteria>
- Monolithic `index.html` is split into ≥5 meaningful source files across CSS, JS, and HTML
- Build script assembles them back into a single HTML file that is functionally identical to the original
- All web UI translations come from `.po` files — no hardcoded translation strings in JS source
- All 4 languages work correctly in the built output
- Build script uses only POSIX shell tools
- Source file organization is intuitive — a new contributor can find any feature in <30 seconds
- The build is idempotent and takes <5 seconds
</success_criteria>
