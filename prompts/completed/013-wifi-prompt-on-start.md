<objective>
Replace the "WiFi is not enabled" warning shown when starting the FileSync server with a flow that asks KOReader itself to enable WiFi (prompting the user via KOReader's standard network UI), then proceeds to start the server once WiFi is up. Also update the updater code path that currently shows the same warning.

End goal: a user who taps "Start FileSync server" while WiFi is off should be guided through KOReader's normal WiFi-enable prompt and the server should start automatically once a connection is established — instead of just being told to turn WiFi on themselves and then having to tap Start again.
</objective>

<context>
This is a KOReader plugin (Lua). The current behavior is in two places:

- `filesync/filesyncmanager.lua:184` — `FileSyncManager:start(silent)` checks `NetworkMgr:isWifiOn()` at line 198 and aborts with an `InfoMessage` if WiFi is off.
- `filesync/updater.lua:308` — the updater performs the same `isWifiOn` check around line 311 before doing an HTTP request.

KOReader's `ui/network/manager.lua` exposes helpers for asking the user to turn WiFi on and for running a callback once the network is ready. Examples seen across the KOReader codebase include `NetworkMgr:promptWifiOn(complete_callback)`, `NetworkMgr:beforeWifiAction(callback)`, and `NetworkMgr:runWhenOnline(callback)` — but the exact set of methods, their arguments, and which one is appropriate must be verified against the installed KOReader source before writing code.

@filesync/filesyncmanager.lua
@filesync/updater.lua
@main.lua
@CLAUDE.md
</context>

<research>
**This task is research-gated. You must establish whether KOReader exposes a documented API for plugins to ask the user to enable WiFi and trigger that flow before writing any code. If no such API exists or is intended for plugin use, stop and report back — do not implement a workaround.**

Do all of the following, in order:

1. **Read KOReader's official documentation first**, not just source code. Plugin-facing APIs are what we need; internal helpers that happen to work today may break tomorrow. Check:
   - The KOReader developer/plugin docs site: https://koreader.rocks/doc/ (and any subpages covering plugin development, network manager, or UI events).
   - The repo's plugin-authoring guides — README and `doc/` directory in `koreader/koreader` on GitHub.
   - Any in-tree docstrings on `frontend/ui/network/manager.lua` that mark methods as public/plugin-facing vs. internal.
   - Use WebFetch / WebSearch as needed; cite the URL(s) you relied on in your reply.

2. **Then locate the source** to confirm what the docs describe actually exists in the installed version. Try:
   - `/Applications/KOReader.app/Contents/koreader/frontend/ui/network/manager.lua` (macOS install)
   - `~/.config/koreader/` (config only, no source — skip if absent)
   - GitHub `koreader/koreader` at the latest tag, via WebFetch, as a fallback.

3. From the docs and source together, answer these questions explicitly:
   - **Can a plugin ask KOReader to enable WiFi?** Yes/no, and which method.
   - How to register a callback that fires **after** WiFi is connected and an IP is assigned (not just "user said yes").
   - Whether the helper handles the "already on but disconnected" case, and whether it handles user-cancellation gracefully.
   - Whether the helper is synchronous or schedules work via `UIManager`.
   - Whether the method is documented as plugin-facing API or merely an internal helper (this affects whether we should use it at all).

4. Cross-check by searching other KOReader plugins (OPDS browser, news downloader, sync plugins) for real-world call patterns. Pattern-match against working production code rather than guessing.

5. **Report findings before editing.** In your reply, before any file changes, output:
   - One paragraph summarizing what KOReader's docs/source say.
   - The specific method you'll use and why.
   - The doc URL(s) and source file paths you relied on.
   - **If the answer is "KOReader does not expose this to plugins", STOP. Do not edit any files. Report that finding and recommend keeping the current warning (or a clearer wording).** The user explicitly wants to know whether this is possible — a "no" answer is a valid and complete result.

Only proceed to the requirements/implementation sections below if research confirms a suitable plugin-facing API exists.
</research>

<requirements>
1. In `filesync/filesyncmanager.lua` `FileSyncManager:start(silent)`:
   - When WiFi is off, instead of showing the warning and returning, call the chosen NetworkMgr helper to prompt the user to enable WiFi.
   - Once WiFi is confirmed up **and** an IP is available, continue the existing start sequence (IP resolution, HTTP server creation, QR display).
   - If the user cancels the WiFi prompt, exit silently — no error toast, since the user explicitly declined.
   - Preserve the `silent` parameter semantics: when `silent == true`, do not show *any* UI (including the WiFi prompt) — just bail as today.
   - Keep the existing "Could not determine device IP address" guard intact for the post-connect case.

2. In `filesync/updater.lua` around line 308–313:
   - Apply the same change so that update checks initiated by the user trigger the WiFi prompt rather than aborting with a warning. If the updater can be invoked from a non-interactive path, keep a silent fallback there too.

3. Do not change any other behavior. Do not refactor surrounding code. Do not add new helper modules unless the same pattern is needed in a third place.

4. Translations: the existing English warning string `"WiFi is not enabled. Please turn on WiFi first."` may become unused. If so, remove it from `filesyncmanager.lua` and **do not** delete it from `.po` files (the i18n pipeline handles that). If a new user-visible string is introduced, mark it with `_(...)` so it gets picked up by the translation extractor.
</requirements>

<implementation>
- Read `filesync/filesyncmanager.lua` start() in full first; the post-WiFi logic must be reachable from inside the connect callback, so you may need to extract the "after WiFi is on" body into a local function and pass it as the callback. Keep the extracted function local to `start` — do not promote it to a method.
- Mirror the same shape in `updater.lua` so both call sites are consistent.
- If the chosen NetworkMgr helper does not guarantee an IP is assigned by the time the callback fires, keep the existing `getLocalIP()` retry/guard — do not assume the network is fully up just because WiFi turned on.
- Avoid swallowing errors. If the HTTP server fails to start *after* WiFi comes up, the existing error toast must still fire.

Why these constraints matter:
- The `silent` mode is used by auto-start flows; popping a WiFi dialog during auto-start would be jarring and is explicitly not what `silent` callers want.
- KOReader's WiFi prompt is async on most devices — synchronous-looking code that "waits" for WiFi will deadlock the UI loop.
- Removing the English string but leaving it in `.po` files would create false "untranslated" entries on the next extraction pass.
</implementation>

<output>
Modify in place:
- `./filesync/filesyncmanager.lua` — replace the WiFi-off warning branch with a prompt+callback flow.
- `./filesync/updater.lua` — same change for the updater's pre-flight WiFi check.

Do not create new files. Do not write a summary doc — the user has a memory rule against committing generated review/analysis docs (`feedback_no_commit_docs`).
</output>

<verification>
Before declaring complete:

1. Re-read both modified files end-to-end and confirm:
   - `silent == true` callers never trigger UI in any branch.
   - The post-WiFi continuation runs the original IP/server-start logic unchanged.
   - User cancellation of the WiFi prompt does not leave `self._running` or `self._server` in an inconsistent state.

2. Run any existing busted/unit tests: `./spec` contains specs — check for `filesyncmanager_spec.lua` and run it via the project's test command (look at `CLAUDE.md` or the README for the exact invocation). If tests for the start() WiFi branch exist, update them; if they don't, do not invent a test harness — note in your reply that no test exists for this path.

3. Confirm no stray references to the removed warning string remain in `.lua` files (grep for `"WiFi is not enabled"`).

4. Output a one-paragraph summary of: (a) which NetworkMgr method you used and why, (b) the two changed files with line ranges, (c) anything you did NOT change but considered. No code in the summary.
</verification>

<success_criteria>
- Tapping "Start FileSync server" with WiFi off triggers KOReader's standard WiFi-enable prompt.
- After the user accepts and WiFi connects, the server starts and the QR code displays without a second tap.
- After the user declines, no error message is shown.
- `silent` callers (auto-start) behave exactly as before.
- Updater's WiFi check is updated consistently.
- No new files; no doc artifacts; only the two source files change.
</success_criteria>
