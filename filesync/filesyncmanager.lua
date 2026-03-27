local Blitbuffer = require("ffi/blitbuffer")
local CenterContainer = require("ui/widget/container/centercontainer")
local ConfirmBox = require("ui/widget/confirmbox")
local Device = require("device")
local FrameContainer = require("ui/widget/container/framecontainer")
local Geom = require("ui/geometry")
local GestureRange = require("ui/gesturerange")
local InfoMessage = require("ui/widget/infomessage")
local InputContainer = require("ui/widget/container/inputcontainer")
local NetworkMgr = require("ui/network/manager")
local OverlapGroup = require("ui/widget/overlapgroup")
local QRWidget = require("ui/widget/qrwidget")
local RightContainer = require("ui/widget/container/rightcontainer")
local Size = require("ui/size")
local TextBoxWidget = require("ui/widget/textboxwidget")
local TextWidget = require("ui/widget/textwidget")
local UIManager = require("ui/uimanager")
local VerticalGroup = require("ui/widget/verticalgroup")
local VerticalSpan = require("ui/widget/verticalspan")
local Font = require("ui/font")
local HorizontalGroup = require("ui/widget/horizontalgroup")
local HorizontalSpan = require("ui/widget/horizontalspan")
local ImageWidget = require("ui/widget/imagewidget")
local logger = require("logger")
local Screen = Device.screen
local ok_i18n, plugin_gettext = pcall(require, "filesync/filesync_i18n")
local _ = ok_i18n and plugin_gettext or require("gettext")
local T = require("ffi/util").template

local FileSyncManager = {
    _running = false,
    _server = nil,
    _port = nil,
    _ip = nil,
    _kindle_firewall_port = nil,
    _kindle_firewall_bin = nil,
    _restart_desired = false,
    _wifi_monitor_active = false,
    _wifi_monitor_generation = 0,
    _wifi_monitor_last_online = nil,
    _wifi_monitor_last_ip = nil,
    _was_running_before_suspend = false,
    _standby_prevented = false,
    _qr_widget = nil,
}

local DEFAULT_PORT = 80
local FALLBACK_PORT = 8080
local KINDLE_IPTABLES_CANDIDATES = {
    "/usr/sbin/iptables",
    "/sbin/iptables",
    "iptables",
}
local WIFI_MONITOR_INTERVAL_SECONDS = 5
local PORT_SETTING_KEY = "filesync_port"
local PORT_USER_DEFINED_SETTING_KEY = "filesync_port_user_defined"
-- NOTE: Port 80 is used by default for convenience (no :port in the URL).
-- On Kindle, KOReader runs as root, so binding to port 80 works.
-- On other devices this may fail due to OS permission restrictions;
-- the start() function handles this case with a clear error message.
-- The Root PIN is stored in plain plugin settings because it must be
-- revealable locally on the device. This is convenient, not strong security.
local ROOT_PIN_SETTING_KEY = "filesync_root_pin"
-- Cleanup compatibility for local hash-only builds created during PR-02 work.
local ROOT_PIN_HASH_SETTING_KEY = "filesync_root_pin_hash"
local ROOT_PIN_SALT_SETTING_KEY = "filesync_root_pin_salt"
local ROOT_PIN_LENGTH_SETTING_KEY = "filesync_root_pin_length"

function FileSyncManager:getPort()
    if self._port then return self._port end
    local saved_port = self:_normalizePort(G_reader_settings:readSetting(PORT_SETTING_KEY))
    self._port = saved_port or DEFAULT_PORT
    return self._port
end

function FileSyncManager:_normalizePort(port)
    port = tonumber(port)
    if not port then
        return nil
    end

    port = math.floor(port)
    if port < 1 or port > 65535 then
        return nil
    end

    return port
end

function FileSyncManager:hasUserConfiguredPort()
    local user_defined = G_reader_settings:readSetting(PORT_USER_DEFINED_SETTING_KEY)
    if user_defined ~= nil then
        return user_defined == true
    end

    -- Older installs stored only the port value, so preserve that behavior
    -- and avoid surprising users by auto-switching a previously saved port.
    return self:_normalizePort(G_reader_settings:readSetting(PORT_SETTING_KEY)) ~= nil
end

function FileSyncManager:_persistPort(port, user_defined)
    local normalized_port = self:_normalizePort(port)
    if not normalized_port then
        return false
    end

    self._port = normalized_port
    G_reader_settings:saveSetting(PORT_SETTING_KEY, normalized_port)
    G_reader_settings:saveSetting(PORT_USER_DEFINED_SETTING_KEY, user_defined == true)
    G_reader_settings:flush()
    return true
end

function FileSyncManager:setPort(port)
    return self:_persistPort(port, true)
end

function FileSyncManager:_setAutomaticPort(port)
    return self:_persistPort(port, false)
end

function FileSyncManager:getSafeMode()
    return G_reader_settings:readSetting("filesync_safe_mode", true)
