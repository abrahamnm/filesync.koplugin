require("spec.helper")

local DeviceInfo = require("filesync/deviceinfo")
local JSON = require("filesync/json")

local function yes() return true end
local function no() return false end

-- Build a stand-in for KOReader's Device object. Device checks are plain
-- yes/no closures like KOReader's, and Screen mimics ffi/framebuffer.lua:
-- getScreenWidth/Height report the unrotated framebuffer size, getWidth/Height
-- the current (rotated) one.
local function fake_device(opts)
    local platform = opts.platform
    local color_rendering = opts.color_rendering
    local screen = {
        getScreenWidth = function() return opts.fb_w end,
        getScreenHeight = function() return opts.fb_h end,
        getWidth = function() return opts.cur_w or opts.fb_w end,
        getHeight = function() return opts.cur_h or opts.fb_h end,
        getDPI = function() return opts.dpi end,
    }
    local device = {
        model = opts.model,
        screen = screen,
        isKobo = platform == "kobo" and yes or no,
        isKindle = platform == "kindle" and yes or no,
        isPocketBook = platform == "pocketbook" and yes or no,
        isAndroid = platform == "android" and yes or no,
        isRemarkable = platform == "remarkable" and yes or no,
        isCervantes = platform == "cervantes" and yes or no,
        isSDL = platform == "sdl" and yes or no,
    }
    if not opts.no_color_apis then
        device.hasColorScreen = opts.color_screen and yes or no
        -- generic/device.lua: the "color_rendering" setting wins, else the
        -- hardware capability.
        screen.isColorEnabled = function()
            if color_rendering ~= nil then return color_rendering end
            return opts.color_screen
        end
    end
    -- Let tests flip the setting at runtime.
    device._setColorRendering = function(v) color_rendering = v end
    return device
end

local function fake_version(rev)
    return { getCurrentRevision = function() return rev end }
end

-- Round-trip through the plugin's JSON encoder so the assertions are on what
-- a client actually receives.
local function as_json(provider)
    local info = provider()
    local encoded = JSON.encode(info)
    local decoded = JSON.decode(encoded)
    assert.is_not_nil(decoded, "device block is not valid JSON: " .. encoded)
    return decoded
end

