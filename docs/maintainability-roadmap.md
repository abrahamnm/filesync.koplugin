# Maintainability Roadmap -- filesync.koplugin

## Executive Summary

The filesync.koplugin codebase is a well-structured KOReader plugin comprising ~3,700 lines of Lua across 8 source files. The overall architecture is sound: modules have clear responsibilities, path traversal protection is implemented, error handling is generally present via `pcall`, and the code follows a consistent style. The plugin has matured rapidly over ~45 commits from initial implementation to v1.4.0, and the git history shows recurring bug fixes around edge cases (QR screen crashes, MOBI cover extraction, sort ordering), which suggests areas that would benefit from hardening.

The most impactful maintainability issues are: (1) a fully duplicated JSON parser between `httpserver.lua` and `updater.lua` (~150 lines each), (2) the `fileops.lua` module at 1,376 lines with EPUB cover extraction logic repeated three times, (3) missing `pcall` protection on several `io.popen` and filesystem operations that could crash the plugin, and (4) dead code in `qrcode.lua` (145 lines) and `updater.lua:_httpsRequest` (unused function). There is no test infrastructure, which makes refactoring riskier than it needs to be.

The recommendations below are organized into three phases. Phase 1 addresses quick wins that reduce bug surface area and remove dead code. Phase 2 tackles structural deduplication. Phase 3 covers deeper improvements like testability and documentation. All changes are conservative and non-breaking.

## Codebase Overview

| Module | Lines | Role |
|--------|-------|------|
| `main.lua` | 153 | Plugin entry point. Registers menus, dispatches server toggle, handles suspend/resume/exit lifecycle events. |
| `_meta.lua` | 7 | Plugin metadata (name, description, version). Used by KOReader's plugin loader and the updater. |
| `filesync/httpserver.lua` | 721 | Non-blocking HTTP server built on LuaSocket. Handles routing, static file serving, JSON API endpoints, and includes a custom JSON encoder/decoder. |
| `filesync/filesyncmanager.lua` | 593 | Server lifecycle management (start/stop), WiFi/IP detection, battery check, QR code display, standby prevention, Kindle firewall rules. |
| `filesync/fileops.lua` | 1,376 | File operations: directory listing, upload, download, rename, delete, metadata extraction (EPUB OPF parsing, MOBI binary parsing), cover image extraction. |
| `filesync/updater.lua` | 650 | OTA update checker: fetches GitHub releases, compares versions, downloads/extracts/installs ZIP updates. Contains its own JSON parser. |
| `filesync/filesync_i18n.lua` | 92 | Custom gettext implementation that loads `.po` translation files from the plugin's `i18n/` directory. |
| `filesync/qrcode.lua` | 145 | Pure-Lua QR code generator (fallback). Currently dead code -- `generate()` returns nil, and the plugin uses KOReader's built-in `QRWidget`. |

Supporting files: `filesync/build.sh` (web UI build script), `filesync/src/` (modular HTML/CSS/JS sources), `filesync/static/index.html` (built web UI), `filesync/i18n/*.po` (10 translation files), `.github/workflows/release.yml` (CI release workflow).

## Findings by Category

### 1. Code Structure and Modularity

- **Current State**: Good separation of concerns across modules. `main.lua` is thin and delegates to `filesyncmanager` and `updater`. The HTTP server cleanly delegates file operations to `fileops`. No circular dependencies exist.