end

function FileSyncManager:setSafeMode(enabled)
    G_reader_settings:saveSetting("filesync_safe_mode", enabled)
    G_reader_settings:flush()
    if enabled then
        self:_resetRootUnlock()
    end
end

function FileSyncManager:_normalizeRootPin(pin)
    if pin == nil then
        return ""
    end
    return tostring(pin):gsub("^%s+", ""):gsub("%s+$", "")
end

function FileSyncManager:_validateRootPin(pin)
    pin = self:_normalizeRootPin(pin)
    if pin == "" then
        return nil, _("PIN cannot be empty.")
    end
    if not pin:match("^%d+$") then
        return nil, _("PIN must contain digits only.")
    end
    if #pin < 4 or #pin > 8 then
        return nil, _("PIN must be between 4 and 8 digits.")
    end
    return pin
end

function FileSyncManager:_deleteSetting(key)
    if G_reader_settings.delSetting then
        G_reader_settings:delSetting(key)
    else
        G_reader_settings:saveSetting(key, nil)
    end
end

function FileSyncManager:_clearHashedRootPinCompatState()
    self:_deleteSetting(ROOT_PIN_HASH_SETTING_KEY)
    self:_deleteSetting(ROOT_PIN_SALT_SETTING_KEY)
    self:_deleteSetting(ROOT_PIN_LENGTH_SETTING_KEY)
end

function FileSyncManager:getRootPin()
    local pin = G_reader_settings:readSetting(ROOT_PIN_SETTING_KEY)
    pin = self:_normalizeRootPin(pin)
    if pin == "" then
        return nil
    end
    return pin
end

function FileSyncManager:hasRootPin()
    return self:getRootPin() ~= nil
end

function FileSyncManager:getRootPinLength()
    local pin = self:getRootPin()
    if not pin then
        return nil
    end
    return #pin
end

function FileSyncManager:_resetRootUnlock()
    if self._server and self._server.invalidateAllRootSessions then
        self._server:invalidateAllRootSessions()
    end
end

function FileSyncManager:setRootPin(pin)
    local normalized_pin, err = self:_validateRootPin(pin)
    if not normalized_pin then
        return false, err
    end

    G_reader_settings:saveSetting(ROOT_PIN_SETTING_KEY, normalized_pin)
    self:_clearHashedRootPinCompatState()
    G_reader_settings:flush()
    self:_resetRootUnlock()
    return true
end

function FileSyncManager:removeRootPin()
    self:_deleteSetting(ROOT_PIN_SETTING_KEY)
    self:_clearHashedRootPinCompatState()
    G_reader_settings:flush()
    self:_resetRootUnlock()
    return true
end

function FileSyncManager:verifyRootPin(pin)
    local saved_pin = self:getRootPin()
    if not saved_pin then
        return false
    end
    return self:_normalizeRootPin(pin) == saved_pin
end

function FileSyncManager:promptSetRootPin(is_change, options)
    options = options or {}
    local InputDialog = require("ui/widget/inputdialog")
    local pin_dialog
    local title
    if is_change then
        title = _("Change Root PIN")
    elseif options.required_for_server then
        title = _("Define Root PIN to Start")
    else
        title = _("Define Root PIN")
    end

    local success_message
    if is_change then
        success_message = _("Root PIN updated.")
    elseif options.start_server_after_save then
        success_message = _("Root PIN saved. Starting server.")
    else
        success_message = _("Root PIN saved.")
    end

    pin_dialog = InputDialog:new{
        title = title,
        input = "",
        input_type = "number",
        input_hint = "1234",
        buttons = {
            {
                {
                    text = _("Cancel"),
                    id = "close",
                    callback = function()
                        UIManager:close(pin_dialog)
                        if options.on_cancel then
                            options.on_cancel()
                        end
                    end,
                },
                {
                    text = _("Save"),
                    is_enter_default = true,
                    callback = function()
                        local ok, err = self:setRootPin(pin_dialog:getInputText())
                        if not ok then
                            UIManager:show(InfoMessage:new{
                                text = err,
                                timeout = 3,
                            })
                            return
                        end

                        UIManager:close(pin_dialog)
                        UIManager:show(InfoMessage:new{
                            text = success_message,
                            timeout = 3,
                        })

                        if options.on_success then
                            options.on_success()
                        end
                    end,
                },
            },
        },
    }
    UIManager:show(pin_dialog)
    pin_dialog:onShowKeyboard()
end

function FileSyncManager:confirmRevealRootPin()
    local pin = self:getRootPin()
    if not pin then
        UIManager:show(InfoMessage:new{
            text = _("Root PIN is not set."),
            timeout = 3,
        })
        return
    end

    UIManager:show(ConfirmBox:new{
        title = _("Reveal Root PIN"),
        text = _("The Root PIN will appear on the Kindle screen. Continue?"),
        ok_text = _("Reveal"),
        cancel_text = _("Cancel"),
        ok_callback = function()
            UIManager:show(InfoMessage:new{
                text = T(_("Root PIN: %1"), pin),
                timeout = 8,
            })
        end,
    })
