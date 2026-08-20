--- Tests for the Simple UI quick action integration.

-- Stub the KOReader modules simpleui.lua requires at load time.
local scheduled = {}
package.loaded["ui/uimanager"] = {
    scheduleIn = function(_, seconds, callback)
        scheduled[#scheduled + 1] = { seconds = seconds, callback = callback }
    end,
    broadcastEvent = function(_, event)
        scheduled.last_event = event
    end,
}
package.loaded["ui/event"] = {
    new = function(_, name) return { name = name } end,
}
package.loaded["gettext"] = function(s) return s end
package.loaded["filesync/utils"] = {
    getPluginDir = function() return "/tmp/fake_plugin" end,
}

local SimpleUI = require("filesync/simpleui")

--- Reset the module's registration state between tests.
local function reset()
    SimpleUI._registered = false
    SimpleUI._attempts = 0
    SimpleUI._retry_scheduled = false
    scheduled = {}
    package.loaded["features/sui_quickactions"] = nil
    package.loaded["infra/sui_config"] = nil
end

--- Install a fake Simple UI Quick Actions module and return it.
local function fakeQuickActions()
    local QA = { registered = {} }
    QA.register = function(descriptor)
        QA.registered[#QA.registered + 1] = descriptor
    end
    package.loaded["features/sui_quickactions"] = QA
    return QA
end

describe("filesync.simpleui", function()

    before_each(reset)
    after_each(reset)

    describe("getDescriptor", function()

        it("uses a stable id and the plugin icon", function()
            local d = SimpleUI:getDescriptor()
            assert.are.equal("filesync_toggle_server", d.id)
            assert.are.equal("/tmp/fake_plugin/filesync/icon.png", d.icon)
        end)

        it("runs in place asynchronously", function()
            local d = SimpleUI:getDescriptor()
            assert.is_true(d.is_in_place)
            assert.is_true(d.is_async_in_place)
        end)

        it("labels the action by the server state", function()
            local running = false
            package.loaded["filesync/filesyncmanager"] = {
                isRunning = function() return running end,
            }
            local d = SimpleUI:getDescriptor()
            assert.are.equal("Start file server", d.get_label())
            running = true
            assert.are.equal("Stop file server", d.get_label())
            package.loaded["filesync/filesyncmanager"] = nil
        end)

        it("falls back to the start label when the manager cannot be loaded", function()
            package.loaded["filesync/filesyncmanager"] = nil
            local d = SimpleUI:getDescriptor()
            assert.are.equal("Start file server", d.get_label())
        end)

        it("broadcasts the toggle event on execute", function()
            SimpleUI:getDescriptor().execute()
            assert.are.equal("ToggleFileSyncServer", scheduled.last_event.name)
        end)
    end)

    describe("register", function()

        it("registers the descriptor when Simple UI is available", function()
            local QA = fakeQuickActions()
            assert.is_true(SimpleUI:register())
            assert.are.equal(1, #QA.registered)
            assert.are.equal("filesync_toggle_server", QA.registered[1].id)
        end)

        it("invalidates the Simple UI tabs cache", function()
            fakeQuickActions()
            local invalidated = false
            package.loaded["infra/sui_config"] = {
                invalidateTabsCache = function() invalidated = true end,
            }
            SimpleUI:register()
            assert.is_true(invalidated)
        end)

        it("does not register twice", function()
            local QA = fakeQuickActions()
            SimpleUI:register()
            SimpleUI:register()
            assert.are.equal(1, #QA.registered)
        end)

        it("schedules a retry when Simple UI is not loaded yet", function()
            assert.is_false(SimpleUI:register())
            assert.are.equal(1, #scheduled)
            assert.are.equal(SimpleUI.RETRY_INTERVAL, scheduled[1].seconds)
        end)

        it("registers on a retry once Simple UI has loaded", function()
            assert.is_false(SimpleUI:register())
            local QA = fakeQuickActions()
            scheduled[1].callback()
            assert.is_true(SimpleUI._registered)
            assert.are.equal(1, #QA.registered)
        end)

        it("keeps only one pending retry at a time", function()
            SimpleUI:register()
            SimpleUI:register()
            assert.are.equal(1, #scheduled)
        end)

        it("gives up after MAX_ATTEMPTS", function()
            for _ = 1, SimpleUI.MAX_ATTEMPTS + 2 do
                SimpleUI._retry_scheduled = false
                SimpleUI:register()
            end
            assert.are.equal(SimpleUI.MAX_ATTEMPTS - 1, #scheduled)
            assert.is_false(SimpleUI._registered)
        end)

        it("survives a Simple UI module that throws", function()
            package.loaded["features/sui_quickactions"] = {
                register = function() error("boom") end,
            }
            assert.is_false(SimpleUI:register())
            assert.is_false(SimpleUI._registered)
        end)
    end)
end)
