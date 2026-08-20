--- Simple UI Quick Action integration.
--- Publishes "toggle the file server" as a Quick Action for the Simple UI
--- plugin (https://github.com/doctorhetfield-cmd/simpleui.koplugin) so it can
--- be placed on its bottom bar / homescreen.
---
--- Simple UI exposes an external registration API in
--- features/sui_quickactions.lua (QA.register(descriptor)). The registry lives
--- in memory only, so registration must happen on every KOReader start.
---
--- Plugins are loaded alphabetically, so "filesync" is initialised before
--- "simpleui" and the Quick Actions module usually is not available yet on our
--- first attempt. We therefore retry a few times before giving up. When Simple
--- UI is not installed at all, every attempt is a silent no-op.

local UIManager = require("ui/uimanager")
local Event = require("ui/event")
local logger = require("logger")
local Utils = require("filesync/utils")
local ok_i18n, plugin_gettext = pcall(require, "filesync/filesync_i18n")
local _ = ok_i18n and plugin_gettext or require("gettext")

local QA_MODULE = "features/sui_quickactions"
local CONFIG_MODULE = "infra/sui_config"

local SimpleUI = {
    QA_ID = "filesync_toggle_server",
    RETRY_INTERVAL = 2, -- seconds between attempts while Simple UI loads
    MAX_ATTEMPTS = 5,

    _registered = false,
    _attempts = 0,
    _retry_scheduled = false,
}

--- Resolve Simple UI's Quick Actions module, or nil when unavailable.
--- Prefers the already-loaded module: `require` only resolves once Simple UI
--- itself has been loaded and its plugin directory added to package.path.
local function getQuickActions()
    local QA = package.loaded[QA_MODULE]
    if not QA then
        local ok, mod = pcall(require, QA_MODULE)
        QA = ok and mod or nil
    end
    if type(QA) == "table" and type(QA.register) == "function" then
        return QA
    end
    return nil
end

--- Build the Quick Action descriptor handed to Simple UI.
function SimpleUI:getDescriptor()
    return {
        id = self.QA_ID,
        label = _("File server"),
        icon = Utils.getPluginDir() .. "/filesync/icon.png",
        -- Called on every render: reflect the current server state.
        get_label = function()
            local ok, running = pcall(function()
                return require("filesync/filesyncmanager"):isRunning()
            end)
            if ok and running then
                return _("Stop file server")
            end
            return _("Start file server")
        end,
        -- Runs without leaving the Simple UI screen, and opens widgets
        -- (battery warning, QR code) that outlive the execute() call.
        is_in_place = true,
        is_async_in_place = true,
        execute = function()
            -- Reuse the Dispatcher event so the toggle logic stays in main.lua.
            UIManager:broadcastEvent(Event:new("ToggleFileSyncServer"))
        end,
    }
end

function SimpleUI:_scheduleRetry()
    if self._retry_scheduled or self._attempts >= self.MAX_ATTEMPTS then return end
    self._retry_scheduled = true
    UIManager:scheduleIn(self.RETRY_INTERVAL, function()
        self._retry_scheduled = false
        self:register()
    end)
end

--- Register the Quick Action with Simple UI.
--- Idempotent and safe to call when Simple UI is not installed.
--- @return boolean: true when the action is registered
function SimpleUI:register()
    if self._registered then return true end

    self._attempts = self._attempts + 1
    local QA = getQuickActions()
    if not QA then
        self:_scheduleRetry()
        return false
    end

    local ok, err = pcall(function()
        QA.register(self:getDescriptor())
        -- Simple UI memoizes the validated bottom bar tab list on first use and
        -- drops ids it does not know yet, so invalidate that cache after a late
        -- registration.
        local ok_config, Config = pcall(require, CONFIG_MODULE)
        if ok_config and type(Config) == "table" and Config.invalidateTabsCache then
            Config.invalidateTabsCache()
        end
    end)
    if not ok then
        logger.warn("filesync: Simple UI quick action registration failed: " .. tostring(err))
        return false
    end

    self._registered = true
    logger.dbg("filesync: registered Simple UI quick action")
    return true
end

return SimpleUI