end

function FileSyncManager:confirmRemoveRootPin()
    if not self:hasRootPin() then
        UIManager:show(InfoMessage:new{
            text = _("Root PIN is not set."),
            timeout = 3,
        })
        return
    end

    UIManager:show(ConfirmBox:new{
        title = _("Remove Root PIN"),
        text = _("Remove the saved Root PIN from this device?"),
        ok_text = _("Remove"),
        cancel_text = _("Cancel"),
        ok_callback = function()
            self:removeRootPin()
            UIManager:show(InfoMessage:new{
                text = _("Root PIN removed."),
                timeout = 3,
            })
        end,
    })
end

function FileSyncManager:configurePort()
    local InputDialog = require("ui/widget/inputdialog")
    local port_dialog
    port_dialog = InputDialog:new{
        title = _("Server port"),
        input = tostring(self:getPort()),
        input_type = "number",
        input_hint = tostring(DEFAULT_PORT),
        buttons = {
            {
                {
                    text = _("Cancel"),
                    id = "close",
                    callback = function()
                        UIManager:close(port_dialog)
                    end,
                },
                {
                    text = _("Save"),
                    is_enter_default = true,
                    callback = function()
                        local new_port = tonumber(port_dialog:getInputText())
                        if new_port and new_port >= 1 and new_port <= 65535 then
                            self:setPort(new_port)
                            UIManager:close(port_dialog)
                            UIManager:show(InfoMessage:new{
                                text = T(_("Port set to %1. Restart the server for changes to take effect."), new_port),
                                timeout = 3,
                            })
                        else
                            UIManager:show(InfoMessage:new{
                                text = _("Invalid port. Please enter a number between 1 and 65535."),
                                timeout = 3,
                            })
                        end
                    end,
                },
            },
        },
    }
    UIManager:show(port_dialog)
    port_dialog:onShowKeyboard()
end