- **Issues Found**:
  - **Duplicated JSON parser**: `httpserver.lua:569-719` and `updater.lua:55-203` contain identical recursive-descent JSON parsers (~150 lines each). Both are copy-pasted implementations with the same structure, variable names, and edge-case handling.
  - **Duplicated `_shellEscape`**: `fileops.lua:668-673` and `updater.lua:472-474` implement the same shell-escaping function independently.
  - **Duplicated `_getPluginDir`**: `httpserver.lua:393-401`, `updater.lua:11-21`, `filesync_i18n.lua:17-19`, `filesyncmanager.lua:365`, and `main.lua:7` all independently compute the plugin directory via `debug.getinfo(1, "S")`. Five separate implementations of the same logic.
  - **EPUB OPF parsing repeated 3 times**: `fileops.lua` contains near-identical EPUB container.xml/OPF reading logic in `_epubHasCover` (lines 1005-1043), `getMetadata` (lines 1090-1168), and `getBookCover` (lines 1242-1345). Each independently shells out to `unzip -p`, parses container.xml, and scans for cover items.
  - **`fileops.lua` is oversized**: At 1,376 lines, it handles directory listing, file I/O, multipart upload parsing, EPUB metadata extraction, MOBI binary parsing, and cover image extraction. The MOBI/EPUB parsing alone accounts for ~650 lines.
  - **Dead code -- `qrcode.lua`**: The entire 145-line module is unused. `QRCode.generate()` returns nil (line 142), and the plugin directly uses KOReader's `QRWidget` in `filesyncmanager.lua:358-362`. The module is never required by any other file.
  - **Dead code -- `Updater:_httpsRequest`**: The function at `updater.lua:260-298` is defined but never called. The `_fetchLatestRelease` and `_downloadFile` methods implement their own HTTP request logic directly.
  - **Unused variable -- `escaped_id`**: `fileops.lua:1288` computes `escaped_id` for regex-safe cover ID matching but then uses direct string equality comparison (`item_id == cover_id`) on line 1292 instead.
  - **Unused variable -- `mv_backup`**: `updater.lua:435` assigns the result of `os.execute` to `mv_backup` but never checks whether the backup move succeeded before proceeding to the install move on line 442.
  - **Repeated lazy `require` in `main.lua`**: `require("filesync/filesyncmanager")` appears 11 times across menu callbacks and lifecycle handlers. While Lua caches `require` results, the repetition hurts readability.

- **Recommended Changes**:
  - Extract the JSON parser into a shared `filesync/json.lua` module and require it from both `httpserver.lua` and `updater.lua`.
  - Extract `_shellEscape` into a shared utility module or add it to the JSON module as a general utility.
  - Create a small `filesync/paths.lua` utility that computes and caches the plugin directory once.
  - Extract EPUB OPF parsing into a private helper (e.g., `FileOps:_readEpubOpf(full_path)`) that returns the parsed OPF content, OPF directory, and cover metadata, then call it from `_epubHasCover`, `getMetadata`, and `getBookCover`.
  - Remove `qrcode.lua` entirely, or at minimum add a clear `-- DEPRECATED` header and remove it from the release ZIP in `release.yml`.
  - Remove `Updater:_httpsRequest` (lines 257-298).
  - Remove or use `escaped_id` at `fileops.lua:1288`.
  - Add a success check for `mv_backup` at `updater.lua:435-439` before proceeding.
  - Move the `require("filesync/filesyncmanager")` call to a single local at the top of each function that uses it, or require it once in `addToMainMenu`.

### 2. Naming Conventions and Readability

- **Current State**: Naming is largely consistent. Module-level tables use PascalCase (`FileOps`, `HttpServer`, `FileSyncManager`). Functions use camelCase with colon syntax (`self:methodName`). Private methods use underscore prefix (`_resolvePath`, `_sendJSON`). Local variables use snake_case. This is consistent with KOReader's conventions.

- **Issues Found**:
  - **Inconsistent private prefix**: `FileOps:isExtensionSafe` (line 184) and `FileOps:setRootDir` (line 39) lack the underscore prefix despite being internal to the plugin (only called by `httpserver.lua`). Meanwhile, `HttpServer:sendResponseHeaders` (line 456) is public (called by `fileops.lua`) but could be mistaken for internal.
  - **Parameter `inline` is ambiguous**: `FileOps:downloadFile(client, rel_path, server, inline)` at `fileops.lua:343` -- `inline` is a boolean controlling Content-Disposition header. A name like `preview` or `inline_disposition` would be clearer.
  - **`_meta` shadowing**: `main.lua:8` uses `local _meta = dofile(...)` where the underscore prefix conventionally means "unused" in Lua. This variable is used on line 95. A name like `plugin_meta` would be clearer.
  - **Abbreviation inconsistency**: `filesyncmanager.lua` uses both `ok_power` / `ok_cap` / `ok_chg` (lines 308-315) with short prefixes, while similar patterns elsewhere use `ok` / `err`. The abbreviated names are fine but differ from the rest of the codebase.
  - **`GF256` in dead code**: `qrcode.lua` defines `GF256` as a non-local table (line 11), which could theoretically pollute the global scope if the file were ever required. However, since the file is never loaded, this is a latent issue.

