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
    _was_running_before_suspend = false,
    _standby_prevented = false,
    _qr_widget = nil,
}

local DEFAULT_PORT = 8080
-- The Root PIN is stored in plain plugin settings because this first version
-- needs to reveal it locally on the device. This is convenient, not secure.
local ROOT_PIN_SETTING_KEY = "filesync_root_pin"

function FileSyncManager:getPort()
    if self._port then return self._port end
    self._port = G_reader_settings:readSetting("filesync_port", DEFAULT_PORT)
    return self._port
end

function FileSyncManager:setPort(port)
    self._port = port
    G_reader_settings:saveSetting("filesync_port", port)
    G_reader_settings:flush()
end

function FileSyncManager:getSafeMode()
    return G_reader_settings:readSetting("filesync_safe_mode", true)
end

function FileSyncManager:setSafeMode(enabled)
    G_reader_settings:saveSetting("filesync_safe_mode", enabled)
    G_reader_settings:flush()
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
    if self._server and self._server.setRootUnlocked then
        self._server:setRootUnlocked(false)
    elseif self._server then
        self._server._root_unlocked = false
    end
end

function FileSyncManager:setRootPin(pin)
    local normalized_pin, err = self:_validateRootPin(pin)
    if not normalized_pin then
        return false, err
    end

    G_reader_settings:saveSetting(ROOT_PIN_SETTING_KEY, normalized_pin)
    G_reader_settings:flush()
    self:_resetRootUnlock()
    return true
end

function FileSyncManager:removeRootPin()
    if G_reader_settings.delSetting then
        G_reader_settings:delSetting(ROOT_PIN_SETTING_KEY)
    else
        G_reader_settings:saveSetting(ROOT_PIN_SETTING_KEY, nil)
    end
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

function FileSyncManager:promptSetRootPin(is_change)
    local InputDialog = require("ui/widget/inputdialog")
    local pin_dialog
    local title = is_change and _("Change Root PIN") or _("Define Root PIN")
    local success_message = is_change and _("Root PIN updated.") or _("Root PIN saved.")

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
        input_hint = "8080",
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
                        if new_port and new_port >= 1024 and new_port <= 65535 then
                            self:setPort(new_port)
                            UIManager:close(port_dialog)
                            UIManager:show(InfoMessage:new{
                                text = T(_("Port set to %1. Restart the server for changes to take effect."), new_port),
                                timeout = 3,
                            })
                        else
                            UIManager:show(InfoMessage:new{
                                text = _("Invalid port. Please enter a number between 1024 and 65535."),
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

function FileSyncManager:isRunning()
    return self._running
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

    -- Start the HTTP server
    local HttpServer = require("filesync/httpserver")
    local ok, err = pcall(function()
        self._server = HttpServer:new{
            port = port,
            root_dir = root_dir,
        }
        self._server:start()
    end)

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

    if not silent then
        self:showQRCode()
    end
end

function FileSyncManager:stop(silent)
    if not self._running then
        return
    end

    -- Close QR screen if open
    self:closeQRScreen()

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
        UIManager:restartKOReader()
    end
end

function FileSyncManager:preventStandby()
    if not self._standby_prevented then
        UIManager:preventStandby()
        self._standby_prevented = true
        logger.info("FileSync: Standby prevented")
    end
end

function FileSyncManager:allowStandby()
    if self._standby_prevented then
        UIManager:allowStandby()
        self._standby_prevented = false
        logger.info("FileSync: Standby allowed")
    end
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

    local url = "http://" .. self._ip .. ":" .. self._port
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
    local icon_widget = ImageWidget:new{
        file = icon_dir .. "icon.png",
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
                -- Stop button tapped: show feedback, then stop and restart
                self._manager:closeQRScreen()
                UIManager:show(InfoMessage:new{
                    text = _("Stopping server..."),
                    timeout = 2,
                })
                -- Schedule the actual stop+restart after a brief moment so the
                -- InfoMessage renders on the e-ink screen before the restart
                UIManager:scheduleIn(0.5, function()
                    self._manager:stop(true)
                    UIManager:restartKOReader()
                end)
                return true
            end
        end

        -- Check if the tap is on the X close button
        local close_btn = self._close_button
        if close_btn.dimen then
            if x >= close_btn.dimen.x and x <= close_btn.dimen.x + close_btn.dimen.w
               and y >= close_btn.dimen.y and y <= close_btn.dimen.y + close_btn.dimen.h then
                -- X button tapped: dismiss QR screen, show info, keep server running
                self._manager:closeQRScreen()
                UIManager:show(InfoMessage:new{
                    text = _("Server running in the background. Stop the server to save battery."),
                    timeout = 4,
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
    -- Add iptables rule to allow incoming connections on the server port
    os.execute(string.format(
        "iptables -A INPUT -p tcp --dport %d -j ACCEPT 2>/dev/null",
        port
    ))
    logger.info("FileSync: Kindle firewall rule added for port", port)
end

function FileSyncManager:closeKindleFirewall(port)
    -- Remove the iptables rule
    os.execute(string.format(
        "iptables -D INPUT -p tcp --dport %d -j ACCEPT 2>/dev/null",
        port
    ))
    logger.info("FileSync: Kindle firewall rule removed for port", port)
end

return FileSyncManager