function FileSyncManager:getLocalIP()
    -- Try multiple methods to get the local IP address
    -- Method 1: Use KOReader's NetworkMgr if available
    if NetworkMgr and NetworkMgr.getLocalIpAddress then
        local ip = NetworkMgr:getLocalIpAddress()
        if ip and ip ~= "0.0.0.0" and ip ~= "127.0.0.1" then
            return ip
        end
    end

    -- Method 2: Parse ifconfig output
    local fd = io.popen("ifconfig 2>/dev/null || ip addr show 2>/dev/null")
    if fd then
        local output = fd:read("*all")
        fd:close()
        if output then
            -- Match inet addresses, skip loopback
            for ip in output:gmatch("inet%s+(%d+%.%d+%.%d+%.%d+)") do
                if ip ~= "127.0.0.1" then
                    return ip
                end
            end
        end
    end

    -- Method 3: UDP socket trick (doesn't actually send data)
    local socket = require("socket")
    local s = socket.udp()
    if s then
        s:setpeername("8.8.8.8", 80)
        local ip = s:getsockname()
        s:close()
        if ip and ip ~= "0.0.0.0" then
            return ip
        end
    end

    return nil
end

function FileSyncManager:_shouldOmitPortInURL(port)
    return tonumber(port) == DEFAULT_PORT
end

--- Build the full URL for the server.
--- Only omit the explicit port for the default HTTP port 80. Other ports,
--- even if they are below 1024, still require :port in the browser URL.
--- This single function is the source of truth for the URL shown on
--- the QR screen, encoded in the QR code, and printed in the log.
function FileSyncManager:buildURL(ip, port)
    if self:_shouldOmitPortInURL(port) then
        return "http://" .. ip
    end
    return "http://" .. ip .. ":" .. port
end

function FileSyncManager:getRootDir()
    -- Determine the books/library directory based on device
    if Device:isKindle() then
        return "/mnt/us"
    elseif Device:isKobo() then
        return "/mnt/onboard"
    elseif Device:isPocketBook() then
        return "/mnt/ext1"
    elseif Device:isAndroid() then
        return require("android").getExternalStoragePath()
    else
        -- Fallback: use KOReader's home directory
        local DataStorage = require("datastorage")
        return DataStorage:getDataDir()
    end
end

function FileSyncManager:isRunning()
    return self._running
end

function FileSyncManager:_pathExists(path)
    if not path or path == "" then
        return false
    end

    local fh = io.open(path, "rb")
    if fh then
        fh:close()
        return true
    end

    return false
end

function FileSyncManager:_runShellCommand(command)
    local ok, result1, result2, result3 = pcall(os.execute, command)
    if not ok then
        return false, tostring(result1)
    end

    if type(result1) == "number" then
        return result1 == 0, tostring(result1)
    end

    if result1 == true or result1 == 0 then
        return true, tostring(result3 or result2 or result1)
    end

    return false, tostring(result3 or result2 or result1)
end

function FileSyncManager:_getKindleIptablesCandidates()
    local candidates = {}
    local seen = {}

    local function addCandidate(candidate)
        if not candidate or candidate == "" or seen[candidate] then
            return
        end
        if candidate:sub(1, 1) == "/" and not self:_pathExists(candidate) then
            return
        end
        seen[candidate] = true
        candidates[#candidates + 1] = candidate
    end

    addCandidate(self._kindle_firewall_bin)
    for _, candidate in ipairs(KINDLE_IPTABLES_CANDIDATES) do
        addCandidate(candidate)
    end

    return candidates
end

function FileSyncManager:_runKindleIptablesRule(action, port)
    port = tonumber(port)
    if not port then
        return false, "invalid port"
    end

    local candidates = self:_getKindleIptablesCandidates()
    if #candidates == 0 then
        return false, "iptables binary not found"
    end

    local last_error = "iptables command failed"
    for _, binary in ipairs(candidates) do
        local command = string.format(
            "%q %s INPUT -p tcp --dport %d -j ACCEPT >/dev/null 2>&1",
            binary,
            action,
            math.floor(port)
        )
        local ok, status = self:_runShellCommand(command)
        if ok then
            self._kindle_firewall_bin = binary
            return true
        end

        last_error = string.format("%s exited with status %s", binary, tostring(status))
        logger.warn("FileSync: Kindle firewall command failed:", action, binary, "port", port, "status", status)
    end

    return false, last_error
end

function FileSyncManager:_cleanupFailedStart()
    if self._server then
        local ok, err = pcall(function()
            self._server:stop()
        end)
        if not ok then
            logger.warn("FileSync: Failed to stop partially started server:", err)
        end
        self._server = nil
    end

    if Device:isKindle() and self._kindle_firewall_port then
        local ok, err = self:closeKindleFirewall(self._kindle_firewall_port)
        if not ok then
            logger.warn("FileSync: Failed to clean up Kindle firewall after startup error:", err)
        end
    end

    local standby_ok, standby_err = self:allowStandby()
    if not standby_ok then
        logger.warn("FileSync: Failed to restore standby state after startup error:", standby_err)
    end

    self._running = false
    self._ip = nil
end

function FileSyncManager:_stopWifiMonitor()
    self._wifi_monitor_active = false
    self._wifi_monitor_generation = (self._wifi_monitor_generation or 0) + 1
    self._wifi_monitor_last_online = nil
    self._wifi_monitor_last_ip = nil
end

function FileSyncManager:_pollWifiMonitor()
    if not self._restart_desired and not self._running then
        self:_stopWifiMonitor()
        return
    end

    local wifi_on = NetworkMgr and NetworkMgr.isWifiOn and NetworkMgr:isWifiOn() or false
    local current_ip = wifi_on and self:getLocalIP() or nil
    local is_online = wifi_on and current_ip ~= nil
    local was_online = self._wifi_monitor_last_online
    local previous_ip = self._wifi_monitor_last_ip

    self._wifi_monitor_last_online = is_online
    self._wifi_monitor_last_ip = current_ip

    if self._running then
        if not is_online then
            logger.info("FileSync: WiFi lost while server was running; stopping and waiting for reconnect")
            self:stop(true, false, true)
            return
        end

        if previous_ip and current_ip and previous_ip ~= current_ip then
            logger.info("FileSync: WiFi IP changed from", previous_ip, "to", current_ip, "- restarting server")
            self:stop(true, false, true)
            self:start(true)
            return
        end

        return
    end

    if self._restart_desired and was_online == false and is_online then
        logger.info("FileSync: WiFi reconnected; restarting server")
        self:start(true)
    end
end

function FileSyncManager:_ensureWifiMonitor()
    if self._wifi_monitor_active then
        return
    end

    self._wifi_monitor_active = true
    self._wifi_monitor_generation = (self._wifi_monitor_generation or 0) + 1
    local generation = self._wifi_monitor_generation

    local function tick()
        if not self._wifi_monitor_active or self._wifi_monitor_generation ~= generation then
            return
        end

        self:_pollWifiMonitor()

        if self._wifi_monitor_active and self._wifi_monitor_generation == generation then
            UIManager:scheduleIn(WIFI_MONITOR_INTERVAL_SECONDS, tick)
        end
    end

    UIManager:scheduleIn(WIFI_MONITOR_INTERVAL_SECONDS, tick)
end

function FileSyncManager:_refreshWifiMonitor()
    if self._restart_desired or self._running then
        self:_ensureWifiMonitor()
    else
        self:_stopWifiMonitor()
    end
end

function FileSyncManager:_tryStartHttpServer(HttpServer, port, root_dir)
    local ok, err = pcall(function()
        self._server = HttpServer:new{
            port = port,
            root_dir = root_dir,
        }
        self._server:start()
    end)

    if ok then
        return true
    end

    self._server = nil
    return false, err
end

function FileSyncManager:_isPortInUseError(err)
    local message = tostring(err or ""):lower()
    return message:find("address already in use", 1, true)
        or message:find("already in use", 1, true)
        or message:find("eaddrinuse", 1, true)
end

function FileSyncManager:_buildStartServerErrorMessage(port, err, options)
    options = options or {}
    local fallback_port = options.fallback_port
    local fallback_err = options.fallback_err
    local default_url = options.default_url
    local fallback_url = options.fallback_url

    if self:_isPortInUseError(err) then
        if port == DEFAULT_PORT then
            if fallback_port and fallback_err then
                if self:_isPortInUseError(fallback_err) then
                    if default_url and fallback_url then
                        return T(_("FileSync could not use the default address %1 because another service is already using port %2.\n\nFileSync then tried %3 automatically, but that address is already in use too.\n\nStop the other service, or change the Server Port setting to another free port such as 8081."), default_url, port, fallback_url)
                    end
                    return T(_("FileSync tried to start on port %1, but another service is already using it.\n\nFileSync then tried port %2 automatically, but that port is already in use too.\n\nStop the other service, or change the Server Port setting to another free port such as 8081."), port, fallback_port)
                end

                if default_url then
                    return T(_("FileSync could not use the default address %1 because another service is already using port %2.\n\nFileSync then tried port %3 automatically, but it also failed.\n\nSecond error: %4"), default_url, port, fallback_port, tostring(fallback_err))
                end
                return T(_("FileSync tried to start on port %1, but another service is already using it.\n\nFileSync then tried port %2 automatically, but it also failed.\n\nSecond error: %3"), port, fallback_port, tostring(fallback_err))
            end

            if default_url then
                return T(_("FileSync could not use the default address %1 because another service is already using port %2.\n\nStop the service using port %2, or change the Server Port setting to 8080 or higher."), default_url, port)
            end
            return T(_("FileSync could not start because another service is already using port %1.\n\nStop the service using port %1, or change the Server Port setting to 8080 or higher."), port)
        end

        return T(_("Failed to start server on port %1.\n\nAnother service is already using this port.\n\nStop the service using port %1, or change the Server Port setting to 8080 or higher."), port)
    end

    if port < 1024 then
        return T(_("Failed to start server on port %1.\n\nPorts below 1024 require root/admin privileges. The system may not allow binding to this port.\n\nTry changing the port to 8080 or higher in the Server Port setting."), port)
    end

    return T(_("Failed to start server: %1"), tostring(err))
end

function FileSyncManager:start(silent)
    if self._running then
        if not silent then
            UIManager:show(InfoMessage:new{
                text = _("FileSync server is already running."),
                timeout = 2,
            })
        end
        return
    end

    if not self:hasRootPin() then
        if silent then
            logger.warn("FileSync: Refusing to start server without a Root PIN")
            self._restart_desired = false
            self:_refreshWifiMonitor()
            return
        end

        self:promptSetRootPin(false, {
            required_for_server = true,
            start_server_after_save = true,
            on_success = function()
                self:checkBatteryAndStart()
            end,
        })
        return
    end

    -- Check WiFi
    if not NetworkMgr:isWifiOn() then
        if not silent then
            UIManager:show(InfoMessage:new{
                text = _("WiFi is not enabled. Please turn on WiFi first."),
                timeout = 3,
            })
        end
        return
    end

    -- Get the local IP
    local ip = self:getLocalIP()
    if not ip then
        if not silent then
            UIManager:show(InfoMessage:new{
                text = _("Could not determine device IP address. Make sure WiFi is connected."),
                timeout = 3,
            })
        end
        return
    end

    local port = self:getPort()
    local root_dir = self:getRootDir()
    local port_was_user_defined = self:hasUserConfiguredPort()

    -- Start the HTTP server
    local HttpServer = require("filesync/httpserver")
    local ok, err = self:_tryStartHttpServer(HttpServer, port, root_dir)
    local original_start_err = err
    local used_fallback_port = false
    local original_port = port
    local fallback_start_err = nil

    if not ok and not port_was_user_defined and port == DEFAULT_PORT then
        local fallback_ok, fallback_err = self:_tryStartHttpServer(HttpServer, FALLBACK_PORT, root_dir)
        if fallback_ok then
            port = FALLBACK_PORT
            used_fallback_port = true
            self:_setAutomaticPort(port)
            ok = true
            err = nil
            logger.warn("FileSync: Port", original_port, "unavailable; switched automatically to", port)
        else
            fallback_start_err = fallback_err
            err = fallback_err
        end
    end

    if not ok then
        logger.err("FileSync: Failed to start server:", err)
        if not silent then
            UIManager:show(InfoMessage:new{
                text = self:_buildStartServerErrorMessage(original_port, original_start_err or err, {
                    fallback_port = fallback_start_err and FALLBACK_PORT or nil,
                    fallback_err = fallback_start_err,
                    default_url = self:buildURL(ip, original_port),
                    fallback_url = fallback_start_err and self:buildURL(ip, FALLBACK_PORT) or nil,
                }),
                timeout = 8,
            })
        end
        return
    end

    -- Add Kindle firewall rules
    if Device:isKindle() then
        local firewall_ok, firewall_err = self:openKindleFirewall(port)
        if not firewall_ok then
            local err_msg = "Could not configure Kindle firewall: " .. tostring(firewall_err)
            logger.err("FileSync:", err_msg)
            self:_cleanupFailedStart()
            if not silent then
                UIManager:show(InfoMessage:new{
                    text = T(_("Failed to start server: %1"), err_msg),
                    timeout = 8,
                })
            end
            return
        end
    end

    local standby_ok, standby_err = self:preventStandby()
    if not standby_ok then
        local err_msg = "Could not prevent standby: " .. tostring(standby_err)
        logger.err("FileSync:", err_msg)
        self:_cleanupFailedStart()
        if not silent then
            UIManager:show(InfoMessage:new{
                text = T(_("Failed to start server: %1"), err_msg),
                timeout = 8,
            })
        end
        return
    end

    self._running = true
    self._ip = ip
    self._port = port
    self._restart_desired = true
    self:_refreshWifiMonitor()
    logger.info("FileSync: Server started on", self:buildURL(ip, port))

    if not silent then
        self:showQRCode()
        if used_fallback_port then
            local fallback_message
            if self:_isPortInUseError(original_start_err) and original_port == DEFAULT_PORT then
                fallback_message = T(_("Port %1 was already in use, so FileSync could not use the default address %2.\n\nFileSync switched automatically to port %3.\n\nUse this address instead: %4"), original_port, self:buildURL(ip, original_port), port, self:buildURL(ip, port))
            elseif self:_isPortInUseError(original_start_err) then
                fallback_message = T(_("FileSync tried to start on port %1, but another service was already using it.\n\nTo avoid the conflict, FileSync switched automatically to port %2.\n\nUse this address: %3"), original_port, port, self:buildURL(ip, port))
            else
                fallback_message = T(_("Port %1 was unavailable, so FileSync switched automatically to port %2.\n\nUse this address: %3"), original_port, port, self:buildURL(ip, port))
            end
            UIManager:show(InfoMessage:new{
                text = fallback_message,
                timeout = 6,
            })
        end
    end
end

function FileSyncManager:stop(silent, keep_qr_screen, preserve_restart_intent)
    if not self._running and not self._server and not self._standby_prevented and not self._kindle_firewall_port then
        return
    end

    -- Close QR screen if open
    if not keep_qr_screen then
        self:closeQRScreen()
    end

    if self._server then
        local ok, err = pcall(function()
            self._server:stop()
        end)
        if not ok then
            logger.warn("FileSync: Failed to stop HTTP server cleanly:", err)
        end
        self._server = nil
    end

    -- Remove Kindle firewall rules
    if Device:isKindle() then
        local firewall_ok, firewall_err = self:closeKindleFirewall()
        if not firewall_ok then
            logger.warn("FileSync: Failed to remove Kindle firewall rule:", firewall_err)
        end
    end

    self._running = false
    if not preserve_restart_intent then
        self._restart_desired = false
    end
    local standby_ok, standby_err = self:allowStandby()
    if not standby_ok then
        logger.warn("FileSync: Failed to restore standby after stop:", standby_err)
    end
    self._ip = nil
    self:_refreshWifiMonitor()
    logger.info("FileSync: Server stopped")

    if not silent then
        UIManager:show(InfoMessage:new{
            text = _("FileSync server stopped."),
            timeout = 2,
        })
    end
end

function FileSyncManager:preventStandby()
    if self._standby_prevented then
        return true
    end

    local ok, err = pcall(function()
        UIManager:preventStandby()
    end)
    if not ok then
        return false, err
    end

    local ok_share, PluginShare = pcall(require, "pluginshare")
    if ok_share and type(PluginShare) == "table" then
        PluginShare.pause_auto_suspend = true
        logger.info("FileSync: Auto-suspend paused via PluginShare")
    else
        logger.warn("FileSync: PluginShare unavailable while preventing standby")
    end

    self._standby_prevented = true
    logger.info("FileSync: Standby prevented")
    return true
end

function FileSyncManager:allowStandby()
    if not self._standby_prevented then
        return true
    end

    local ok_share, PluginShare = pcall(require, "pluginshare")
    if ok_share and type(PluginShare) == "table" then
        PluginShare.pause_auto_suspend = nil
        logger.info("FileSync: Auto-suspend resumed via PluginShare")
    else
        logger.warn("FileSync: PluginShare unavailable while restoring standby")
    end

    local ok, err = pcall(function()
        UIManager:allowStandby()
    end)
    if not ok then
        return false, err
    end

    logger.info("FileSync: Standby allowed")

    self._standby_prevented = false
    return true
end

function FileSyncManager:checkBatteryAndStart()
    if not self:hasRootPin() then
        self:promptSetRootPin(false, {
            required_for_server = true,
            start_server_after_save = true,
            on_success = function()
                self:checkBatteryAndStart()
            end,
        })
        return
    end

    local ok_power, power_device = pcall(function() return Device:getPowerDevice() end)
    local capacity = 100
    local is_charging = false
    if ok_power and power_device then
        local ok_cap, cap = pcall(function() return power_device:getCapacity() end)
        if ok_cap and cap then capacity = cap end
        local ok_chg, chg = pcall(function() return power_device:isCharging() end)
        if ok_chg then is_charging = chg end
    end

    if capacity < 15 and not is_charging then
        UIManager:show(ConfirmBox:new{
            title = _("Low Battery"),
            text = T(_("Battery level is at %1%. Running the server may drain the battery quickly."), capacity),
            ok_text = _("Start Anyway"),
            cancel_text = _("Cancel"),
            ok_callback = function()
                self:start()
            end,
        })
    else
        self:start()
    end
end

function FileSyncManager:closeQRScreen()
    if self._qr_widget then
        UIManager:close(self._qr_widget, "full")
        self._qr_widget = nil
    end
end

function FileSyncManager:showQRCode()
    if not self._running or not self._ip then
        UIManager:show(InfoMessage:new{
            text = _("Server is not running."),
            timeout = 2,
        })
        return
    end

    -- Close any existing QR screen first
    self:closeQRScreen()

    local url = self:buildURL(self._ip, self._port)
    local screen_width = Screen:getWidth()
    local screen_height = Screen:getHeight()

    -- Build the QR code widget
    local qr_size = Screen:scaleBySize(260)
    local qr_widget = QRWidget:new{
        text = url,
        width = qr_size,
        height = qr_size,
    }

    -- Icon + Title row
    local icon_dir = debug.getinfo(1, "S").source:match("@(.+)"):match("(.*/)")
    local icon_size = Screen:scaleBySize(46)
    local icon_file = icon_dir .. "icon.png"
    if Screen.night_mode then
        local dark_icon_file = icon_dir .. "icon_dark.png"
        local dark_icon_handle = io.open(dark_icon_file, "rb")
        if dark_icon_handle then
            dark_icon_handle:close()
            icon_file = dark_icon_file
        end
    end
    local icon_widget = ImageWidget:new{
        file = icon_file,
        width = icon_size,
        height = icon_size,
        alpha = true,
    }
    local title_text = TextWidget:new{
        text = _("FileSync"),
        face = Font:getFace("infofont", 34),
        bold = true,
        fgcolor = Blitbuffer.COLOR_BLACK,
    }
    local title_widget = HorizontalGroup:new{
        align = "center",
        icon_widget,
        HorizontalSpan:new{ width = Screen:scaleBySize(8) },
        title_text,
    }

    -- URL text
    local url_widget = TextWidget:new{
        text = url,
        face = Font:getFace("infofont", 22),
        fgcolor = Blitbuffer.COLOR_BLACK,
        max_width = screen_width - Screen:scaleBySize(40),
    }

    -- Instructions text
    local instructions_widget = TextBoxWidget:new{
        text = _("Scan the QR code or enter the URL\nin your browser.\n\nBoth devices must be on the same WiFi network."),
        face = Font:getFace("smallinfofont", 20),
        width = screen_width * 0.65,
        alignment = "center",
        fgcolor = Blitbuffer.COLOR_BLACK,
    }

    -- Stop Server button
    local button_text = TextWidget:new{
        text = _("Stop Server"),
        face = Font:getFace("infofont", 20),
        fgcolor = Blitbuffer.COLOR_BLACK,
    }
    local stop_button = FrameContainer:new{
        bordersize = Size.border.button,
        radius = Size.radius.button,
        padding = Screen:scaleBySize(10),
        padding_left = Screen:scaleBySize(30),
        padding_right = Screen:scaleBySize(30),
        background = Blitbuffer.COLOR_WHITE,
        button_text,
    }

    -- Vertical layout
    local vertical_content = VerticalGroup:new{
        align = "center",
        VerticalSpan:new{ width = Screen:scaleBySize(40) },
        title_widget,
        VerticalSpan:new{ width = Screen:scaleBySize(30) },
        qr_widget,
        VerticalSpan:new{ width = Screen:scaleBySize(20) },
        url_widget,
        VerticalSpan:new{ width = Screen:scaleBySize(15) },
        instructions_widget,
        VerticalSpan:new{ width = Screen:scaleBySize(30) },
        stop_button,
    }

    -- X (close) button in the top-right corner
    local close_button_box_size = Screen:scaleBySize(40)
    local close_button_text = TextWidget:new{
        text = "\u{00D7}", -- multiplication sign as X
        face = Font:getFace("infofont", 30),
        fgcolor = Blitbuffer.COLOR_BLACK,
    }
    local close_button = FrameContainer:new{
        bordersize = Size.border.button,
        radius = Screen:scaleBySize(8),
        padding = 0,
        background = Blitbuffer.COLOR_WHITE,
        CenterContainer:new{
            dimen = Geom:new{
                w = close_button_box_size,
                h = close_button_box_size,
            },
            close_button_text,
        },
    }
    local close_button_row = RightContainer:new{
        dimen = { w = screen_width - Screen:scaleBySize(10), h = close_button:getSize().h + Screen:scaleBySize(10) },
        FrameContainer:new{
            bordersize = 0,
            padding = 0,
            padding_top = Screen:scaleBySize(10),
            padding_right = Screen:scaleBySize(10),
            background = Blitbuffer.COLOR_WHITE,
            close_button,
        },
    }

    -- Center everything on screen
    local centered_content = CenterContainer:new{
        dimen = { w = screen_width, h = screen_height },
        vertical_content,
    }

    -- Layer the close button on top of centered content using OverlapGroup
    local overlap = OverlapGroup:new{
        dimen = { w = screen_width, h = screen_height },
        centered_content,
        close_button_row,
    }

    -- Full-screen white background container
    local frame = FrameContainer:new{
        width = screen_width,
        height = screen_height,
        bordersize = 0,
        padding = 0,
        margin = 0,
        background = Blitbuffer.COLOR_WHITE,
        overlap,
    }

    -- Build the InputContainer for handling taps
    local widget = InputContainer:new{
        width = screen_width,
        height = screen_height,
    }
    widget[1] = frame

    -- Store button references for hit testing
    widget._stop_button = stop_button
    widget._close_button = close_button
    widget._manager = self

    widget.ges_events = {
        Tap = {
            GestureRange:new{
                ges = "tap",
                range = Geom:new{ x = 0, y = 0, w = screen_width, h = screen_height },
            },
        },
    }

    function widget:onTap(_event, ges)
        if not ges then return true end
        local x, y = ges.pos.x, ges.pos.y

        -- Check if the tap is on the Stop Server button
        local btn = self._stop_button
        if btn.dimen then
            if x >= btn.dimen.x and x <= btn.dimen.x + btn.dimen.w
               and y >= btn.dimen.y and y <= btn.dimen.y + btn.dimen.h then
                -- Stop button tapped: reuse the standard stop flow so the
                -- "server stopped" confirmation remains visible on screen.
                self._manager:stop(false, true)
                return true
            end
        end

        -- Check if the tap is on the X close button
        local close_btn = self._close_button
        if close_btn.dimen then
            if x >= close_btn.dimen.x and x <= close_btn.dimen.x + close_btn.dimen.w
               and y >= close_btn.dimen.y and y <= close_btn.dimen.y + close_btn.dimen.h then
                -- X button tapped: ask user what to do
                local manager = self._manager
                UIManager:show(ConfirmBox:new{
                    title = _("File server is running"),
                    text = _("The server will keep running in the background and prevent the device from sleeping. What would you like to do?"),
                    ok_text = _("Stop server"),
                    cancel_text = _("Keep running"),
                    ok_callback = function()
                        manager:closeQRScreen()
                        UIManager:show(InfoMessage:new{
                            text = _("Stopping server..."),
                            timeout = 2,
                        })
                        UIManager:scheduleIn(0.5, function()
                            manager:stop(true)
                            UIManager:restartKOReader()
                        end)
                    end,
                    cancel_callback = function()
                        manager:closeQRScreen()
                    end,
                })
                return true
            end
        end

        -- Tap anywhere else: do nothing (no dismiss)
        return true
    end

    function widget:onClose()
        -- Only dismiss via X button, not via generic close/back key
        return true
    end

    self._qr_widget = widget
    UIManager:show(widget, "full")
end

function FileSyncManager:openKindleFirewall(port)
    port = tonumber(port)
    if not port then
        return false, "invalid port"
    end

    if self._kindle_firewall_port and self._kindle_firewall_port ~= port then
        local close_ok, close_err = self:closeKindleFirewall(self._kindle_firewall_port)
        if not close_ok then
            logger.warn("FileSync: Failed to close stale Kindle firewall rule:", close_err)
        end
    end

    local ok, err = self:_runKindleIptablesRule("-A", port)
    if not ok then
        return false, err
    end

    self._kindle_firewall_port = port
    logger.info("FileSync: Kindle firewall rule added for port", port)
    return true
end

function FileSyncManager:closeKindleFirewall(port)
    local target_port = tonumber(port or self._kindle_firewall_port)
    if not target_port then
        return true
    end

    local ok, err = self:_runKindleIptablesRule("-D", target_port)
    if not ok then
        return false, err
    end

    if self._kindle_firewall_port == target_port then
        self._kindle_firewall_port = nil
    end
    logger.info("FileSync: Kindle firewall rule removed for port", target_port)
    return true
end

return FileSyncManager