- **Recommended Changes**:
  - Rename `_meta` to `plugin_meta` in `main.lua:8`.
  - Consider renaming `inline` to `preview` in `downloadFile` parameters (matching the query parameter name `query.preview` used in `httpserver.lua:291`).
  - Add `local` to `GF256` declaration in `qrcode.lua:11` (if the file is retained).
  - No other naming changes are strongly warranted -- the conventions are sound.

### 3. Error Handling and Robustness

- **Current State**: The codebase uses `pcall` extensively for error-prone operations (HTTP client handling, file I/O, metadata parsing, LFS calls). The HTTP server wraps each client handler in `pcall` (line 75) and has a fallback error response. File operations validate paths and return `nil, error_message` on failure.

- **Issues Found**:
  - **Unprotected `lfs.dir` in `_deleteRecursive`**: `fileops.lua:642` calls `lfs.dir(path)` without `pcall`. If the directory cannot be read (permissions, concurrent deletion), this will throw an unhandled error. Compare with `listDirectory` (line 209) and `_countFilesRecursive` (line 619), which both wrap `lfs.dir` in `pcall`.
  - **Unprotected `debug.getinfo` chain in `showQRCode`**: `filesyncmanager.lua:365` has `debug.getinfo(1, "S").source:match("@(.+)"):match("(.*/)")`. If `source` does not start with `@`, the first `match` returns nil and the chained `:match` call will crash with "attempt to index a nil value".
  - **No body-size limit on HTTP requests**: `httpserver.lua:121-124` reads the body based solely on the `Content-Length` header value. A malicious client could send `Content-Length: 999999999` and exhaust device memory. There is no maximum body size check.
  - **`_readBody` can loop indefinitely on slow connections**: `httpserver.lua:142-161` reads until `remaining` reaches 0, but if the socket returns empty data (nil err without partial), the loop breaks. However, if the client sends data very slowly, each `receive` can block up to the 5-second timeout set on line 74. For a large body, this could block the UI event loop for extended periods.
  - **`mv_backup` return value ignored**: `updater.lua:435` performs the critical backup move but does not check its return value. If the backup fails (e.g., disk full), the subsequent install move at line 442 could leave the plugin in a broken state with neither the original nor the update in place.
  - **`io.popen` failures silently ignored in some paths**: `filesyncmanager.lua:118` calls `io.popen("ifconfig...")` and checks `if fd then`, which is correct. However, `fileops.lua:1009` and similar EPUB extraction calls check the handle but not the exit status -- a failed `unzip` command returns empty output that is treated as "no cover" rather than an error.
  - **`dofile` in `_readSdrMetadata` could execute arbitrary Lua**: `fileops.lua:687` calls `pcall(dofile, meta_file)` on `.sdr` metadata files. While these are KOReader's own files, a crafted metadata file could execute arbitrary code. This is mitigated by `pcall` catching errors, but the code execution itself is the concern.
  - **Client socket timeout of 5 seconds per request**: `httpserver.lua:74` sets `client:settimeout(5)`. For large file uploads, this timeout applies per `receive` call rather than overall, which is fine. However, for the 4-connection-per-poll-cycle design (line 70), a slow client on each of the 4 connections could block the UI for up to 20 seconds.
  - **No error handling on `client:send` in `_sendAll`**: `httpserver.lua:404-418` handles partial sends but returns `nil, err` on failure without logging. Callers of `_sendAll` (like `_sendJSON`, `_sendError`) do not check the return value.

