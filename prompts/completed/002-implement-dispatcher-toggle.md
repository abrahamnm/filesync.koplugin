<objective>
Implement KOReader Dispatcher integration for the FileSync plugin, adding a "Toggle file server" action that users can trigger from Quick Settings or custom gestures. This addresses GitHub issue #15.
</objective>

<context>
This is a KOReader plugin called FileSync. The plugin manages an HTTP file server that lets users browse and transfer files to/from their e-reader via a web browser.

Currently, starting the server requires navigating: Settings → Network → FileSync → Start file server. Users want to trigger this from Quick Settings or a gesture (issue #15).

**Key files to examine:**
- `./main.lua` — Plugin entry point, menu registration, event handlers
- `./filesync/filesyncmanager.lua` — Server lifecycle (`checkBatteryAndStart()`, `stop()`, `_running` state)

**Research results:** Read `./prompts/001-research-results.md` first — it contains the dispatcher API documentation and integration pattern discovered in the research phase. Follow the pattern documented there.
</context>

<requirements>
1. Register a **single toggle action** with KOReader's Dispatcher that:
   - Starts the FileSync server (via `FileSyncManager:checkBatteryAndStart()`) when it's not running
   - Stops the FileSync server (via `FileSyncManager:stop()`) when it's running
   - Uses `FileSyncManager._running` to determine current state

2. Follow the exact dispatcher registration pattern from `./prompts/001-research-results.md`

3. The action should:
   - Have a clear, user-facing name like "Toggle FileSync server" (localized via the plugin's i18n system if applicable)
   - Be categorized appropriately (likely under "network" or similar)
   - Work correctly whether WiFi is on or off (the existing `checkBatteryAndStart` and server start flow already handles WiFi checks)

4. **Minimal changes only** — modify existing files (`main.lua` and possibly `filesyncmanager.lua`), do not create new files unless the dispatcher pattern strictly requires it.
</requirements>

<implementation>
1. First, read `./prompts/001-research-results.md` to understand the dispatcher API
2. Read `./main.lua` to understand the current plugin structure
3. Read `./filesync/filesyncmanager.lua` to understand server state and lifecycle methods
4. Add the dispatcher registration following the researched pattern — this likely involves:
   - Adding an event handler (e.g., `onDispatcherRegisterActions`) in `main.lua`
   - Defining the action metadata and callback
5. Test that the code is syntactically correct by reviewing it carefully

Keep the implementation clean and consistent with the existing code style in `main.lua`.
</implementation>

<output>
Modify files in place:
- `./main.lua` — Add dispatcher registration
- `./filesync/filesyncmanager.lua` — Only if needed (e.g., adding a public toggle method)
</output>

<verification>
Before declaring complete, verify:
- The dispatcher registration follows the pattern from the research results exactly
- The toggle logic correctly checks `FileSyncManager._running` state
- The `FileSyncManager` module is properly required/loaded (note: it's lazy-loaded in the current code)
- No existing functionality is broken (menu items, event handlers still work)
- Code style matches the existing codebase (indentation, naming conventions, etc.)
</verification>

<success_criteria>
- A "Toggle FileSync server" action is registered with KOReader's Dispatcher
- The action starts the server when stopped and stops it when running
- Users can assign this action to a gesture or find it in Quick Settings
- Existing menu-based start/stop continues to work unchanged
</success_criteria>
