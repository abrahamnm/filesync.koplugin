<objective>
Implement the plugin update checker feature described in GitHub issue #11 (https://github.com/abrahamnm/filesync.koplugin/issues/11).

Create a new branch from master, then develop a complete update mechanism that allows users to check for new versions of the FileSync KOReader plugin, and automatically download and install updates.
</objective>

<context>
This is a KOReader plugin (`filesync.koplugin`) — a wireless file manager for e-readers (Kindle, Kobo, etc.). It's written in Lua and uses KOReader's widget framework.

Key files to examine before making changes:
- `_meta.lua` — plugin metadata (currently missing a `version` field)
- `main.lua` — plugin entry point, menu registration, About dialog (hardcodes `v1.0.0` but latest release is `v1.1.0`)
- `filesync/filesyncmanager.lua` — main manager module, good reference for KOReader UI patterns (InfoMessage, ConfirmBox, NetworkMgr, UIManager, G_reader_settings)
- `filesync/httpserver.lua` — already uses LuaSocket (`require("socket")`), reference for networking patterns

Also read CLAUDE.md if it exists for project conventions.

The GitHub repository is `abrahamnm/filesync.koplugin`. Releases are published as ZIP archives that users extract into their KOReader plugins directory.
</context>

<requirements>

1. **Create a feature branch**
   - Pull latest from master first
   - Branch name: `feature/update-checker` (or similar descriptive name from issue #11)

2. **Add `version` field to `_meta.lua`**
   - Add `version = "1.1.0"` to the metadata table
   - This makes the version machine-readable and enables compatibility with community update managers (appstore.koplugin, updatesmanager.koplugin)

3. **Fix version in `main.lua` About dialog**
   - The About dialog on line 76 hardcodes `"FileSync v1.0.0"` — change it to read the version from `_meta.lua` instead, so there's a single source of truth
   - Load the version at the top of main.lua or within the callback from `_meta.lua`

4. **Create an updater module** (`filesync/updater.lua`)
   - Thoroughly consider the architecture before implementing. This module should handle:
     - **Version checking**: Query `https://api.github.com/repos/abrahamnm/filesync.koplugin/releases/latest` using KOReader's HTTP capabilities
     - **Version comparison**: Parse semantic version strings (e.g., "1.1.0" vs "1.2.0") and determine if remote is newer
     - **JSON parsing**: Use KOReader's built-in JSON module (typically `require("json")` or `require("rapidjson")`) to parse the GitHub API response
     - **Download**: Download the release ZIP asset from the GitHub release
     - **Install**: Extract the ZIP and replace the plugin folder. Research how KOReader handles file extraction — it may bundle `unzip` as a command, or you may need to use `io.popen` with system `unzip`. Consider that the plugin is located at the path where `_meta.lua` lives.
     - **Error handling**: Handle network errors, JSON parse errors, missing releases gracefully with user-friendly messages
     - **Caching**: Store the last check timestamp in `G_reader_settings` to avoid excessive API calls (e.g., check at most once per day automatically, but allow manual checks anytime)

5. **Add "Check for updates" menu item in `main.lua`**
   - Add a new menu entry in the `sub_item_table` (before the "About" item)
   - When clicked:
     - Check if network is available (use `NetworkMgr`)
     - Query GitHub for latest release
     - If update available: show a ConfirmBox with the new version and changelog summary, with an "Update now" button that triggers download + install
     - If already up to date: show an InfoMessage saying so
     - If network error: show an InfoMessage with the error
   - After successful install, prompt user to restart KOReader

6. **Internationalization**
   - Wrap all user-facing strings with the `_()` translation function (follow the existing pattern in the codebase)
   - Do NOT add translations to the .po files — just ensure strings are wrapped for future translation

</requirements>

<constraints>
- Use ONLY libraries available in KOReader's runtime (LuaSocket, LuaSec, json/rapidjson, lfs, standard Lua). Do NOT introduce external dependencies.
- Follow the existing code style: lazy `require()` calls inside functions (as seen in main.lua callbacks), same formatting conventions.
- The plugin runs on e-readers with limited resources — keep the implementation lightweight.
- GitHub API has rate limits (60 requests/hour for unauthenticated). Cache results and don't check on every menu open.
- The plugin directory path varies by device (Kindle: `/mnt/us/koreader/plugins/`, Kobo: `.adds/koreader/plugins/`). Determine the path dynamically from the plugin's own location.
- HTTPS is required for GitHub API — ensure SSL/TLS is handled (LuaSec's `ssl.https` or KOReader's HTTP utilities).
- When replacing plugin files during update, be careful not to delete the plugin while it's running. Consider writing to a temporary location first, then moving files.
</constraints>

<implementation_guidance>
- Look at how `filesyncmanager.lua` uses `NetworkMgr` for network state — follow the same patterns
- For the plugin's own path, you can derive it from the module loading path or use `debug.getinfo` — examine how other parts of the code reference local files (e.g., `filesync/static/index.html` loading in httpserver.lua)
- For HTTP requests, explore what's available: try `require("socket.http")` and `require("ssl.https")` — the GitHub API requires HTTPS and returns JSON with a `tag_name` field for the version and `assets` array for download URLs
- For ZIP extraction, check if KOReader provides a Lua-accessible unzip utility, or fall back to `os.execute("unzip ...")` which is available on most KOReader-supported devices
- Use `G_reader_settings:readSetting()` / `G_reader_settings:saveSetting()` for persisting the last update check timestamp (follow the pattern used for `filesync_port`)
</implementation_guidance>

<verification>
Before declaring complete, verify:
1. `_meta.lua` contains a `version` field
2. `main.lua` About dialog reads version from `_meta.lua` (no hardcoded version string)
3. The updater module exists at `filesync/updater.lua` with version check, download, and install functions
4. The "Check for updates" menu item appears in `main.lua`
5. All user-facing strings are wrapped with `_()`
6. No external dependencies were introduced
7. Error cases are handled (no network, API errors, download failures)
</verification>

<success_criteria>
- A new branch exists with all changes committed
- Users can tap "Check for updates" in the FileSync menu to check for and install plugin updates
- Version is managed from a single source (`_meta.lua`)
- The update flow: check → confirm → download → extract → prompt restart
- Graceful handling of all error conditions
</success_criteria>