- **Recommended Changes**:
  - Wrap `lfs.dir` in `pcall` in `_deleteRecursive` at `fileops.lua:642`, consistent with the pattern already used elsewhere.
  - Add nil-safety to `filesyncmanager.lua:365`: split the chained match calls and add a fallback.
  - Add a maximum body size constant (e.g., 50 MB) and reject requests exceeding it in `_handleClient` before calling `_readBody`.
  - Check the return value of `mv_backup` at `updater.lua:435` and abort with error if it fails.
  - Add `logger.warn` calls for `_sendAll` failures in `_sendJSON` and `_sendError` to aid debugging.

### 4. Lua Best Practices

- **Current State**: The codebase uses `local` declarations consistently for variables and functions. Tables are used efficiently, and the OOP pattern (module table with colon-syntax methods) is idiomatic for KOReader plugins. String operations use Lua patterns appropriately.

- **Issues Found**:
  - **Potential global leak in `qrcode.lua`**: `GF256` at line 11 is declared without `local`. If this module were ever `require`d, it would create a global variable. (Currently dead code, so no runtime impact.)
  - **Inefficient string-based JSON escape**: `httpserver.lua:540-566` iterates byte-by-byte using `string.byte` and builds a table of single characters. While functionally correct, using `string.gsub` with a character class would be more idiomatic and potentially faster for large strings.
  - **`str:sub(pos, pos)` pattern used heavily in JSON parser**: Both `httpserver.lua` and `updater.lua` use `str:sub(pos, pos)` extensively in the JSON parser (e.g., lines 575-576). This creates a new string object for each character access. Using `string.byte(str, pos)` for comparisons would avoid allocations.
  - **XOR emulation in `qrcode.lua`**: Lines 48-59 implement bitwise XOR by iterating bit-by-bit with `math.floor` and `2^bit`. This is very slow compared to using `bit32.bxor` (available in Lua 5.2+/LuaJIT). The code checks for `bit32` on line 22 but falls back to a broken arithmetic approach instead of using it consistently.
  - **Repeated `require` calls in callbacks**: `main.lua` calls `require("filesync/filesyncmanager")` 11 times. While Lua caches `require` results after first load, each call still involves a table lookup in `package.loaded`. This is a minor efficiency concern but primarily a readability issue.
  - **`table.insert` vs `t[#t+1]`**: The codebase uses `table.insert(items, value)` throughout (e.g., `httpserver.lua:524`). In LuaJIT (used by KOReader), `t[#t+1] = value` is marginally faster, but `table.insert` is more readable. This is a style note, not a bug.
  - **Unused `start` variable**: `httpserver.lua:585` declares `local start = pos` inside `parse_string()` but `start` is never referenced.

- **Recommended Changes**:
  - Add `local` to `GF256` in `qrcode.lua:11` (if retained).
  - Remove the unused `local start = pos` at `httpserver.lua:585` (also exists in `updater.lua:106` in the duplicated parser).
  - Consider replacing the byte-by-byte `_escapeJSONString` with a `gsub`-based approach for clarity.
  - No other changes are strongly warranted -- the code follows Lua best practices well.

### 5. Documentation

- **Current State**: The codebase has sparse inline documentation. Some functions have brief `---` doc comments (e.g., `fileops.lua:43-44`, `updater.lua:23`, `updater.lua:32`), but most functions have no documentation of parameters, return values, or side effects. Module-level descriptions exist only in `qrcode.lua:1-7` and `filesync_i18n.lua:1-4`.

- **Issues Found**:
  - **No module-level documentation**: `httpserver.lua`, `filesyncmanager.lua`, `fileops.lua`, `main.lua`, and `updater.lua` have no module-level doc comment explaining the module's purpose, dependencies, or usage.
  - **No parameter/return documentation on public API**: Key public functions like `FileOps:listDirectory`, `FileOps:handleUpload`, `HttpServer:start`, `FileSyncManager:start`, `FileSyncManager:showQRCode` have no documentation of their parameters or return values.
  - **`FileOps:delete` is the only well-documented function**: `fileops.lua:551-555` has a proper `@param` and `@field` doc block. This should be the standard for all public functions.
  - **No documentation on the HTTP API contract**: The REST API routes (GET /api/files, POST /api/upload, etc.) are only discoverable by reading `httpserver.lua:_route`. There is no reference for what parameters each endpoint accepts or what response shape it returns.
  - **Complex MOBI parsing underdocumented**: `_parseMobiMetadata` (lines 713-910) parses PalmDB headers, MOBI headers, and EXTH records with magic offsets. While inline comments explain individual fields, there is no high-level description of the parsing strategy or reference to the MOBI format specification.

