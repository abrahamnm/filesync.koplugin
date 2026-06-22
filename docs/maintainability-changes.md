# Maintainability Changes Applied

## Summary
Executed the maintainability roadmap across Phase 1 (Quick Wins) and Phase 2 (Structural Improvements). All Phase 1 items were implemented. Phase 2 items were largely completed, with one item skipped (lazy require consolidation in main.lua -- already idiomatic). Phase 3 items were flagged for review as they require more significant architectural changes that should be paired with test infrastructure.

Key outcomes:
- Removed ~450 lines of dead/duplicated code (qrcode.lua, duplicated JSON parsers, unused functions)
- Added HTTP security hardening (body size limit, header count limit)
- Fixed potential crash bugs (nil-safety in showQRCode, pcall in _deleteRecursive, mv_backup check)
- Extracted shared modules (json.lua, utils.lua) eliminating code duplication across 5 files
- Consolidated EPUB OPF parsing from 3 duplicated implementations into 1 shared helper
- Added module-level documentation and public function annotations across all files

## Changes by Phase

### Phase 1: Quick Wins
- [x] **Remove dead code: `qrcode.lua`** -- Deleted `filesync/qrcode.lua` (145 lines). The module was never required by any other file and its `generate()` function was a no-op. The file was included in release ZIPs via `cp -r filesync` in release.yml; removing the file is sufficient.
- [x] **Remove dead function `_httpsRequest`** -- Deleted `Updater:_httpsRequest` from `filesync/updater.lua` (~40 lines). The function was defined but never called.
- [x] **Remove unused variables** -- Removed `local start = pos` from `HttpServer:_parseJSON:parse_string` in `httpserver.lua` (subsequently removed entirely with JSON extraction). Removed unused `escaped_id` from `FileOps:getBookCover` in `fileops.lua`.
- [x] **Add body size limit to HTTP server** -- Added `MAX_BODY_SIZE = 50 * 1024 * 1024` constant and a check before `_readBody` in `httpserver.lua`. Returns HTTP 413 "Payload Too Large" if exceeded.
- [x] **Add header count limit** -- Added `MAX_HEADER_COUNT = 100` constant and a counter in the header reading loop in `httpserver.lua`. Returns HTTP 431 "Request Header Fields Too Large" if exceeded.
- [x] **Wrap `lfs.dir` in pcall in `_deleteRecursive`** -- Wrapped the `lfs.dir` iteration in `FileOps:_deleteRecursive` with `pcall`, consistent with `listDirectory` and `_countFilesRecursive`. Errors during directory iteration are now caught and returned as error messages instead of crashing.
- [x] **Fix nil-safety in `showQRCode` icon path** -- Split the chained `match` calls in `filesyncmanager.lua:showQRCode` and replaced with `Utils.getPluginDir()` to compute the icon path safely.
- [x] **Check `mv_backup` return value before install** -- Added a return-value check after the backup `os.execute("mv ...")` in `Updater:_installUpdate`. If the backup fails, the update is aborted with cleanup instead of proceeding to an install that could leave the plugin in a broken state.
- [x] **Add `tonumber` guard on port for iptables** -- Added `port = tonumber(port)` with early return in both `openKindleFirewall` and `closeKindleFirewall` in `filesyncmanager.lua`.

