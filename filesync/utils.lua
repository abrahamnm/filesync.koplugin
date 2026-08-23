--- Shared utility functions for the FileSync plugin.
--- Provides common helpers used across multiple modules:
---   - getPluginDir(): returns the absolute path to the plugin root directory
---   - shellEscape(s): escapes a string for safe use in shell commands
---   - restartKOReader(): restarts KOReader only on platforms that support it

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
--- UIManager:restartKOReader() simply exits with code 85 and relies on the
--- launcher shell script to relaunch the process.  Android has no such
--- wrapper (it runs as a NativeActivity), so calling it there just quits the
--- app -- which is why KOReader gates its own "Restart KOReader" menu entry
--- on Device:canRestart().  Where a restart is unavailable, force a full
--- screen refresh instead, which is all the restart was buying us.
--- @return boolean: true if a restart was requested, false if it was skipped
function Utils.restartKOReader()
    local Device = require("device")
    local UIManager = require("ui/uimanager")
    if Device:canRestart() then
        UIManager:restartKOReader()
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

return Utils