- **Recommended Changes**:
  - Add a module-level `---` comment block to each `.lua` file describing its purpose and key dependencies.
  - Add `--- @param` and `--- @return` annotations to all public functions (those without underscore prefix).
  - Add a brief inline comment block at the top of `_route` documenting the API endpoints and their parameters.
  - Add a reference comment in `_parseMobiMetadata` pointing to the MOBI format specification or a well-known documentation source.

### 6. Testability

- **Current State**: There are no tests, no test infrastructure, and no test-related files in the repository (no `spec/`, `test/`, or `*_test.lua` files).

- **Issues Found**:
  - **No test framework**: The project has no testing setup. KOReader uses busted as its test framework; this plugin could adopt the same.
  - **Tightly coupled to KOReader globals**: `G_reader_settings` is accessed directly in `filesyncmanager.lua` (6 times) and `httpserver.lua` (1 time), as well as in `filesync_i18n.lua`. This global prevents modules from being loaded outside KOReader.
  - **`Device` dependency in `filesyncmanager.lua`**: `getRootDir()` (line 147) directly calls `Device:isKindle()`, `Device:isKobo()`, etc. This cannot be tested without mocking the entire Device module.
  - **`UIManager` dependency throughout**: `filesyncmanager.lua` and `httpserver.lua` directly call `UIManager:show`, `UIManager:scheduleIn`, `UIManager:close`, etc. These side effects make unit testing difficult.
  - **`io.popen` calls in `fileops.lua`**: EPUB metadata extraction shells out to `unzip` (7 calls across the file). This couples the logic to the system environment and makes it untestable in isolation.
  - **`FileOps` is a singleton table, not a class**: `fileops.lua` defines `FileOps` as a plain table with `self._root_dir` state. There is no constructor -- `setRootDir` mutates shared state. This makes it impossible to run multiple FileOps instances in parallel tests.
  - **`HttpServer:new` exists but `FileSyncManager` and `FileOps` lack constructors**: `HttpServer` has a proper `new` method (line 14), but `FileSyncManager` and `FileOps` are singletons with module-level state.

- **Recommended Changes**:
  - Add constructor methods (`new`) to `FileOps` and `FileSyncManager` to allow creating independent instances for testing.
  - Extract `G_reader_settings` access into thin wrapper functions on `FileSyncManager` (e.g., `_readSetting`, `_saveSetting`) that can be overridden in tests.
  - Start with unit tests for the pure-logic functions that have no KOReader dependencies: `Updater:_parseVersion`, `Updater:_isNewer`, `FileOps:_resolvePath`, `FileOps:_validateFilename`, `FileOps:_formatSize`, `FileOps:_getMimeType`, `FileOps:_getFileType`, `FileOps:isExtensionSafe`, `HttpServer:_encodeJSON`, `HttpServer:_parseJSON`, `HttpServer:_urlDecode`, `HttpServer:_parseQuery`, `HttpServer:_escapeJSONString`.
  - Add a `spec/` directory with busted-compatible test files for the above functions.

### 7. API Surface and Contracts

- **Current State**: Module interfaces are implicit. Public functions are distinguished from private ones by the underscore prefix convention, but this is not enforced by the language.

