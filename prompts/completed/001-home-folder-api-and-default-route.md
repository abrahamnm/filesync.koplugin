<objective>
Add support in `filesync.koplugin` for opening the user's KOReader **home folder** (instead of filesystem root) when they navigate to the plugin's web UI at `http://<device-ip>:<port>/`. This requires:

1. Researching how KOReader stores and exposes the configured home folder.
2. Adding a new HTTP API endpoint that returns the home folder path.
3. Wiring the frontend to call that endpoint on initial load and navigate into the home folder by default, falling back gracefully to root.

End goal: Users land directly in their library folder instead of having to navigate from `/` every time, matching the experience of opening KOReader's File Manager on the device.
</objective>

<branch_setup>
Before writing any code:

1. Verify you are on `master` and the working tree is clean.
2. Pull latest: `git pull --ff-only origin master`.
3. Create and check out a new feature branch: `git checkout -b feat/home-folder-default-route`.

**Do NOT merge this branch into master.** Leave it as a feature branch with commits, ready for review. Do not push to remote unless explicitly asked.
</branch_setup>

<context>
- This is a KOReader plugin (Lua) that exposes a small HTTP server (`filesync/httpserver.lua`) backed by a static frontend in `filesync/src/` (compiled into `filesync/static/index.html` via `filesync/build.sh`).
- The plugin already enumerates the device filesystem via `filesync/fileops.lua` and serves directory listings through API routes registered in `httpserver.lua`.
- KOReader is an open-source ebook reader for e-ink devices (Kindle, Kobo, reMarkable, etc.). Its source is at https://github.com/koreader/koreader.
- The user has already confirmed: **if no home folder is configured, fall back to filesystem root (current behavior)** — do NOT show an error or use last-opened folder.

@/Users/abrahamnm/Developer/filesync.koplugin/CLAUDE.md (read first if it exists)
@/Users/abrahamnm/Developer/filesync.koplugin/filesync/httpserver.lua
@/Users/abrahamnm/Developer/filesync.koplugin/filesync/fileops.lua
@/Users/abrahamnm/Developer/filesync.koplugin/filesync/src/js
@/Users/abrahamnm/Developer/filesync.koplugin/main.lua
</context>

<research>
Before writing any code, **thoroughly investigate** how KOReader exposes the home folder. Document findings inline (in your reply, not in committed files) so the implementation choices are auditable.

Specifically determine:

1. **Where the home folder setting lives.** Likely candidates to verify:
   - The global settings file `settings.reader.lua` (key likely `home_dir` or similar).
   - The `G_reader_settings` table in-memory at runtime (e.g. `G_reader_settings:readSetting("home_dir")`).
   - Any FileManager module that exposes a getter.
2. **Whether the value is an absolute path** or device-relative, and whether it can be `nil`/empty when unset.
3. **The canonical KOReader API to read it from a plugin** — prefer using `G_reader_settings:readSetting("home_dir")` if available, since it is the same source the FileManager itself uses. Cite the exact KOReader source file/line you base this on (use WebFetch against the koreader/koreader GitHub repo if needed).
4. **Whether `main.lua` of this plugin already requires/access `G_reader_settings`** — if not, check what the idiomatic require is.
5. **Plugin context**: confirm whether the home folder must be read at request time (in case the user changes it while the server is running) or can be cached at server start. Pick request-time unless you find a clear reason otherwise — the cost is one settings lookup per call to a single endpoint.

Use `WebFetch` and `WebSearch` only if a direct read of KOReader source is needed. Otherwise rely on the conventions visible in this plugin.

For maximum efficiency, when researching, perform independent lookups (KOReader settings docs, FileManager source, plugin examples) **in parallel** rather than sequentially.
</research>

<requirements>

**Backend (Lua, `filesync/httpserver.lua`):**

1. Add a new GET endpoint: `GET /api/home`
   - Returns JSON: `{ "home": "<absolute path or null>" }`
   - If `G_reader_settings:readSetting("home_dir")` returns nil/empty, return `{ "home": null }` (do NOT substitute root server-side — let the frontend decide, so the contract is honest).
   - Include the standard error/status handling pattern already used by other endpoints in this file.
2. The endpoint must be registered alongside the existing routes (follow the same registration pattern — do not invent a new dispatcher).
3. Do not break existing endpoints. The path-listing endpoint should continue to accept arbitrary `?path=` values, including a path equal to home or root.