### Phase 2: Structural Improvements
- [x] **Extract shared JSON module** -- Created `filesync/json.lua` with `JSON.encode()`, `JSON.decode()`, and `JSON.escapeString()`. Removed ~300 lines of duplicated JSON parser/encoder code from `httpserver.lua` and `updater.lua`. Both modules now `require("filesync/json")`.
- [x] **Extract shared utility module** -- Created `filesync/utils.lua` with `Utils.getPluginDir()` (cached, returns plugin root) and `Utils.shellEscape()`. Updated `updater.lua`, `fileops.lua`, and `filesyncmanager.lua` to delegate to the shared implementations. `httpserver.lua` delegates but appends `/filesync` since it needs the submodule directory for `static/` files. The `filesync_i18n.lua` module was not changed because its path computation resolves to a different directory level (the `filesync/` subdir, not the plugin root).
- [x] **Consolidate EPUB OPF parsing in `fileops.lua`** -- Extracted `FileOps:_readEpubOpf(full_path)` as a shared helper that reads container.xml, parses the OPF, and returns a table with opf_content, opf_dir, title, author, cover metadata, and has_cover flag. Refactored `_epubHasCover`, `getMetadata` (EPUB branch), and `getBookCover` (EPUB branch) to use it, eliminating ~120 lines of duplicated unzip/XML-parsing logic.
- [ ] **Reduce lazy `require` repetition in `main.lua`** (skipped) -- The existing pattern of `local FileSyncManager = require(...)` inside each callback/lifecycle function is idiomatic for KOReader plugins where lazy loading is intentional. Lua caches `require` results, so the performance impact is negligible. Hoisting the require outside closures would change the loading semantics.
- [x] **Add module-level documentation** -- Added `---` doc comment blocks at the top of `httpserver.lua`, `filesyncmanager.lua`, `fileops.lua`, and `updater.lua` describing purpose and key dependencies. (`json.lua` and `utils.lua` were created with documentation. `filesync_i18n.lua` already had a doc header. `_meta.lua` is metadata only.)
- [x] **Document public functions** -- Added `@param` and `@return` annotations to: `HttpServer:start`, `HttpServer:stop`, `HttpServer:_route` (with full API endpoint reference), `FileSyncManager:start`, `FileSyncManager:stop`, `FileSyncManager:isRunning`, `FileSyncManager:showQRCode`, `FileOps:listDirectory`, `FileOps:handleUpload`, `FileOps:getMetadata`, `FileOps:getBookCover`, `FileOps:_parseMobiMetadata` (with MobileRead wiki reference), `FileOps:_readEpubOpf`.
- [x] **Rename `_meta` to `plugin_meta` in main.lua** -- Renamed the local variable from `_meta` (which conventionally implies "unused") to `plugin_meta` for clarity, since it is used on line 95 to display the version.

### Phase 3: Deeper Refactors
- [ ] **Decouple FileOps from HTTP transport** (flagged) -- Requires changing the signatures of `downloadFile` and `getBookCover` to return data instead of writing to sockets. Should be done alongside test infrastructure.
- [ ] **Add constructors to singleton modules** (flagged) -- Adding `new()` to FileOps and FileSyncManager is best paired with test infrastructure to validate the change.
- [ ] **Set up test infrastructure** (flagged) -- Requires creating a `spec/` directory and busted test files. Should be a separate PR.
- [ ] **Extract MOBI parser into its own module** (flagged) -- Moving ~300 lines into `filesync/mobi.lua` is a structural change best done with test coverage.
- [ ] **Add request timeout/connection limit hardening** (flagged) -- Changing timeout values could affect real-world behavior; needs testing on actual devices.

## Items Flagged for Review
All Phase 3 items are flagged. They share a common dependency: the project needs test infrastructure (busted) before these deeper refactors can be done safely. Recommended order:
1. Set up test infrastructure with tests for pure-logic functions
2. Extract MOBI parser (can be tested independently)
3. Decouple FileOps from HTTP transport (needs integration testing)
4. Add constructors to singletons (enables proper unit testing)
5. Tune connection timeouts (needs device testing)

## Verification Notes
- All modified files pass `luajit -bl` syntax check (no parse errors)
- No exported function signatures were changed
- No accidental globals were introduced (all new variables use `local`)
- The `filesync/qrcode.lua` module had no references from any other file (confirmed via grep)
- The `Updater:_httpsRequest` function had no callers (confirmed via grep)
- `filesync_i18n.lua` was not updated for Utils.getPluginDir() because it needs the `filesync/` subdirectory path, not the plugin root; this is a different computation
- The `_readEpubOpf` helper preserves the exact same cover detection logic as the three functions it replaces, including both Method 1 (cover meta element) and Method 2 (items with cover-like id)

## Files Modified
- `main.lua` -- renamed `_meta` to `plugin_meta`
- `filesync/httpserver.lua` -- removed inline JSON parser/encoder (~230 lines), added JSON/Utils requires, added body/header limits, added module docs and API route docs
- `filesync/filesyncmanager.lua` -- fixed nil-safety in showQRCode icon path, added tonumber guard on iptables port, added Utils require, added module/function docs
- `filesync/fileops.lua` -- removed unused `escaped_id`, wrapped `_deleteRecursive` lfs.dir in pcall, added Utils require, delegated `_shellEscape`, extracted `_readEpubOpf` helper, refactored 3 EPUB functions, added module/function docs
- `filesync/updater.lua` -- removed `_httpsRequest` (~40 lines), removed inline JSON parser (~150 lines), added JSON/Utils requires, delegated `_getPluginDir`/`_shellEscape`, added mv_backup check, added module docs

## Files Created
- `filesync/json.lua` -- shared JSON encoder/decoder (extracted from httpserver.lua and updater.lua)
- `filesync/utils.lua` -- shared utilities: `getPluginDir()` (cached) and `shellEscape()`

## Files Deleted
- `filesync/qrcode.lua` -- dead code (145 lines), never required by any module
