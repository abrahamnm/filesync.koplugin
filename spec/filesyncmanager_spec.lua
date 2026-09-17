require("spec.helper")

-- The manager pulls in a long list of KOReader widget modules. None of them
-- matter for the settings migration, so stub every one with a permissive table
-- whose fields answer to any call. Loading the real module keeps the test
-- honest about the code that ships.
local function stub_koreader_modules()
    local permissive
    permissive = function()
        return setmetatable({}, {
            __index = function() return permissive() end,
            __call = function() return permissive() end,
        })
    end
    for _, name in ipairs({
        "ui/bidi", "ffi/blitbuffer", "ui/widget/buttontable",
        "ui/widget/container/centercontainer", "ui/widget/confirmbox",
        "ui/widget/focusmanager", "ui/widget/container/framecontainer",
        "ui/geometry", "ui/gesturerange", "ui/widget/infomessage",
        "ui/network/manager", "ui/widget/overlapgroup", "ui/widget/qrwidget",
        "ui/widget/container/rightcontainer", "ui/size",
        "ui/widget/textboxwidget", "ui/widget/textwidget", "ui/uimanager",
        "ui/widget/verticalgroup", "ui/widget/verticalspan", "ui/font",
        "ui/widget/horizontalgroup", "ui/widget/horizontalspan",
        "ui/widget/imagewidget",
    }) do
        package.loaded[name] = permissive()
    end
    package.loaded["device"] = {
        screen = permissive(),
        isKindle = function() return false end,
    }
    package.loaded["gettext"] = setmetatable({}, {
        __call = function(_self, s) return s end,
    })
    package.loaded["ffi/util"] = { template = function(s) return s end }
end

-- Minimal stand-in for KOReader's LuaSettings, exposing only the four methods
-- the plugin uses.
local function fake_settings(initial)
    local store = {}
    for k, v in pairs(initial or {}) do store[k] = v end
    return {
        store = store,
        flushed = 0,
        readSetting = function(self, key, default)
            local value = self.store[key]
            if value == nil then return default end
            return value
        end,
        saveSetting = function(self, key, value) self.store[key] = value end,
        delSetting = function(self, key) self.store[key] = nil end,
        flush = function(self) self.flushed = self.flushed + 1 end,
    }
end

stub_koreader_modules()
local FileSyncManager = require("filesync.filesyncmanager")

local MIGRATION_KEY = "filesync_port_migrated_to_80"

describe("FileSyncManager settings migration", function()
    local previous_settings

    before_each(function()
        previous_settings = _G.G_reader_settings
        -- Drop the lazily cached port between examples.
        FileSyncManager._port = nil
    end)

    after_each(function()
        _G.G_reader_settings = previous_settings
        FileSyncManager._port = nil
    end)

    it("moves a saved 8080 to 80", function()
        local settings = fake_settings({ filesync_port = 8080 })
        _G.G_reader_settings = settings

        assert.is_true(FileSyncManager:migrateSettings())
        assert.are.equal(80, settings.store.filesync_port)
        assert.is_true(settings.flushed > 0)
    end)

    it("marks the migration as done so it never runs twice", function()
        local settings = fake_settings({ filesync_port = 8080 })
        _G.G_reader_settings = settings

        FileSyncManager:migrateSettings()
        assert.is_true(settings.store[MIGRATION_KEY])

        -- A user who deliberately goes back to 8080 keeps it.
        settings.store.filesync_port = 8080
        FileSyncManager._port = nil
        assert.is_false(FileSyncManager:migrateSettings())
        assert.are.equal(8080, settings.store.filesync_port)
    end)

    it("leaves other custom ports alone", function()
        local settings = fake_settings({ filesync_port = 8081 })
        _G.G_reader_settings = settings

        assert.is_false(FileSyncManager:migrateSettings())
        assert.are.equal(8081, settings.store.filesync_port)
        assert.is_true(settings.store[MIGRATION_KEY])
    end)

    it("leaves a fresh install with no saved port untouched", function()
        local settings = fake_settings({})
        _G.G_reader_settings = settings

        assert.is_false(FileSyncManager:migrateSettings())
        assert.is_nil(settings.store.filesync_port)
        assert.are.equal(80, FileSyncManager:getPort())
    end)

    it("updates the cached port so the URL drops the suffix", function()
        local settings = fake_settings({ filesync_port = 8080 })
        _G.G_reader_settings = settings

        assert.are.equal(8080, FileSyncManager:getPort())
        FileSyncManager:migrateSettings()

        assert.are.equal(80, FileSyncManager:getPort())
        assert.are.equal("http://filesync.local", FileSyncManager:getServerHostnameURL())
    end)

    it("clears the migration flag with the rest of the settings", function()
        local settings = fake_settings({ filesync_port = 8080 })
        _G.G_reader_settings = settings

        FileSyncManager:migrateSettings()
        FileSyncManager:deleteSettings()

        assert.is_nil(settings.store[MIGRATION_KEY])
        assert.is_nil(settings.store.filesync_port)
    end)
end)