- **Issues Found**:
  - **`FileOps` exposes internals to `httpserver.lua`**: `HttpServer:_route` (line 194) calls `FileOps:listDirectory`, `FileOps:handleUpload`, `FileOps:downloadFile`, etc. This is appropriate. However, `httpserver.lua:260` also calls `FileOps:getBookCover(client, file_path, self)`, passing the HTTP client socket and server reference into the file operations module. This inverts the dependency: `FileOps` sends HTTP responses directly, coupling it to the transport layer.
  - **`sendResponseHeaders` is the only truly public method on `HttpServer`**: It is called by `FileOps:downloadFile` (line 367) and `FileOps:getBookCover` (lines 1223, 1361). This tight coupling means `FileOps` cannot function without an `HttpServer` instance.
  - **No formal contract for API responses**: The JSON response shapes for `/api/files`, `/api/metadata`, etc. are implicit -- defined by the data structures built in `FileOps` methods. There is no schema or type definition that the web UI frontend can rely on.
  - **`FileSyncManager` is accessed as both a module and an instance**: In `main.lua`, it is `require`d and then methods are called with colon syntax (`FileSyncManager:isRunning()`). But `FileSyncManager` is a singleton table, not an instance. This works but means there can only ever be one server, and state like `_was_running_before_suspend` (line 35) is module-global.

- **Recommended Changes**:
  - Decouple `FileOps` from HTTP transport: have `downloadFile` and `getBookCover` return the data (or a file handle + metadata) instead of directly writing to a client socket. Let `httpserver.lua` handle streaming. This is a medium-effort change but significantly improves separation of concerns.
  - Document the return types of each `FileOps` public method (what keys the returned tables contain).

### 8. Security Considerations

- **Current State**: The codebase has good baseline security. Path traversal protection exists in `FileOps:_resolvePath` (blocks `..`, verifies resolved path is under `_root_dir`). Filenames are validated in `_validateFilename`. Safe mode restricts file access to whitelisted extensions.

- **Issues Found**:
  - **No HTTP request body size limit**: `httpserver.lua:121-124` reads the full body based on `Content-Length` without any maximum. An attacker on the local network could send a multi-gigabyte `Content-Length` header, causing the device to run out of memory. This is the highest-severity security issue.
  - **Shell injection surface via `io.popen`**: `fileops.lua` constructs shell commands for `unzip` using `_shellEscape` (e.g., lines 1008, 1018, 1091, 1103, 1245, 1266, 1348). The `_shellEscape` function at line 668 correctly wraps values in single quotes and escapes embedded single quotes. This is adequate for path injection prevention. However, the reliance on shell commands means any bug in `_shellEscape` would be a command injection vulnerability.
  - **`os.execute` in updater for file operations**: `updater.lua` uses `os.execute("rm -rf ...")` (lines 382, 383, 428, 457, 463, 464) and `os.execute("mv ...")` (lines 435, 442). These use `_shellEscape` correctly, but `rm -rf` on controlled paths is inherently dangerous. A race condition between the backup move and install move (lines 435-446) could theoretically be exploited, though the attack surface is narrow.
  - **`iptables` command injection on Kindle**: `filesyncmanager.lua:577-580` uses `string.format` with the port number to construct an `iptables` command. Since `port` is validated as a number between 1024-65535 in `configurePort` (line 85), this is safe in practice. However, the port value stored in settings could theoretically be tampered with. Adding a `tonumber()` guard before the `iptables` call would be defensive.
  - **`dofile` on `.sdr` metadata files**: `fileops.lua:687` executes arbitrary Lua from `.sdr/metadata.*.lua` files. While these are KOReader's own cache files, a malicious file placed on the device could execute code. This is a known trade-off for KOReader's metadata format and is mitigated by `pcall`.
  - **CORS allows all origins**: `httpserver.lua:168` and `httpserver.lua:435` send `Access-Control-Allow-Origin: *`. This is intentional for a local network file server, but worth noting.
  - **No authentication**: The HTTP server has no authentication mechanism. Any device on the same WiFi network can access, upload, rename, and delete files. This is a known design choice documented in the README and mitigated by the user needing to manually start the server.
  - **HTTP header parsing does not limit header count or size**: `httpserver.lua:111-117` reads headers in a loop until an empty line. A malicious client could send thousands of headers to consume memory. Adding a maximum header count (e.g., 100) would be defensive.

