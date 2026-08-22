<objective>
Enhance the `filesync.koplugin` web UI's directory listings so that ebook files are displayed with their **Title** and **Author** (sourced from KOReader's existing metadata cache) instead of only the raw filename.

End goal: When the user browses their library at `http://<device-ip>:<port>/`, books they've already opened in KOReader should show as `"<Title> — <Author>"` (or similar), giving the web UI parity with KOReader's own File Manager / History view, **without** the plugin re-parsing ebook files itself.
</objective>

<branch_setup>
Before writing any code:

1. Verify you are on `master` and the working tree is clean.
2. Pull latest: `git pull --ff-only origin master`.
3. Create and check out a new feature branch: `git checkout -b feat/metadata-cache-integration`.

**Do NOT merge this branch into master.** Leave it as a feature branch with commits, ready for review. Do not push to remote unless explicitly asked.

Note: a sibling prompt (`001-home-folder-api-and-default-route.md`) is being executed in parallel on a different branch. Do NOT touch the same JS file regions unless strictly necessary; if conflicts seem likely, scope your JS edits to the listing-rendering function only and leave routing/init logic alone.
</branch_setup>

<context>
- This is a KOReader plugin (Lua) that exposes an HTTP server (`filesync/httpserver.lua`) and a small frontend in `filesync/src/`.
- KOReader maintains a **metadata cache** for ebook files it has opened. This is what populates the title/author shown in KOReader's own File Manager view. We want to read from that cache rather than parsing ebook files in the plugin.
- KOReader is at https://github.com/koreader/koreader. Two known mechanisms for metadata access (verify these in research):
  - **Sidecar `.sdr` directories** colocated with each book (e.g. `MyBook.epub.sdr/metadata.epub.lua`) containing serialized Lua tables with `doc_props` (title, authors, etc.).
  - **A central book info / cover cache** maintained by KOReader (e.g. via `BookInfoManager` from the coverbrowser plugin, or `DocSettings`).
- The user has already confirmed: **if a book has no cached metadata, just show the filename (current behavior)**. Do NOT parse files, do NOT hide them, do NOT lazily generate metadata.

@/Users/abrahamnm/Developer/filesync.koplugin/CLAUDE.md (read first if it exists)
@/Users/abrahamnm/Developer/filesync.koplugin/filesync/httpserver.lua
@/Users/abrahamnm/Developer/filesync.koplugin/filesync/fileops.lua
@/Users/abrahamnm/Developer/filesync.koplugin/filesync/src/js
@/Users/abrahamnm/Developer/filesync.koplugin/filesync/mobi.lua
</context>

<research>
**Thoroughly investigate** how KOReader stores and exposes book metadata. Document findings inline (in your reply, not as a committed `.md`) so the chosen approach is auditable.

Specifically determine, with at least one citation to KOReader source for each:

1. **Sidecar `.sdr` format**:
   - For a book at `/some/path/Book.epub`, where exactly does KOReader store its sidecar? (`/some/path/Book.sdr/`? `/some/path/Book.epub.sdr/`? Both, depending on version?)
   - What file inside it contains the title/author? (`metadata.epub.lua`? `metadata.lua`?)
   - What's the schema — is it a returned Lua table with `doc_props.title` / `doc_props.authors`?
2. **Central cache (BookInfoManager / DocSettings)**:
   - Is there a global SQLite or Lua cache that aggregates metadata for ALL books, regardless of whether you have the sidecar path?
   - If yes: where does it live (path), what's the format, and is there a documented public API to read it from a plugin context?
3. **Which approach is most appropriate for this plugin:**
   - Sidecar reads are simple and per-file (no extra deps), but only work for books the user has actually opened.
   - Central cache is faster for big directories but adds a dependency on internal modules and a SQLite or similar reader.
   - **Default recommendation**: start with sidecar reads since they're zero-dependency and align with the user's "filename fallback if no metadata" requirement. Confirm or override this based on what the research reveals.
4. **Performance**: how many books might a single directory listing contain in practice? Is there a risk of stat'ing/reading hundreds of `.sdr` directories per request? Decide whether to: (a) read sidecars synchronously inline, (b) read them in a bounded batch, or (c) provide a separate `/api/metadata?path=...` endpoint that the frontend calls per-file lazily.
5. **Existing helpers in this plugin**: is there already a metadata or sidecar reader in `filesync/`? Check `mobi.lua`, `fileops.lua`, and `utils.lua` before adding new code.

For maximum efficiency, run independent lookups (KOReader source on `DocSettings`, sidecar examples, BookInfoManager source) **in parallel**, and reflect on findings before deciding the approach.
</research>

<requirements>

**Backend (Lua):**

