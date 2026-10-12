--- Read-only description of the screen KOReader is running on, for the
--- `device` block of `GET /api/health`.
---
--- Companion apps use it to size and colour-convert images for the reader
--- (for example sleep screens) without asking the user for a model.
---
--- Contract (every field optional; a missing KOReader API drops only its own
--- field, and the whole block is left out if nothing could be read):
---
---   device = {
---     model            = "Kobo_monza",  -- Device.model
---     platform         = "kobo",        -- Device:isKobo()/isKindle()/... checks
---     screen = {
---       width  = 1264,                  -- native panel size, portrait (width <= height)
---       height = 1680,
---       dpi    = 300,                   -- Screen:getDPI()
---     },
---     color_screen     = true,          -- Device:hasColorScreen()
---     color_enabled    = true,          -- Screen:isColorEnabled(), false on B/W panels
---     koreader_version = "v2025.08",    -- Version:getCurrentRevision()
---   }
---
--- KOReader APIs used, and the oldest release each was checked against:
---   Device.model                        all versions (frontend/device/*/device.lua)
---   Device:isKobo/isKindle/isPocketBook/isAndroid/isSDL   all versions
---   Device:isCervantes()                v2018.11 and later
---   Device:isRemarkable()               v2020.02 and later
---   Screen:getScreenWidth/Height()      koreader-base ffi/framebuffer.lua, v2019.12 and earlier
---     (size of the framebuffer at init, i.e. unrotated; falls back to
---      Screen:getWidth/getHeight(); the two values are then sorted so
---      width <= height whatever the native or current rotation)
---   Screen:getDPI()                     koreader-base ffi/framebuffer.lua, all versions
---     (honours a user "Screen DPI" override, like the rest of KOReader)
---   Device:hasColorScreen()             v2017.10 and earlier (generic/device.lua)
---   Screen:isColorEnabled()             v2017.10 and earlier; set up in generic/device.lua
---                                       from the "color_rendering" setting
---   require("version"):getCurrentRevision()   frontend/version.lua, v2018.11 and earlier
---
--- Nothing here identifies a person or a particular unit: no serial number,
--- MAC address, Wi-Fi name or user path is read.
---
--- This module never requires KOReader modules on its own except "version"
--- (lazily, guarded). The Device object is passed in, so it can be stubbed in
--- tests.

local DeviceInfo = {}

-- Read obj[key] without raising (Device tables may use __index metamethods).
local function get_field(obj, key)
    if type(obj) ~= "table" then return nil end
    local ok, v = pcall(function() return obj[key] end)
    if ok then return v end
    return nil
end

-- Call obj[method](obj, ...) if it exists; return the result or nil.
-- Never raises.
local function try_method(obj, method, ...)
    local fn = get_field(obj, method)
    if type(fn) ~= "function" then return nil end
    local ok, result = pcall(fn, obj, ...)
    if not ok then return nil end
    return result
end

local function positive_number(v)
    if type(v) == "number" and v == v and v > 0 and v < math.huge then
        return math.floor(v + 0.5)
    end
    return nil
end

-- Order matters only for exotic builds that answer yes to more than one check.
local PLATFORM_CHECKS = {
    { "isKobo",       "kobo" },
    { "isKindle",     "kindle" },
    { "isPocketBook", "pocketbook" },
    { "isAndroid",    "android" },
    { "isRemarkable", "remarkable" },
    { "isCervantes",  "cervantes" },
    { "isSDL",        "sdl" },
}

--- Map KOReader's device checks to one platform string.
--- @return string one of kobo, kindle, pocketbook, android, remarkable, cervantes, sdl, other
function DeviceInfo.platform(Device)
    for _, check in ipairs(PLATFORM_CHECKS) do
        if try_method(Device, check[1]) == true then
            return check[2]
        end
    end
    return "other"
end

--- Native panel size in portrait orientation, plus DPI.
--- @return table|nil {width, height, dpi}, any of which may be missing
function DeviceInfo.screen(Device)
    local Screen = get_field(Device, "screen")
    if type(Screen) ~= "table" then return nil end

    local w = positive_number(try_method(Screen, "getScreenWidth"))
    local h = positive_number(try_method(Screen, "getScreenHeight"))
    if not (w and h) then
        -- Current (possibly rotated) size; sorted below, so still portrait.
        w = positive_number(try_method(Screen, "getWidth"))
        h = positive_number(try_method(Screen, "getHeight"))
    end

    local screen = {}
    if w and h then
        screen.width = math.min(w, h)
        screen.height = math.max(w, h)
    end
    screen.dpi = positive_number(try_method(Screen, "getDPI"))

    if next(screen) == nil then return nil end
    return screen
end

--- Whether KOReader is rendering in colour right now. Can change at runtime
--- (Settings > Screen > Color rendering), so it is read fresh on each call.
--- Always false when the panel is known to be black and white.
--- @param color_screen boolean|nil the cached hardware capability
--- @return boolean|nil nil when the API is missing or fails
function DeviceInfo.colorEnabled(Device, color_screen)
    if color_screen == false then return false end
    local enabled = try_method(get_field(Device, "screen"), "isColorEnabled")
    if type(enabled) ~= "boolean" then return nil end
    return enabled
end

--- Fields that cannot change while KOReader runs.
--- @param Device table KOReader's Device object (require("device"))
--- @param Version table|nil KOReader's version module; loaded lazily if nil
--- @return table possibly empty
function DeviceInfo.collectStatic(Device, Version)
    local info = {}

    local model = get_field(Device, "model")
    if type(model) == "string" and model ~= "" then
        info.model = model
    end

    info.platform = DeviceInfo.platform(Device)
    info.screen = DeviceInfo.screen(Device)

    local color_screen = try_method(Device, "hasColorScreen")
    if type(color_screen) == "boolean" then
        info.color_screen = color_screen
    end

    if Version == nil then
        local ok, mod = pcall(require, "version")
        if ok then Version = mod end
    end
    local rev = try_method(Version, "getCurrentRevision")
    if type(rev) == "string" and rev ~= "" then
        info.koreader_version = rev
    end

    return info
end

--- Build a provider for HttpServer: a function returning a fresh `device`
--- table on each call, or nil if nothing could be read. Static fields are
--- computed on the first call and cached; color_enabled is read every time.
--- The provider never raises.
--- @param Device table KOReader's Device object
--- @param Version table|nil optional version module (for tests)
--- @return function
function DeviceInfo.provider(Device, Version)
    local static = nil
    return function()
        if static == nil then
            local ok, result = pcall(DeviceInfo.collectStatic, Device, Version)
            static = ok and type(result) == "table" and result or {}
        end

        local info = {}
        for k, v in pairs(static) do
            if k == "screen" then
                info.screen = { width = v.width, height = v.height, dpi = v.dpi }
            else
                info[k] = v
            end
        end

        local ok, enabled = pcall(DeviceInfo.colorEnabled, Device, static.color_screen)
        if ok and type(enabled) == "boolean" then
            info.color_enabled = enabled
        end

        if next(info) == nil then return nil end
        return info
    end
end

return DeviceInfo
