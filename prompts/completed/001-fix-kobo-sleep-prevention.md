<objective>
Fix the sleep/suspension prevention mechanism in filesync.koplugin so that the device stays awake and the file server remains accessible while running, specifically on Kobo devices (tested on Kobo Libra Colour).

Currently, `UIManager:preventStandby()` is called when the server starts, but the device still goes to sleep/suspend after the configured timeout in KOReader settings. When the device wakes up, WiFi is disconnected and the server is stopped, requiring the user to manually re-enable WiFi and restart the server.

The goal is to keep the device fully awake (no sleep, no suspend) and WiFi connected for the entire duration the file server is running.
</objective>

<context>
This is a KOReader plugin written in Lua. KOReader runs on e-ink devices (Kobo, Kindle, etc.) and has its own power management abstraction layer.

Key files to examine:
- `./main.lua` — Plugin entry point with suspend/resume event handlers (lines 85-107)
- `./filesync/filesyncmanager.lua` — Server lifecycle, current preventStandby/allowStandby implementation (lines 275-289)
- `./filesync/httpserver.lua` — HTTP server with UIManager-based polling (0.1s intervals)

Read the `CLAUDE.md` file first for project conventions if it exists.

**Current approach (insufficient):**
1. `FileSyncManager:preventStandby()` calls `UIManager:preventStandby()` on server start
2. `FileSyncManager:allowStandby()` calls `UIManager:allowStandby()` on server stop
3. `onSuspend`/`onEnterStandby` events stop the server; `onResume`/`onLeaveStandby` restart it

**Why it fails:** On Kobo devices, there are multiple power management levels:
- **Standby** (screen off, light sleep) — `UIManager:preventStandby()` may address this
- **Suspend** (deep sleep, WiFi drops) — NOT prevented by current code
- **Auto-suspend** (KOReader's own timer-based suspend) — NOT prevented by current code

KOReader's power management APIs (found in `frontend/device/generic/powerd.lua` and `frontend/ui/uimanager.lua` in the KOReader source):
- `UIManager:preventStandby()` / `UIManager:allowStandby()` — prevents standby (light sleep)
- `powerd:preventSuspend()` / `powerd:allowSuspend()` — prevents device suspend (added in newer KOReader, not available in all versions)
- `Device:setAutoSuspend(false)` or similar — prevents the auto-suspend timer
- `NetworkMgr:setWifiKeepalive(true)` — may help keep WiFi alive on some devices
</context>

<research>
Before implementing, research the KOReader source code and plugin ecosystem to understand the correct way to prevent device sleep:

1. Search the existing codebase for any KOReader API references related to power management
2. Look at how other KOReader plugins handle keeping the device awake (e.g., the calibre plugin, SSH plugin, or any network-related plugin)
3. Examine KOReader's `UIManager` source to understand the difference between `preventStandby()` and suspend prevention
4. Check if `Device.powerd` provides `preventSuspend()` / `allowSuspend()` methods
5. Investigate whether KOReader's auto-suspend timer needs to be explicitly disabled
6. Check if there's a WiFi keepalive mechanism available through `NetworkMgr`
</research>

<requirements>
1. **Prevent ALL levels of sleep/suspend** while the file server is running:
   - Prevent standby (screen-off light sleep) — already done via `UIManager:preventStandby()`
   - Prevent device suspend (deep sleep that kills WiFi)
   - Prevent KOReader's auto-suspend timer from triggering

2. **Keep WiFi alive** for the entire duration the server is running

3. **Gracefully handle API availability**: Not all KOReader versions have the same APIs. Use feature detection (`if Device.powerd.preventSuspend then ...`) rather than assuming methods exist

4. **Clean up properly**: When the server stops, restore ALL power management settings to their previous state (allow standby, allow suspend, restore auto-suspend timer)

5. **Maintain the existing suspend/resume recovery logic** as a safety net — if the device somehow suspends despite prevention, the existing `onSuspend`/`onResume` handlers should still work to restart the server

6. **Do not break Kindle compatibility**: Any Kobo-specific code should be guarded with device checks
</requirements>

<implementation>
Focus changes on these files:
- `./filesync/filesyncmanager.lua` — Enhance `preventStandby()` and `allowStandby()` to also handle suspend prevention, auto-suspend timer, and WiFi keepalive
- `./main.lua` — May need updates to event handlers if new lifecycle events are relevant

Approach:
1. In `preventStandby()`, add calls to prevent suspend and disable auto-suspend timer
2. In `allowStandby()`, restore suspend and auto-suspend timer settings
3. Add WiFi keepalive if the API is available
4. Use proper feature detection for all optional APIs
5. Track previous auto-suspend timeout value so it can be restored

Keep the implementation simple and focused. Do not refactor unrelated code.
</implementation>

<verification>
After implementing:
1. Verify the code has no syntax errors by reviewing it carefully
2. Ensure all new API calls are wrapped in feature detection checks
3. Ensure `allowStandby()` properly reverses everything `preventStandby()` does
4. Ensure the `_standby_prevented` flag (or equivalent) guards against double-prevention
5. Verify that the stop() function path always calls allowStandby() to clean up
6. Check that the onSuspend/onResume handlers still function as a fallback safety net
</verification>

<success_criteria>
- The file server stays accessible without the device going to sleep or suspend
- WiFi remains connected for the duration of the server running
- Stopping the server restores normal power management behavior
- Code gracefully handles missing APIs (older KOReader versions)
- Kindle compatibility is not broken
</success_criteria>
