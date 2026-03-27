local WidgetContainer = require("ui/widget/container/widgetcontainer")
local ok_i18n, plugin_gettext = pcall(require, "filesync/filesync_i18n")
local _ = ok_i18n and plugin_gettext or require("gettext")
local T = require("ffi/util").template

-- Determine plugin directory from this file's path
local _plugin_dir = debug.getinfo(1, "S").source:match("@(.+)/[^/]+$") or "."
local _meta = dofile(_plugin_dir .. "/_meta.lua")

local FileSync = WidgetContainer:extend{
    name = "filesync",
    is_doc_only = false,
}

local plugin_meta_cache = nil

local function getPluginMeta()
    if plugin_meta_cache ~= nil then
        return plugin_meta_cache or nil
    end

    local info = debug.getinfo(1, "S")
    local script_path = info and info.source and info.source:match("@(.+)")
    local plugin_dir = script_path and script_path:match("(.+)/[^/]+$") or "."
    local ok, meta = pcall(dofile, plugin_dir .. "/_meta.lua")
    if ok and type(meta) == "table" then
        plugin_meta_cache = meta
    else
        plugin_meta_cache = false
    end

    return plugin_meta_cache or nil
end

function FileSync:init()
    self.ui.menu:registerToMainMenu(self)
end

function FileSync:addToMainMenu(menu_items)
    local FileSyncManager = require("filesync/filesyncmanager")
    local sub_items = {
        {
            text = _("Server status"),
            checked_func = function()
                return FileSyncManager:isRunning()
            end,
            callback = function()
                if FileSyncManager:isRunning() then
                    FileSyncManager:stop()
                else
                    FileSyncManager:checkBatteryAndStart()
                end
            end,
            keep_menu_open = true,
        },
        {
            text = _("Safe mode"),
            checked_func = function()
                return FileSyncManager:getSafeMode()
            end,
            callback = function()
                FileSyncManager:setSafeMode(not FileSyncManager:getSafeMode())
            end,
            keep_menu_open = true,
        },
        {
            text = _("Server port"),
            callback = function()
                FileSyncManager:configurePort()
            end,
            keep_menu_open = true,
        },
        {
            text = _("Show QR code"),
            enabled_func = function()
                return FileSyncManager:isRunning()
            end,
            callback = function()
                FileSyncManager:showQRCode()
            end,
            keep_menu_open = false,
        },
        {
            text = _("Check for updates"),
            callback = function()
                local Updater = require("filesync/updater")
                Updater:checkForUpdates()
            end,
            keep_menu_open = true,
        },
        {
            text = _("About"),
            callback = function()
                local UIManager = require("ui/uimanager")
                local InfoMessage = require("ui/widget/infomessage")
                local meta = getPluginMeta() or {}
                local version = meta.version or "dev"
                UIManager:show(InfoMessage:new{
                    text = T(_("FileSync v%1\n\nWireless file manager for KOReader.\n\nStart the server, scan the QR code with your phone, and manage your books from any browser on the same WiFi network.\n\nProject:\ngithub.com/TavaresBugs/filesync.koplugin"), version),
                })
            end,
            keep_menu_open = true,
        },
    }

    if FileSyncManager:hasRootPin() then
        table.insert(sub_items, {
            text = _("Reveal Root PIN"),
            callback = function()
                FileSyncManager:confirmRevealRootPin()
            end,
            keep_menu_open = false,
        })
        table.insert(sub_items, {
            text = _("Remove Root PIN"),
            callback = function()
                FileSyncManager:confirmRemoveRootPin()
            end,
            keep_menu_open = false,
        })
    else
        table.insert(sub_items, {
            text = _("Define Root PIN"),
            callback = function()
                FileSyncManager:promptSetRootPin(false)
            end,
            keep_menu_open = false,
        })
    end

    menu_items.filesync = {
        text = _("FileSync"),
        sorting_hint = "network",
        sub_item_table = sub_items,
    }
end

function FileSync:onSuspend()
    local FileSyncManager = require("filesync/filesyncmanager")
    if FileSyncManager:isRunning() then
        FileSyncManager._was_running_before_suspend = true
        FileSyncManager:stop(true, false, true) -- silent stop, preserve restart intent
    end
end

function FileSync:onResume()
    local FileSyncManager = require("filesync/filesyncmanager")
    if FileSyncManager._was_running_before_suspend then
        FileSyncManager._was_running_before_suspend = false
        FileSyncManager:start(true) -- silent start (no QR code)
    end
end

function FileSync:onEnterStandby()
    self:onSuspend()
end

function FileSync:onLeaveStandby()
    self:onResume()
end

function FileSync:onExit()
    local FileSyncManager = require("filesync/filesyncmanager")
    if FileSyncManager:isRunning() then
        FileSyncManager:stop(true)
    end
end

return FileSync
