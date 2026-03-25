local WidgetContainer = require("ui/widget/container/widgetcontainer")
local ok_i18n, plugin_gettext = pcall(require, "filesync/filesync_i18n")
local _ = ok_i18n and plugin_gettext or require("gettext")

local FileSync = WidgetContainer:extend{
    name = "filesync",
    is_doc_only = false,
}

function FileSync:init()
    self.ui.menu:registerToMainMenu(self)
end

function FileSync:addToMainMenu(menu_items)
    menu_items.filesync = {
        text = _("FileSync"),
        sorting_hint = "network",
        sub_item_table = {
            {
                text_func = function()
                    local FileSyncManager = require("filesync/filesyncmanager")
                    if FileSyncManager:isRunning() then
                        return _("Stop file server")
                    else
                        return _("Start file server")
                    end
                end,
                callback = function()
                    local FileSyncManager = require("filesync/filesyncmanager")
                    if FileSyncManager:isRunning() then
                        FileSyncManager:stop()
                    else
                        FileSyncManager:checkBatteryAndStart()
                    end
                end,
                keep_menu_open = false,
            },
            {
                text = _("Server port"),
                callback = function()
                    local FileSyncManager = require("filesync/filesyncmanager")
                    FileSyncManager:configurePort()
                end,
                keep_menu_open = true,
            },
            {
                text = _("Safe mode"),
                checked_func = function()
                    local FileSyncManager = require("filesync/filesyncmanager")
                    return FileSyncManager:getSafeMode()
                end,
                callback = function()
                    local FileSyncManager = require("filesync/filesyncmanager")
                    FileSyncManager:setSafeMode(not FileSyncManager:getSafeMode())
                end,
                keep_menu_open = true,
            },
            {
                text = _("Show QR code"),
                enabled_func = function()
                    local FileSyncManager = require("filesync/filesyncmanager")
                    return FileSyncManager:isRunning()
                end,
                callback = function()
                    local FileSyncManager = require("filesync/filesyncmanager")
                    FileSyncManager:showQRCode()
                end,
                keep_menu_open = false,
            },
            {
                text = _("Check for updates"),
                callback = function()
                    local Updater = require("filesync/updater")
                    Updater:checkForUpdates(true)
                end,
                keep_menu_open = true,
            },
            {
                text = _("About"),
                callback = function()
                    local UIManager = require("ui/uimanager")
                    local InfoMessage = require("ui/widget/infomessage")
                    local meta = require("filesync/_meta")
                    local T = require("ffi/util").template
                    UIManager:show(InfoMessage:new{
                        text = T(_("FileSync v%1\n\nWireless file manager for KOReader.\n\nStart the server, scan the QR code with your phone, and manage your books from any browser on the same WiFi network.\n\nProject:\ngithub.com/abrahamnm/filesync.koplugin"), meta.version),
                    })
                end,
                keep_menu_open = true,
            },
        },
    }
end

function FileSync:onSuspend()
    local FileSyncManager = require("filesync/filesyncmanager")
    if FileSyncManager:isRunning() then
        FileSyncManager._was_running_before_suspend = true
        FileSyncManager:stop(true) -- silent stop
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
