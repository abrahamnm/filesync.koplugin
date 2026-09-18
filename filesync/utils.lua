--- Shared utility functions for the FileSync plugin.
--- Provides common helpers used across multiple modules:
---   - getPluginDir(): returns the absolute path to the plugin root directory
---   - shellEscape(s): escapes a string for safe use in shell commands
---   - restartKOReader(): restarts KOReader only on platforms that support it
---   - refreshFileList(): refreshes the file manager after files change on disk

local Utils = {}

-- Cached plugin directory path (computed once on first call)
local _cached_plugin_dir = nil

--- Get the plugin root directory path.
--- Computes the path from the source location of this file and caches the result.
--- @return string: absolute path to the plugin directory (e.g., "/mnt/us/koreader/plugins/filesync.koplugin")
function Utils.getPluginDir()
    if _cached_plugin_dir then return _cached_plugin_dir end
    local info = debug.getinfo(1, "S")
    local script_path = info.source:match("@(.+)")
    if script_path then
        -- This file is filesync/utils.lua, go up one level to get the plugin root
        local filesync_dir = script_path:match("(.+)/[^/]+$") or "."
        _cached_plugin_dir = filesync_dir:match("(.+)/[^/]+$") or "."
    else
        _cached_plugin_dir = "."
    end
    return _cached_plugin_dir
end

--- Escape a string for safe use in a shell command (wrap in single quotes).
--- @param s string|nil: the string to escape
--- @return string: the shell-safe escaped string
function Utils.shellEscape(s)
    if not s then return "''" end
    -- Replace each single quote with: end quote, escaped quote, start quote
    local escaped = s:gsub("'", "'\\''")
    return "'" .. escaped .. "'"
end

--- Restart KOReader, but only on platforms where a restart actually works.
--- Broadcasting a "Restart" event is how KOReader restarts itself (it is what
--- both its own menu entry and the dispatcher action do): DeviceListener picks
--- it up and hands it to ReaderMenu/FileManagerMenu:exitOrRestart(), which
--- closes the active ReaderUI/FileManager *before* quitting with exit code 85,
--- the magic number the launcher script watches for.
---
--- That teardown is not optional.  UIManager:restartKOReader() is only
--- `quit(85)`: it drops the window stack and the task queue on the floor
--- without closing a single widget, so KOReader exits -- and closes its Lua
--- state -- with the document still open and every plugin still live.  Calling
--- it directly is what left devices wedged on a frozen screen instead of
--- restarting (issue #49).
---
--- Android has no launcher wrapper (KOReader runs as a NativeActivity), which
--- is why KOReader gates its own "Restart KOReader" menu entry on
--- Device:canRestart().  Where a restart is unavailable, force a full screen
--- refresh instead.
--- @return boolean: true if a restart was requested, false if it was skipped
function Utils.restartKOReader()
    local Device = require("device")
    local UIManager = require("ui/uimanager")
    if Device:canRestart() then
        local Event = require("ui/event")
        UIManager:broadcastEvent(Event:new("Restart"))
        return true
    end
    UIManager:setDirty("all", "full")
    return false
end

--- Whether KOReader can restart itself on this device.
--- @return boolean
function Utils.canRestartKOReader()
    local Device = require("device")
    return Device:canRestart() and true or false
end

--- Refresh the file manager so files added over the network show up, and
--- repaint the screen.  This is the same thing KOReader's own download-to-disk
--- plugins do once they are done writing files; when a book is open instead
--- there is no FileManager to refresh, and the next trip Home builds a fresh
--- one anyway.
function Utils.refreshFileList()
    local UIManager = require("ui/uimanager")
    local FileManager = require("apps/filemanager/filemanager")
    if FileManager.instance then
        FileManager.instance:onRefresh()
    end
    UIManager:setDirty("all", "full")
end

return Utils
