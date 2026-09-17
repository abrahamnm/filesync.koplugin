--- Server lifecycle management for the FileSync plugin.
--- Handles starting/stopping the HTTP server, WiFi/IP detection, battery checks,
--- QR code display, standby prevention, and Kindle firewall rules.
---
--- Key dependencies: device (KOReader), UIManager (KOReader), filesync/httpserver,
--- filesync/mdns

local BD = require("ui/bidi")
local Blitbuffer = require("ffi/blitbuffer")
local ButtonTable = require("ui/widget/buttontable")
local CenterContainer = require("ui/widget/container/centercontainer")
local ConfirmBox = require("ui/widget/confirmbox")
local Device = require("device")
local FocusManager = require("ui/widget/focusmanager")
local FrameContainer = require("ui/widget/container/framecontainer")
local Geom = require("ui/geometry")
local GestureRange = require("ui/gesturerange")
local InfoMessage = require("ui/widget/infomessage")
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
local Utils = require("filesync/utils")
local logger = require("logger")
local Screen = Device.screen
local ok_i18n, plugin_gettext = pcall(require, "filesync/filesync_i18n")
local _ = ok_i18n and plugin_gettext or require("gettext")
local T = require("ffi/util").template

local FileSyncManager = {
    _running = false,
    _server = nil,
    _mdns = nil,
    _port = nil,
    _hostname = nil,
    _ip = nil,
    _was_running_before_suspend = false,
    _standby_prevented = false,
    _qr_widget = nil,
}

function FileSyncManager:new(o)
    o = o or {}
    setmetatable(o, self)
    self.__index = self
    return o
end

-- Port used by a fresh install. Port 80 lets users reach the server by typing
-- just the device IP (no ":port" suffix), which matters on e-ink keyboards.
-- It only binds when KOReader runs as root (Kobo/Kindle); elsewhere the server
-- start path falls back to FALLBACK_PORT.
local DEFAULT_PORT = 80
-- Port used when binding a privileged port (<1024) fails.
local FALLBACK_PORT = 8080
-- mDNS hostname label used by a fresh install: the server answers at
-- http://filesync.local. The ".local" suffix is always appended by the plugin.
local DEFAULT_HOSTNAME = "filesync"

function FileSyncManager:getPort()
    if self._port then return self._port end
    self._port = G_reader_settings:readSetting("filesync_port", DEFAULT_PORT)
    return self._port
end

--- Build "http://<host>[:port]". Port 80 is the HTTP default, so it is
--- omitted from the URL: "http://192.168.1.5" instead of ":80".
function FileSyncManager:_buildURL(host)
    local url = "http://" .. host
    if self._port ~= 80 then
        url = url .. ":" .. self._port
    end
    return url
end

--- Build the URL users type or scan, based on the device IP.
function FileSyncManager:getServerURL()
    return self:_buildURL(self._ip)
end

--- Build the mDNS URL (e.g. "http://filesync.local"). Only meaningful while
--- the responder is running; see isMdnsRunning().
function FileSyncManager:getServerHostnameURL()
    return self:_buildURL(self:getHostname() .. ".local")
end

function FileSyncManager:setPort(port)
    self._port = port
    G_reader_settings:saveSetting("filesync_port", port)
    G_reader_settings:flush()
end

function FileSyncManager:getHostname()
    if self._hostname then return self._hostname end
    self._hostname = G_reader_settings:readSetting("filesync_hostname", DEFAULT_HOSTNAME)
    return self._hostname
end

--- Persist a new hostname label and, if the server is running, restart the
--- mDNS responder so the new name takes effect immediately. The HTTP server
--- is untouched. The caller is responsible for validation.
function FileSyncManager:setHostname(hostname)
    self._hostname = hostname
    G_reader_settings:saveSetting("filesync_hostname", hostname)
    G_reader_settings:flush()
    if self._running then
        self:stopMdns()
        self:startMdns()
    end
end

--- Whether the mDNS responder is up, i.e. whether the .local URL can be
--- expected to work.
function FileSyncManager:isMdnsRunning()
    return self._mdns ~= nil and self._mdns:isRunning()
end