1. Add a metadata-loading helper. Place it in a sensible existing module (most likely `filesync/fileops.lua` or a new `filesync/metadata.lua` if that's cleaner — decide based on size and cohesion).
2. Given an absolute path to an ebook file, the helper returns a small table like `{ title = "...", authors = "..." }`, or `nil` if no metadata is available.
   - Read from the KOReader sidecar (or central cache, depending on research outcome).
   - **Never** fall back to parsing the ebook file itself — that's explicitly out of scope.
   - Be defensive: malformed/missing sidecar files must not raise; just return `nil`.
3. Integrate into the directory-listing endpoint:
   - For each file entry that looks like an ebook (existing extension check in this plugin — reuse it; don't duplicate the list), attach `title` and `authors` to the JSON response when available.
   - Files without metadata simply omit those fields (or set them to `null`) — frontend will fall back to filename.
4. **Decide synchronous-inline vs lazy endpoint** based on the perf research above. If you choose lazy, also add `GET /api/metadata?path=<absolute path>` returning `{ title, authors }` or 404. Default to synchronous-inline unless research shows it's too slow.
5. Make sure the response shape is **backwards-compatible**: existing fields stay, new fields are additive.

**Frontend (JS, `filesync/src/js/...`):**

1. In the directory listing render function (find it during research — do not assume the filename), when an entry has `title`, render `"<title> — <authors>"` instead of the filename. If only `title` is present, render just the title. If neither, render the filename (current behavior).
2. Keep the filename available somewhere accessible (tooltip, secondary line, or `title=` attribute on the row) so the user can still see the actual file when they need to.
3. If you went with the lazy `/api/metadata` endpoint, fetch metadata after the listing renders, batched or rate-limited, and update rows in place. Do not block the initial listing render on metadata.
4. Rebuild the static bundle via `./filesync/build.sh` (or whatever build command the project uses — confirm by reading it). Only commit the regenerated `filesync/static/index.html` if that's the existing project convention (check `git log -- filesync/static/index.html`).

**i18n:**

- If you introduce user-visible strings (e.g. "by " between title and author), add them to `filesync/filesync_i18n.lua` and the JS i18n files following the existing structure. If you can implement without new strings (e.g. plain `" — "` separator), prefer that.

</requirements>

<implementation_notes>

- **Why read the KOReader cache instead of parsing ebooks ourselves:** The plugin already has `mobi.lua` for limited parsing, but proper EPUB/PDF metadata extraction is a maintenance liability. KOReader has already done the work for any book the user has opened — we should reuse it.
- **Why filename-only fallback:** The user explicitly chose this. Do NOT add lazy parsing or "scan all books on first load" — that turns a nice listing into a heavy operation and changes the contract.
- **Why a helper that returns `nil` rather than throwing:** Listings span many files; a single corrupt sidecar must not break the whole directory view.
- **Why backwards-compatible JSON shape:** The same endpoint is used by other UI code paths (uploads, navigation). Don't force them all to know about title/authors.
- **Don't write metadata.** This plugin is a reader of KOReader's cache, not a writer. No edits to `.sdr/` contents.

</implementation_notes>

<output>

Files to create or modify (relative paths from repo root):

- `./filesync/fileops.lua` (or new `./filesync/metadata.lua`) — sidecar/cache reader helper.
- `./filesync/httpserver.lua` — attach title/authors to file entries in the listing endpoint, and (only if you chose lazy) add `GET /api/metadata`.
- `./filesync/src/js/<listing-render-file>.js` — render title + author when present, fall back to filename. Identify the file via research.
- `./filesync/static/index.html` — regenerated by build script (only commit if convention is to commit it).
- (Maybe) `./filesync/filesync_i18n.lua` and `./filesync/i18n/*` and `./filesync/src/i18n/*` — only if new strings are introduced.

Commits (separate, in order):

1. `feat: read KOReader metadata cache (title/author) for ebook files`
2. `feat: show book title and author in web UI listings`
3. (optional) `chore: rebuild static bundle` — only if static is normally committed.

Do not push. Do not open a PR. Do not merge to master.

</output>

<verification>

Before declaring complete:

1. **Lua syntax**: `luac -p filesync/httpserver.lua filesync/fileops.lua` (and any new files). No errors.
2. **Spec tests**: if `spec/` contains tests for the modules you touched, run them (check for `.busted` config or `Makefile` target). No regressions.
3. **Frontend build**: `./filesync/build.sh` (or equivalent) completes; bundle still contains existing app code.
4. **Manual verification plan (state in your final reply, since you can't run KOReader from this shell):**
   - `curl http://<device-ip>:<port>/api/list?path=<a-folder-with-opened-books>` → entries should include `title`/`authors` for files that have sidecars; should omit them for files that don't.
   - Browse the web UI to that folder; opened books show titles, never-opened books show filenames; nothing is hidden.
5. **Defensive check**: temporarily corrupt a sidecar `.lua` file in your test setup (or describe how the user would) and verify the listing endpoint still responds 200, just without metadata for that file. Don't commit the corruption.
6. **Diff sanity check**: `git diff master..HEAD --stat` should show only the files listed in `<output>`. Anything else is a red flag.
7. **Branch state**: `git status` clean, on branch `feat/metadata-cache-integration`, NOT on master, master unchanged.
8. **Conflict awareness**: confirm you did NOT modify the same JS init/routing region that the parallel `feat/home-folder-default-route` branch is editing. If you had to, call it out explicitly in the final reply so the human can resolve when the two branches eventually integrate.

</verification>

<success_criteria>

- Directory listings expose `title` and `authors` fields for ebooks that have a KOReader metadata cache entry.
- Web UI renders books as `"<Title> — <Author>"` when metadata is present, falls back to filename otherwise.
- No regressions: files without sidecars, malformed sidecars, and non-ebook files all still appear correctly in the listing.
- The plugin does NOT parse ebook contents itself for this feature — only reads KOReader's existing cache.
- All changes live on `feat/metadata-cache-integration`; `master` is untouched.
- Research findings (which KOReader storage was used, why, and citations to KOReader source) are stated in the final reply.

</success_criteria>