describe("filesync.deviceinfo", function()

    it("describes a Kobo Libra Colour", function()
        local device = fake_device{
            platform = "kobo", model = "Kobo_monza",
            fb_w = 1264, fb_h = 1680, dpi = 300, color_screen = true,
        }
        local p = DeviceInfo.provider(device, fake_version("v2025.08"))
        assert.are.same({
            model = "Kobo_monza",
            platform = "kobo",
            screen = { width = 1264, height = 1680, dpi = 300 },
            color_screen = true,
            color_enabled = true,
            koreader_version = "v2025.08",
        }, as_json(p))
    end)

    it("describes a black-and-white Kindle", function()
        local device = fake_device{
            platform = "kindle", model = "KindlePaperWhite5",
            fb_w = 1236, fb_h = 1648, dpi = 300, color_screen = false,
            -- Even with colour rendering forced on in the settings, a B/W
            -- panel reports color_enabled = false.
            color_rendering = true,
        }
        local p = DeviceInfo.provider(device, fake_version("v2024.11"))
        assert.are.same({
            model = "KindlePaperWhite5",
            platform = "kindle",
            screen = { width = 1236, height = 1648, dpi = 300 },
            color_screen = false,
            color_enabled = false,
            koreader_version = "v2024.11",
        }, as_json(p))
    end)

    it("reports portrait size when the framebuffer is natively landscape", function()
        local device = fake_device{
            platform = "pocketbook", model = "PB743G",
            fb_w = 1872, fb_h = 1404, dpi = 227, color_screen = false,
        }
        local info = as_json(DeviceInfo.provider(device, fake_version("v2025.04")))
        assert.are.same({ width = 1404, height = 1872, dpi = 227 }, info.screen)
        assert.is_true(info.screen.width <= info.screen.height)
    end)

    it("reports portrait size when the screen is rotated and only getWidth/getHeight exist", function()
        local device = fake_device{
            platform = "kobo", model = "Kobo_monza",
            cur_w = 1680, cur_h = 1264, dpi = 300, color_screen = true,
        }
        device.screen.getScreenWidth = nil
        device.screen.getScreenHeight = nil
        local info = as_json(DeviceInfo.provider(device, fake_version("v2025.08")))
        assert.are.same({ width = 1264, height = 1680, dpi = 300 }, info.screen)
    end)

    it("leaves out only the colour fields on a KOReader without the colour APIs", function()
        local device = fake_device{
            platform = "kobo", model = "Kobo_frost",
            fb_w = 1440, fb_h = 1920, dpi = 300, no_color_apis = true,
        }
        local p = DeviceInfo.provider(device, fake_version("v2017.10.04-nightly"))
        assert.are.same({
            model = "Kobo_frost",
            platform = "kobo",
            screen = { width = 1440, height = 1920, dpi = 300 },
            koreader_version = "v2017.10.04-nightly",
        }, as_json(p))
    end)

    it("reads color_enabled fresh on every call", function()
        local device = fake_device{
            platform = "kobo", model = "Kobo_monza",
            fb_w = 1264, fb_h = 1680, dpi = 300, color_screen = true,
        }
        local p = DeviceInfo.provider(device, fake_version("v2025.08"))
        assert.is_true(p().color_enabled)
        device._setColorRendering(false)
        assert.is_false(p().color_enabled)
        device._setColorRendering(true)
        assert.is_true(p().color_enabled)
    end)

    it("does not let callers mutate the cached values", function()
        local device = fake_device{
            platform = "kobo", model = "Kobo_monza",
            fb_w = 1264, fb_h = 1680, dpi = 300, color_screen = true,
        }
        local p = DeviceInfo.provider(device, fake_version("v2025.08"))
        local first = p()
        first.screen.width = 1
        first.model = "changed"
        local second = p()
        assert.are.equal(1264, second.screen.width)
        assert.are.equal("Kobo_monza", second.model)
    end)

    it("maps every platform check", function()
        for _, platform in ipairs({ "kobo", "kindle", "pocketbook", "android",
                                    "remarkable", "cervantes", "sdl" }) do
            assert.are.equal(platform, DeviceInfo.platform(fake_device{ platform = platform }))
        end
        assert.are.equal("other", DeviceInfo.platform(fake_device{ platform = "sony" }))
    end)

    it("treats a missing isRemarkable/isCervantes as no", function()
        local device = fake_device{ platform = "sony" }
        device.isRemarkable = nil
        device.isCervantes = nil
        assert.are.equal("other", DeviceInfo.platform(device))
    end)

    it("survives every device API throwing", function()
        local boom = function() error("boom") end
        local device = {
            screen = {
                getScreenWidth = boom, getScreenHeight = boom,
                getWidth = boom, getHeight = boom, getDPI = boom,
                isColorEnabled = boom,
            },
            isKobo = boom, isKindle = boom, isPocketBook = boom, isAndroid = boom,
            isRemarkable = boom, isCervantes = boom, isSDL = boom,
            hasColorScreen = boom,
        }
        local version = { getCurrentRevision = boom }
        local p = DeviceInfo.provider(device, version)
        local ok, info = pcall(p)
        assert.is_true(ok)
        -- Nothing readable but the fallback platform.
        assert.are.same({ platform = "other" }, info)
    end)

    it("survives a Device whose field access throws", function()
        local device = setmetatable({}, { __index = function() error("no such field") end })
        local p = DeviceInfo.provider(device, fake_version("v2025.08"))
        local ok, info = pcall(p)
        assert.is_true(ok)
        assert.are.same({ platform = "other", koreader_version = "v2025.08" }, info)
    end)

    it("drops non-numeric or non-positive screen values", function()
        local device = fake_device{
            platform = "kobo", model = "Kobo_monza",
            fb_w = 0, fb_h = 0 / 0, dpi = "300", color_screen = true,
        }
        device.screen.getWidth = function() return nil end
        local info = as_json(DeviceInfo.provider(device, fake_version("v2025.08")))
        assert.is_nil(info.screen)
    end)

    it("leaves out koreader_version when the version module has no revision", function()
        local device = fake_device{
            platform = "kobo", model = "Kobo_monza",
            fb_w = 1264, fb_h = 1680, dpi = 300, color_screen = true,
        }
        local info = as_json(DeviceInfo.provider(device, fake_version(nil)))
        assert.is_nil(info.koreader_version)
        assert.are.equal("Kobo_monza", info.model)
    end)

    it("includes no identifying fields", function()
        local device = fake_device{
            platform = "kobo", model = "Kobo_monza",
            fb_w = 1264, fb_h = 1680, dpi = 300, color_screen = true,
        }
        local info = DeviceInfo.provider(device, fake_version("v2025.08"))()
        local allowed = {
            model = true, platform = true, screen = true, color_screen = true,
            color_enabled = true, koreader_version = true,
        }
        for k in pairs(info) do
            assert.is_true(allowed[k] == true, "unexpected field " .. tostring(k))
        end
    end)
end)