--- Start the mDNS responder for the running server. Failure is logged and
--- otherwise ignored: the HTTP server keeps working by IP.
--- @return boolean: true when the responder started
function FileSyncManager:startMdns()
    if self._mdns then return self._mdns:isRunning() end
    local ok, result = pcall(function()
        local Mdns = require("filesync/mdns")
        local mdns = Mdns:new{
            hostname = self:getHostname(),
            port = self._port,
            ip = self._ip,
        }
        if not mdns:start() then
            return nil
        end
        return mdns
    end)
    if not ok then
        logger.warn("FileSync: mDNS responder failed to start:", result)
        return false
    end
    if not result then
        -- Mdns:start() already logged the reason.
        return false
    end
    self._mdns = result
    if Device:isKindle() then
        self:openKindleFirewall(require("filesync/mdns").MDNS_PORT, "udp")
    end
    return true
end

--- Stop the mDNS responder (sends the goodbye packet), if running.
function FileSyncManager:stopMdns()
    if not self._mdns then return end
    pcall(function() self._mdns:stop() end)
    self._mdns = nil
    if Device:isKindle() then
        self:closeKindleFirewall(require("filesync/mdns").MDNS_PORT, "udp")
    end
end

function FileSyncManager:getSafeMode()
    return G_reader_settings:readSetting("filesync_safe_mode", true)
end

function FileSyncManager:setSafeMode(enabled)
    G_reader_settings:saveSetting("filesync_safe_mode", enabled)
    G_reader_settings:flush()
end

--- Marks that the one-time 8080 -> 80 port migration has already run.
local PORT_MIGRATION_KEY = "filesync_port_migrated_to_80"

--- Settings this plugin persists in G_reader_settings. Kept in one place so
--- deleteSettings() cannot drift from the readers/writers above.
local SETTINGS_KEYS = {
    "filesync_port",
    "filesync_safe_mode",
    "filesync_hostname",
    PORT_MIGRATION_KEY,
}

--- One-time migration of the saved port from 8080 to 80.
---
--- Installs that predate the port-80 default (v1.7.0) kept their saved 8080,
--- because that release deliberately left existing ports alone. Since v1.9.0
--- the server also answers to <hostname>.local, and a saved 8080 turns that
--- into "http://filesync.local:8080" -- the port suffix this name exists to
--- avoid. Move those installs to port 80 once.
---
--- Only the exact value 8080 is touched: any other custom port was chosen
--- deliberately and is left alone. The flag is written on the first run
--- whether or not a port was migrated, so a user who sets 8080 again
--- afterwards keeps it. Devices that cannot bind a privileged port are
--- covered by the fallback in startServer(), which returns them to 8080 at
--- run time without touching the setting.
---
--- @return boolean: true when a saved 8080 was rewritten to 80
function FileSyncManager:migrateSettings()
    if G_reader_settings:readSetting(PORT_MIGRATION_KEY) then return false end
    G_reader_settings:saveSetting(PORT_MIGRATION_KEY, true)

    local migrated = false
    if G_reader_settings:readSetting("filesync_port") == FALLBACK_PORT then
        G_reader_settings:saveSetting("filesync_port", DEFAULT_PORT)
        -- Keep the lazily cached value coherent with what was just written.
        self._port = DEFAULT_PORT
        migrated = true
        logger.info("FileSync: migrated saved port", FALLBACK_PORT, "to", DEFAULT_PORT)
    end

    G_reader_settings:flush()
    return migrated
end

--- Remove every setting this plugin owns, restoring first-run defaults.
--- Called by KOReader's plugin manager through FileSync:deletePluginSettings().
function FileSyncManager:deleteSettings()
    for _i, key in ipairs(SETTINGS_KEYS) do
        G_reader_settings:delSetting(key)
    end
    G_reader_settings:flush()
    -- Drop the cached values so a still-loaded instance re-reads the defaults.
    self._port = nil
    self._hostname = nil
end

--- Normalize and validate a hostname label typed by the user.
--- @return string|nil: the lowercased label, or nil plus an error message
function FileSyncManager:validateHostname(input)
    local Mdns = require("filesync/mdns")
    local label = (input or ""):gsub("^%s+", ""):gsub("%s+$", ""):lower()
    if label:match("%.local$") then
        return nil, _("Enter only the name, without \".local\"; it is added automatically.")
    end
    if not Mdns.isValidHostname(label) then
        return nil, _("Invalid hostname. Use 1-63 characters: lowercase letters, digits and hyphens, not starting or ending with a hyphen.")
    end
    return label
end