- **Recommended Changes**:
  - Add a `MAX_BODY_SIZE` constant (e.g., 50 MB) to `httpserver.lua` and reject requests exceeding it before reading the body. This is the single most important security fix.
  - Add a `MAX_HEADER_COUNT` limit (e.g., 100) to the header parsing loop in `_handleClient`.
  - Add `tonumber()` validation on the port value before passing it to `iptables` in `openKindleFirewall`/`closeKindleFirewall`.
  - Consider adding a maximum request line length check in `_handleClient` (line 94) to prevent extremely long URLs from consuming memory.

## Prioritized Roadmap

### Phase 1: Quick Wins (Low risk, high impact)

- [ ] **Remove dead code: `qrcode.lua`** -- `filesync/qrcode.lua` -- Remove the 145-line module entirely. It is never `require`d by any other file, and `QRCode.generate()` is a no-op that returns nil. Also remove it from the release ZIP build step in `.github/workflows/release.yml:58` if it is included.

- [ ] **Remove dead function `_httpsRequest`** -- `filesync/updater.lua:260-298` -- Delete the unused `_httpsRequest` method. It was likely a precursor to the current `_downloadFile` implementation and is never called.

- [ ] **Remove unused variables** -- `filesync/httpserver.lua:585` (unused `local start = pos` in `parse_string`), `filesync/fileops.lua:1288` (unused `escaped_id`). Clean up to avoid confusion.

- [ ] **Add body size limit to HTTP server** -- `filesync/httpserver.lua:120-124` -- Add `local MAX_BODY_SIZE = 50 * 1024 * 1024` and check `content_length` against it before calling `_readBody`. Return 413 "Payload Too Large" if exceeded.

- [ ] **Add header count limit** -- `filesync/httpserver.lua:111-117` -- Add a counter to the header reading loop and break after 100 headers to prevent resource exhaustion.

- [ ] **Wrap `lfs.dir` in pcall in `_deleteRecursive`** -- `filesync/fileops.lua:642` -- Add `pcall` protection consistent with `listDirectory` (line 209) and `_countFilesRecursive` (line 619) to prevent unhandled errors during recursive deletion.

- [ ] **Fix nil-safety in `showQRCode` icon path** -- `filesync/filesyncmanager.lua:365` -- Split the chained `match` calls: `local source = debug.getinfo(1, "S").source or ""; local icon_dir = source:match("@(.+)") or ""; icon_dir = icon_dir:match("(.*/)" ) or "./"` to prevent nil indexing.

- [ ] **Check `mv_backup` return value before install** -- `filesync/updater.lua:435-446` -- Add a check after line 439: if `mv_backup` failed, abort with an error message instead of proceeding with the install move.

- [ ] **Add `tonumber` guard on port for iptables** -- `filesync/filesyncmanager.lua:575-590` -- Add `port = tonumber(port)` and an `if not port then return end` guard before the `string.format` call to ensure defensive coding even if settings are corrupted.

### Phase 2: Structural Improvements (Medium effort)

- [ ] **Extract shared JSON module** -- `filesync/httpserver.lua:496-719`, `filesync/updater.lua:55-203` -- Create `filesync/json.lua` containing `encode`, `decode`, and `escapeString` functions. Replace the ~300 lines of duplicated code with `require("filesync/json")` calls in both modules.

- [ ] **Extract shared utility module** -- `filesync/httpserver.lua:393-401`, `filesync/updater.lua:11-21,472-474`, `filesync/fileops.lua:668-673`, `filesync/filesync_i18n.lua:17-19`, `filesyncmanager.lua:365`, `main.lua:7` -- Create `filesync/utils.lua` with `getPluginDir()` and `shellEscape(s)` functions to eliminate 5 duplications of plugin-dir resolution and 2 duplications of shell escaping.

- [ ] **Consolidate EPUB OPF parsing in `fileops.lua`** -- `filesync/fileops.lua:1005-1043,1090-1168,1242-1345` -- Extract a private helper like `FileOps:_readEpubOpf(full_path)` that returns `{opf_content, opf_dir, cover_id, cover_href, cover_media_type, title, author}`. Call it from `_epubHasCover`, `getMetadata`, and `getBookCover`. This eliminates ~120 lines of duplicated `unzip -p` / XML-parsing logic.