**Frontend (JS, `filesync/src/js/...`):**

1. On initial page load (before the first directory fetch), call `/api/home`.
   - If `home` is a non-null string, navigate to that path as the initial directory.
   - If `home` is `null` or the request fails, fall back to the existing root-listing behavior (do not block the UI on the home request).
2. Do not change browser history/back-button semantics in a way that traps the user — they should still be able to navigate up out of the home folder to root.
3. The home-folder fetch must not be retried in a tight loop; one attempt is enough. A failure logs to console and falls back silently.
4. After editing JS/CSS, **rebuild the static bundle** by running `./filesync/build.sh` (or whatever the existing build script is — confirm by reading it first). Commit the regenerated `filesync/static/index.html` if and only if the existing project convention does so (check `git log -- filesync/static/index.html` to confirm).

**i18n:**

- If you add any user-visible strings, add them to `filesync/filesync_i18n.lua` and `filesync/src/i18n/` and `filesync/i18n/` following the existing structure. If no new strings are needed, skip this entirely.

</requirements>

<implementation_notes>

- **Why fall back to root, not last-opened folder:** The user explicitly chose root as the fallback. Don't add complexity by reading "last folder" — that's a separate feature.
- **Why `null` over an empty string in the API:** Empty string is ambiguous (could mean "the current dir") in a path context. `null` clearly signals "not configured."
- **Why fetch on the frontend rather than redirect server-side:** A redirect couples the home-folder concept to the root URL semantics. Keeping `/` as a neutral entry and resolving the default on the client keeps the API composable (e.g. for future UI choices like "open last visited" without server changes).
- **Don't add a settings UI for choosing home folder.** KOReader already owns that setting; the plugin should read, not duplicate.
- **Don't cache the home folder in the JS app for the session.** A fresh fetch on each full page load is correct and cheap; users may reconfigure home in KOReader between sessions.

</implementation_notes>

<output>

Files to create or modify (use relative paths from repo root):

- `./filesync/httpserver.lua` — register `GET /api/home` handler.
- `./filesync/src/js/<appropriate-file>.js` — add the home-folder fetch on init and use the result as the initial path. Identify the right file by reading the existing JS during research; do not assume a filename.
- `./filesync/static/index.html` — regenerated by build script (only if convention is to commit it).

Commits (separate, in order):

1. `feat: add /api/home endpoint to expose KOReader home folder`
2. `feat: open KOReader home folder by default in web UI`
3. (optional) `chore: rebuild static bundle` — only if static is normally committed.

Do not push. Do not open a PR. Do not merge to master.

</output>

<verification>

Before declaring complete:

1. **Endpoint smoke test (plan one, since you can't run KOReader from this shell):** Describe how the user can verify on-device — e.g. `curl http://<device-ip>:<port>/api/home` returns expected JSON. Include this as a one-line note in your final reply, not in a committed file.
2. **Lua syntax**: run `luac -p filesync/httpserver.lua` (or the project's existing lint command — check `package.json`, `Makefile`, `.github/workflows/`) and confirm no errors.
3. **Frontend build**: confirm `./filesync/build.sh` (or equivalent) completes without error and that the regenerated bundle still contains the existing app code.
4. **Existing tests**: if `spec/` contains tests for `httpserver.lua` or `fileops.lua`, run them via `busted` (or whatever runner the spec folder uses — check for a `.busted` config or `Makefile` target) and confirm none regress.
5. **Diff sanity check**: `git diff master..HEAD --stat` should show changes only in: `httpserver.lua`, the JS source file you modified, optionally `static/index.html`, and optionally i18n files. Anything else is a red flag.
6. **Branch state**: `git status` clean, on branch `feat/home-folder-default-route`, NOT on master, and master is unchanged.

</verification>

<success_criteria>

- `GET /api/home` returns `{"home": "<path>"}` when home is set in KOReader, `{"home": null}` when not set.
- Loading the web UI at `/` lands the user in the configured home folder; if not set, lands at root (existing behavior preserved).
- No regression in existing path-listing, upload, or download endpoints.
- All changes live on `feat/home-folder-default-route`; `master` is untouched.
- Research findings (which KOReader API was used and why) are stated in the final reply, with at least one citation back to KOReader source.

</success_criteria>