function FileSyncManager:configureHostname()
    local InputDialog = require("ui/widget/inputdialog")
    local hostname_dialog
    hostname_dialog = InputDialog:new{
        title = _("Hostname"),
        description = _("The server is also reachable at http://<hostname>.local on networks and devices that support mDNS. Enter only the name; \".local\" is added automatically."),
        input = self:getHostname(),
        input_hint = DEFAULT_HOSTNAME,
        buttons = {
            {
                {
                    text = _("Cancel"),
                    id = "close",
                    callback = function()
                        UIManager:close(hostname_dialog)
                    end,
                },
                {
                    text = _("Save"),
                    is_enter_default = true,
                    callback = function()
                        local label, err = self:validateHostname(hostname_dialog:getInputText())
                        if not label then
                            UIManager:show(InfoMessage:new{
                                text = err,
                                timeout = 4,
                            })
                            return
                        end
                        self:setHostname(label)
                        UIManager:close(hostname_dialog)
                        UIManager:show(InfoMessage:new{
                            text = T(_("Hostname set to %1"), label .. ".local"),
                            timeout = 3,
                        })
                    end,
                },
            },
        },
    }
    UIManager:show(hostname_dialog)
    hostname_dialog:onShowKeyboard()
end

function FileSyncManager:configurePort()
    local InputDialog = require("ui/widget/inputdialog")
    local port_dialog
    port_dialog = InputDialog:new{
        title = _("Server port"),
        input = tostring(self:getPort()),
        input_type = "number",
        input_hint = "80",
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
                            local msg
                            if new_port < 1024 then
                                -- Privileged ports only bind when KOReader runs
                                -- as root (Kobo/Kindle). Elsewhere the server
                                -- falls back to FALLBACK_PORT at start time.
                                msg = T(_("Port set to %1. Ports below 1024 need root access (available on Kobo/Kindle); if unavailable the server falls back to port %2. Restart the server for changes to take effect."), new_port, FALLBACK_PORT)
                            else
                                msg = T(_("Port set to %1. Restart the server for changes to take effect."), new_port)
                            end
                            UIManager:show(InfoMessage:new{
                                text = msg,
                                timeout = 5,
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

--- Check whether the FileSync server is currently running.
--- @return boolean
function FileSyncManager:isRunning()
    return self._running
end

--- Start the FileSync server: check WiFi, resolve IP, create HttpServer, and show QR code.
--- @param silent boolean|nil: when true, suppress UI messages and QR code display
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

    -- Continuation: runs once WiFi is confirmed up (or immediately, if it
    -- already was). Kept local to start() so it can close over `silent`.
    local function continueStart()
        -- Re-entrancy guard: an auto-start could have fired between the
        -- WiFi prompt and the connectivity callback.
        if self._running then return end

        -- Get the local IP. NetworkMgr:runWhenConnected only guarantees
        -- isConnected (IP + gateway), so the IP lookup may still fail on
        -- some devices; keep the existing retry/fallback chain.
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

        -- Start the HTTP server
        local HttpServer = require("filesync/httpserver")
        local function tryStart(p)
            return pcall(function()
                self._server = HttpServer:new{
                    port = p,
                    root_dir = root_dir,
                }
                self._server:start()
            end)
        end

        local ok, err = tryStart(port)

        -- Privileged ports (<1024) only bind when KOReader runs as root, which
        -- is the case on Kobo/Kindle but not on Android or desktop. If binding
        -- such a port fails, fall back to FALLBACK_PORT so the server still
        -- comes up instead of failing outright.
        if not ok and port < 1024 then
            logger.warn("FileSync: Could not bind privileged port", port,
                "- falling back to", FALLBACK_PORT)
            local fb_ok, fb_err = tryStart(FALLBACK_PORT)
            if fb_ok then
                ok = true
                if not silent then
                    UIManager:show(InfoMessage:new{
                        text = T(_("Port %1 needs root access and isn't available on this device. Using port %2 instead."), port, FALLBACK_PORT),
                        timeout = 5,
                    })
                end
                port = FALLBACK_PORT
            else
                err = fb_err
            end
        end

        if not ok then
            logger.err("FileSync: Failed to start server:", err)
            if not silent then
                UIManager:show(InfoMessage:new{
                    text = T(_("Failed to start server: %1"), tostring(err)),
                    timeout = 5,
                })
            end
            return
        end

        -- Add Kindle firewall rules
        if Device:isKindle() then
            self:openKindleFirewall(port)
        end

        self._running = true
        self._ip = ip
        self._port = port
        self:preventStandby()
        logger.info("FileSync: Server started on", ip .. ":" .. port)

        -- Advertise <hostname>.local now that the effective port is known.
        -- Any failure here is logged and ignored; the IP URL keeps working.
        self:startMdns()

        if not silent then
            self:showQRCode()
        end
    end

    -- WiFi gate. In silent mode (auto-start on resume) we never want to
    -- pop KOReader's "Turn on Wi-Fi?" prompt, so just bail if WiFi is off.
    -- In interactive mode, defer to NetworkMgr: if already connected,
    -- runWhenConnected fires the callback inline; otherwise it shows the
    -- standard prompt and schedules the callback after IP is assigned.
    -- If the user cancels the prompt, the callback simply never fires
    -- and no error is shown -- which is what we want.
    if not NetworkMgr:isConnected() then
        if silent then
            return
        end
        NetworkMgr:runWhenConnected(continueStart)
        return
    end

    continueStart()
end

--- Stop the FileSync server: close QR screen, stop HttpServer, remove firewall rules.
--- @param silent boolean|nil: when true, suppress UI messages and skip the KOReader restart
function FileSyncManager:stop(silent)
    if not self._running then
        return
    end

    -- Close QR screen if open
    self:closeQRScreen()

    -- Say goodbye on mDNS before the HTTP server goes away
    self:stopMdns()

    if self._server then
        pcall(function()
            self._server:stop()
        end)
        self._server = nil
    end

    -- Remove Kindle firewall rules
    if Device:isKindle() then
        self:closeKindleFirewall(self:getPort())
    end

    self._running = false
    self:allowStandby()
    logger.info("FileSync: Server stopped")

    if not silent then
        UIManager:show(InfoMessage:new{
            text = _("FileSync server stopped."),
            timeout = 2,
        })
        Utils.restartKOReader()
    end
end

function FileSyncManager:preventStandby()
    if self._standby_prevented then return end

    -- 1. Prevent standby (light sleep / screen off)
    UIManager:preventStandby()
    logger.info("FileSync: Standby prevented")

    -- 2. Pause auto-suspend via the officially supported PluginShare flag.
    --    KOReader's autosuspend plugin checks this flag on every schedule
    --    cycle and resets the suspend countdown while it is truthy.
    local PluginShare = require("pluginshare")
    PluginShare.pause_auto_suspend = true
    logger.info("FileSync: Auto-suspend paused via PluginShare")

    self._standby_prevented = true
end

function FileSyncManager:allowStandby()
    if not self._standby_prevented then return end

    -- 1. Resume auto-suspend
    local PluginShare = require("pluginshare")
    PluginShare.pause_auto_suspend = nil
    logger.info("FileSync: Auto-suspend resumed via PluginShare")

    -- 2. Allow standby again
    UIManager:allowStandby()
    logger.info("FileSync: Standby allowed")

    self._standby_prevented = false
end

function FileSyncManager:checkBatteryAndStart()
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

--- Stop the server from the QR screen: close it, show feedback, then stop and
--- restart (or refresh, on devices that cannot restart).
--- Shared by the "Stop Server" button and the confirmation dialog.
function FileSyncManager:stopFromQRScreen()
    self:closeQRScreen()
    UIManager:show(InfoMessage:new{
        text = _("Stopping server..."),
        timeout = 2,
    })
    -- Schedule the actual stop+restart after a brief moment so the
    -- InfoMessage renders on the e-ink screen before the restart
    UIManager:scheduleIn(0.5, function()
        self:stop(true)
        Utils.restartKOReader()
    end)
end

--- Ask the user what to do when leaving the QR screen while the server runs.
--- Shared by the close button and the Back key.
function FileSyncManager:confirmLeaveQRScreen()
    UIManager:show(ConfirmBox:new{
        title = _("File server is running"),
        text = _("The server will keep running in the background and prevent the device from sleeping. What would you like to do?"),
        ok_text = _("Stop server"),
        cancel_text = _("Keep running"),
        ok_callback = function()
            self:stopFromQRScreen()
        end,
        cancel_callback = function()
            self:closeQRScreen()
        end,
    })
end

--- Display a full-screen QR code with the server URL, stop button, and close button.
--- Requires the server to be running (with a valid IP address).
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

    local url = self:getServerURL()
    local screen_width = Screen:getWidth()
    local screen_height = Screen:getHeight()
    local manager = self

    -- The popup is a FocusManager so that D-pad devices can move focus between
    -- the buttons below; it is created up-front because the ButtonTables need
    -- it as their show_parent.
    local widget = FocusManager:new{
        name = "filesync_qrcode",
        covers_fullscreen = true, -- hint for UIManager:_repaint()
        width = screen_width,
        height = screen_height,
        layout = {},
    }

    -- Build the QR code widget
    local qr_size = Screen:scaleBySize(260)
    local qr_widget = QRWidget:new{
        text = url,
        width = qr_size,
        height = qr_size,
    }

    -- Icon + Title row
    local icon_path = Utils.getPluginDir() .. "/filesync/icon.png"
    local icon_size = Screen:scaleBySize(36)
    local icon_widget = ImageWidget:new{
        file = icon_path,
        width = icon_size,
        height = icon_size,
        alpha = true,
    }
    local title_text = TextWidget:new{
        text = _("FileSync"),
        face = Font:getFace("infofont", 48),
        bold = true,
        fgcolor = Blitbuffer.COLOR_BLACK,
    }
    local title_widget = HorizontalGroup:new{
        align = "center",
        icon_widget,
        HorizontalSpan:new{ width = Screen:scaleBySize(10) },
        title_text,
    }

    -- URL text. When the mDNS responder is up, the memorable .local URL comes
    -- first and the IP URL beneath it as a fallback; the QR payload stays the
    -- IP URL because .local resolution depends on the client OS.
    local url_font = Font:getFace("infofont", 22)
    local url_max_width = screen_width - Screen:scaleBySize(40)
    local url_widget
    if self:isMdnsRunning() then
        url_widget = VerticalGroup:new{
            align = "center",
            TextWidget:new{
                text = self:getServerHostnameURL(),
                face = url_font,
                fgcolor = Blitbuffer.COLOR_BLACK,
                max_width = url_max_width,
            },
            VerticalSpan:new{ width = Screen:scaleBySize(6) },
            TextWidget:new{
                text = url,
                face = Font:getFace("infofont", 18),
                fgcolor = Blitbuffer.COLOR_BLACK,
                max_width = url_max_width,
            },
        }
    else
        url_widget = TextWidget:new{
            text = url,
            face = url_font,
            fgcolor = Blitbuffer.COLOR_BLACK,
            max_width = url_max_width,
        }
    end

    -- Instructions text. On devices with physical keys we append a hint about
    -- how to drive this screen without a touchscreen.
    local instructions_text = _("Scan the QR code or enter the URL\nin your browser.\n\nBoth devices must be on the same WiFi network.")
    if Device:hasDPad() then
        instructions_text = instructions_text .. "\n\n"
            .. _("Use the arrow keys to select a button and press the centre key to activate it. Press Back to leave this screen.")
    elseif Device:hasKeys() then
        instructions_text = instructions_text .. "\n\n" .. _("Press Back to leave this screen.")
    end
    local instructions_widget = TextBoxWidget:new{
        text = instructions_text,
        face = Font:getFace("smallinfofont", 20),
        width = screen_width * 0.65,
        alignment = "center",
        fgcolor = Blitbuffer.COLOR_BLACK,
    }

    -- Stop Server button. Built as a real ButtonTable so it is tappable *and*
    -- focusable/activatable with the D-pad; the FrameContainer around it only
    -- restores the bordered look of the previous hand-rolled button.
    local stop_button_table = ButtonTable:new{
        width = Screen:scaleBySize(240),
        buttons = {
            {
                {
                    text = _("Stop Server"),
                    font_face = "infofont",
                    font_size = 20,
                    callback = function()
                        manager:stopFromQRScreen()
                    end,
                },
            },
        },
        show_parent = widget,
    }
    local stop_button = FrameContainer:new{
        bordersize = Size.border.button,
        radius = Size.radius.button,
        padding = Screen:scaleBySize(6),
        background = Blitbuffer.COLOR_WHITE,
        stop_button_table,
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

    -- X (close) button in the top-right corner, also a real ButtonTable button
    local close_button_table = ButtonTable:new{
        width = Screen:scaleBySize(64),
        buttons = {
            {
                {
                    text = "\u{00D7}", -- multiplication sign as X
                    font_face = "infofont",
                    font_size = 32,
                    callback = function()
                        manager:confirmLeaveQRScreen()
                    end,
                },
            },
        },
        show_parent = widget,
    }
    local close_button = FrameContainer:new{
        bordersize = Size.border.button,
        radius = Size.radius.button,
        padding = Screen:scaleBySize(2),
        background = Blitbuffer.COLOR_WHITE,
        close_button_table,
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

    widget[1] = frame

    -- Hand both ButtonTables' focus rows to the popup, side by side, so that
    -- Left/Right moves between "Stop Server" and the close button. (These are
    -- no-ops on devices without a D-pad, where ButtonTable has no layout.)
    widget:mergeLayoutInHorizontal(stop_button_table)
    widget:mergeLayoutInHorizontal(close_button_table)
    if widget.layout[1] and widget.layout[1][1] then
        -- Start with "Stop Server" focused (only visibly so on non-touch devices)
        widget:refocusWidget()
    end

    -- FocusManager only steps vertically between rows of its layout, and our
    -- two buttons live side by side in a single row, so Up/Down would move
    -- nowhere. Map them onto the equivalent horizontal move, so the buttons can
    -- be cycled with either axis (Left is not even available on few-keys
    -- devices, where Up/Down is the only way across).
    local focusMove = widget.onFocusMove
    function widget:onFocusMove(args)
        local dx, dy = unpack(args)
        if dx == 0 and dy ~= 0 and #self.layout == 1 then
            dx = dy > 0 and 1 or -1
            if BD.mirroredUILayout() then
                -- onFocusMove flips dx again in RTL; undo it here so that Down
                -- always moves to the next button as laid out on screen.
                dx = -dx
            end
            args = { dx, 0 }
        end
        return focusMove(self, args)
    end

    -- Key handling: on any device with keys, Back leaves the screen through the
    -- same confirmation the close button shows. Focus movement and activation
    -- (Up/Down/Left/Right, Press) are registered by FocusManager itself.
    if Device:hasKeys() then
        widget.key_events.Close = { { Device.input.group.Back } }
    end

    -- Touch handling: swallow taps that miss the buttons, so the popup is never
    -- dismissed by an accidental tap (same as the previous behaviour).
    if Device:isTouchDevice() then
        widget.ges_events.TapSwallow = {
            GestureRange:new{
                ges = "tap",
                range = Geom:new{ x = 0, y = 0, w = screen_width, h = screen_height },
            },
        }
    end

    --- Taps outside the buttons do nothing, but must not fall through.
    function widget:onTapSwallow()
        return true
    end

    --- Back key: leave the QR screen, warning that the server keeps running.
    function widget:onClose()
        manager:confirmLeaveQRScreen()
        return true
    end

    self._qr_widget = widget
    UIManager:show(widget, "full")
end

--- Only these protocols may reach the shell command below.
local FIREWALL_PROTOCOLS = { tcp = true, udp = true }

--- Add an iptables rule allowing incoming traffic on a port.
--- @param port number
--- @param protocol string|nil: "tcp" (default, HTTP) or "udp" (mDNS)
function FileSyncManager:openKindleFirewall(port, protocol)
    -- Defensive: ensure port and protocol are safe before passing to a shell command
    port = tonumber(port)
    protocol = protocol or "tcp"
    if not port or not FIREWALL_PROTOCOLS[protocol] then return end
    os.execute(string.format(
        "iptables -A INPUT -p %s --dport %d -j ACCEPT 2>/dev/null",
        protocol, port
    ))
    logger.info("FileSync: Kindle firewall rule added for", protocol, "port", port)
end

--- Remove the iptables rule added by openKindleFirewall.
function FileSyncManager:closeKindleFirewall(port, protocol)
    -- Defensive: ensure port and protocol are safe before passing to a shell command
    port = tonumber(port)
    protocol = protocol or "tcp"
    if not port or not FIREWALL_PROTOCOLS[protocol] then return end
    os.execute(string.format(
        "iptables -D INPUT -p %s --dport %d -j ACCEPT 2>/dev/null",
        protocol, port
    ))
    logger.info("FileSync: Kindle firewall rule removed for", protocol, "port", port)
end

return FileSyncManager