- [ ] **Reduce lazy `require` repetition in `main.lua`** -- `main.lua:36-105` -- Move `local FileSyncManager = require("filesync/filesyncmanager")` to a single declaration inside `addToMainMenu` (since it is used by all sub-items), and reuse it in closures. Similarly for `onToggleFileSyncServer`, `onSuspend`, `onResume`, `onExit`.

- [ ] **Add module-level documentation** -- All `.lua` files -- Add a `---` comment block at the top of each module file describing its purpose, key dependencies, and public interface.

- [ ] **Document all public functions** -- All `.lua` files -- Add `--- @param` and `--- @return` annotations to every function without an underscore prefix. Model after `FileOps:delete` (lines 551-555) which already has good documentation.

### Phase 3: Deeper Refactors (Higher effort, still conservative)

- [ ] **Decouple `FileOps` from HTTP transport** -- `filesync/fileops.lua:343-388,1199-1374`, `filesync/httpserver.lua:254-295` -- Refactor `downloadFile` to return a file handle, size, and mime type instead of directly writing to the socket. Refactor `getBookCover` to return image data and content type. Move the HTTP streaming logic into `httpserver.lua:_route`. This eliminates the `server` and `client` parameters from `FileOps` and makes the module independently testable.

- [ ] **Add constructors to singleton modules** -- `filesync/fileops.lua`, `filesync/filesyncmanager.lua` -- Add `FileOps:new(o)` and `FileSyncManager:new(o)` constructors (similar to `HttpServer:new`). This allows creating independent instances for testing while keeping backward compatibility (the module-level table still works as a default instance).

- [ ] **Set up test infrastructure** -- New `spec/` directory -- Add busted as a test framework. Create test files for pure-logic functions: `spec/json_spec.lua` (test encode/decode round-trips), `spec/fileops_spec.lua` (test `_resolvePath`, `_validateFilename`, `_formatSize`, `_getMimeType`, `_getFileType`, `isExtensionSafe`), `spec/updater_spec.lua` (test `_parseVersion`, `_isNewer`). These functions have no KOReader dependencies and can be tested standalone.

- [ ] **Extract MOBI parser into its own module** -- `filesync/fileops.lua:713-910,914-1001` -- Move `_parseMobiMetadata` and `_extractMobiCover` into `filesync/mobi.lua`. This would reduce `fileops.lua` by ~300 lines and make the MOBI parsing independently testable and documentable.

- [ ] **Add request timeout/connection limit hardening** -- `filesync/httpserver.lua:66-90` -- Consider reducing the per-connection timeout from 5 seconds to 2 seconds, and adding an overall per-poll-cycle time budget to ensure the UI event loop is not blocked for more than a few seconds even when all 4 connection slots are used by slow clients.

## Out of Scope

The following improvements would enhance the codebase but require breaking changes, external dependencies, or significant architectural shifts. They are noted for future consideration:

- **Replace custom JSON parser with a library**: KOReader bundles `rapidjson` (via FFI). Using it would be faster and more correct than the hand-rolled parser, but would add a dependency on a specific KOReader internal module that may change across versions.
- **Replace `io.popen("unzip ...")` with a Lua ZIP library**: Using a pure-Lua or FFI ZIP reader would eliminate the shell dependency for EPUB parsing. KOReader has `ffi/ziplib` but its API is not documented for plugin use.
- **Add authentication/token to the HTTP server**: Would require changes to the web UI frontend, the API contract, and the QR code encoding. Significant feature work, not a maintainability improvement.
- **Switch from polling-based HTTP to event-driven**: The current 100ms poll interval (`_schedulePoll`) is adequate for the use case but is architecturally limited. An event-driven approach using `UIManager:watchFd` (if available) would be more efficient but would require significant restructuring.
- **Adopt LDoc or similar documentation generator**: Would formalize the documentation but adds tooling complexity. The inline `---` comments recommended in Phase 2 are sufficient for now.
