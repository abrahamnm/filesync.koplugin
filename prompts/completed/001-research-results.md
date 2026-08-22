# KOReader Dispatcher Integration Research

## How Dispatcher Registration Works

The Dispatcher is KOReader's central system for mapping user-configurable actions (gestures, profiles, quick menus) to plugin functionality. It lives in `frontend/dispatcher.lua`.

### Registration Mechanism

1. **`Dispatcher:init()`** is called once. At the end, it broadcasts:
   ```lua
   UIManager:broadcastEvent(Event:new("DispatcherRegisterActions"))
   ```

2. **Plugins implement `onDispatcherRegisterActions()`** to handle this broadcast event. However, in practice, most plugins also call `self:onDispatcherRegisterActions()` directly from their own `init()` method. This is the standard pattern -- the direct call in `init()` ensures registration happens even if the broadcast timing is not ideal.

3. **`Dispatcher:registerAction(name, value)`** adds the action to the internal `settingsList` table and appends the name to `dispatcher_menu_order` (which controls UI ordering). It is idempotent -- if the name already exists, it does nothing:
   ```lua
   function Dispatcher:registerAction(name, value)
       if settingsList[name] == nil then
           settingsList[name] = value
           table.insert(dispatcher_menu_order, name)
       end
       return true
   end
   ```

### Event Dispatch Flow

When a user triggers a dispatcher action (via gesture, profile, or quick menu):

1. `Dispatcher:execute(settings)` iterates over the configured actions.
2. For `category="none"` actions, it calls:
   ```lua
   UIManager:sendEvent(Event:new(event_name))
   ```
3. The plugin's `onEventName()` method handles this event (KOReader's event system automatically routes `Event:new("Foo")` to any widget's `onFoo()` method).

**There are no callback functions.** The mapping is purely event-based: the `event` field in the registration table determines which `on<Event>()` method will be called on the plugin.

## Action Data Structure

```lua
Dispatcher:registerAction("action_key_name", {
    category = "none",           -- REQUIRED: "none"|"arg"|"absolutenumber"|"incrementalnumber"|"string"|"configurable"
    event    = "EventName",      -- REQUIRED: maps to on<EventName>() handler method
    title    = _("Display text"),-- REQUIRED: shown in gesture/profile/quick-menu configuration UI

    -- Section flags (at least one REQUIRED, controls where the action appears):
    general     = true,  -- "General" section (available everywhere: file browser + reader)
    device      = true,  -- "Device" section
    screen      = true,  -- "Screen and lights" section
    filemanager = true,  -- "File browser" section only
    reader      = true,  -- "Reader" section only
    rolling     = true,  -- "Reflowable documents" section only
    paging      = true,  -- "Fixed layout documents" section only

    -- Optional fields:
    arg       = value,   -- for "none" category: passed as argument to the event
    condition = bool,    -- if false, action is hidden from menus entirely
    separator = true,    -- adds a visual separator after this item in menus
})
```

### Category Types

| Category | Behavior | Event call |
|---|---|---|
| `"none"` | Simple fire-and-forget, no parameters | `Event:new(event_name)` or `Event:new(event_name, arg)` if `arg` is set |
| `"arg"` | Passes gesture object as argument | `Event:new(event_name, gesture)` |
| `"absolutenumber"` | User picks a number (min/max/step) | `Event:new(event_name, value)` |
| `"incrementalnumber"` | User picks a delta or gesture controls it | `Event:new(event_name, value_or_gesture)` |
| `"string"` | User picks from predefined options | `Event:new(event_name, selected_arg)` |
| `"configurable"` | Like string but also updates document config | `Event:new("ConfigChange", ...)` + `Event:new(event_name, ...)` |

### Section Flags

The UI organizes actions into these sections (defined in `section_list`):

```lua
{"general",     _("General")}
{"device",      _("Device")}
{"screen",      _("Screen and lights")}
{"filemanager", _("File browser")}
{"reader",      _("Reader")}
{"rolling",     _("Reflowable documents (epub, fb2, txt...)")}
{"paging",      _("Fixed layout documents (pdf, djvu, pics...)")}
```

For FileSync, `general=true` is the correct choice since the server can be toggled from both the file browser and while reading a document.

## Minimal Example: Hello World Plugin

This is KOReader's official example plugin (`plugins/hello.koplugin/main.lua`):

```lua
local Dispatcher = require("dispatcher")
local InfoMessage = require("ui/widget/infomessage")
local UIManager = require("ui/uimanager")
local WidgetContainer = require("ui/widget/container/widgetcontainer")
local _ = require("gettext")

local Hello = WidgetContainer:extend{
    name = "hello",
    is_doc_only = false,
}

function Hello:onDispatcherRegisterActions()
    Dispatcher:registerAction("helloworld_action", {
        category = "none",
        event = "HelloWorld",
        title = _("Hello World"),
        general = true,
    })
end

function Hello:init()
    self:onDispatcherRegisterActions()
    self.ui.menu:registerToMainMenu(self)
end

function Hello:addToMainMenu(menu_items)
    menu_items.hello_world = {
        text = _("Hello World"),
        sorting_hint = "more_tools",
        callback = function()
            UIManager:show(InfoMessage:new{
                text = _("Hello, plugin world"),
            })
        end,
    }
end

-- This handler is called when the dispatcher action fires
function Hello:onHelloWorld()
    local popup = InfoMessage:new{
        text = _("Hello World"),
    }
    UIManager:show(popup)
end

return Hello
```

## Closest Analog: SSH Plugin (Server Toggle)

The SSH plugin (`plugins/SSH.koplugin/main.lua`) is the closest existing pattern to what FileSync needs. It registers a toggle action that starts or stops a server:

```lua
-- Registration (in init and as event handler):
function SSH:onDispatcherRegisterActions()
    Dispatcher:registerAction("toggle_ssh_server", {
        category = "none",
        event = "ToggleSSHServer",
        title = _("Toggle SSH server"),
        general = true,
    })
end

function SSH:init()
    -- ... setup ...
    self.ui.menu:registerToMainMenu(self)
    self:onDispatcherRegisterActions()
end

-- Handler — the event name "ToggleSSHServer" maps to onToggleSSHServer():
function SSH:onToggleSSHServer()
    if self:isRunning() then
        self:stop()
    else
        self:start()
    end
end
```

Key observations from the SSH plugin:
- `category = "none"` is correct for a simple toggle with no parameters.
- `general = true` makes it available in both file browser and reader contexts.
- The `onToggleSSHServer()` method checks running state and toggles accordingly.
- The same `onToggleSSHServer()` method is also called from the menu callback, providing a single code path for both menu and dispatcher-triggered toggles.

## Recommended Approach for FileSync

### 1. Registration

Add to `main.lua`:

```lua
local Dispatcher = require("dispatcher")

function FileSync:onDispatcherRegisterActions()
    Dispatcher:registerAction("toggle_filesync_server", {
        category = "none",
        event = "ToggleFileSyncServer",
        title = _("Toggle FileSync server"),
        general = true,
    })
end
```

### 2. Update init()

```lua
function FileSync:init()
    self:onDispatcherRegisterActions()
    self.ui.menu:registerToMainMenu(self)
end
```

### 3. Add Event Handler

```lua
function FileSync:onToggleFileSyncServer()
    local FileSyncManager = require("filesync/filesyncmanager")
    if FileSyncManager:isRunning() then
        FileSyncManager:stop()
    else
        FileSyncManager:checkBatteryAndStart()
    end
end
```

### 4. Reuse in Menu Callback

The existing menu callback in `addToMainMenu` can call the same handler:

```lua
callback = function()
    self:onToggleFileSyncServer()
end,
```

### Design Decisions

- **Action name:** `"toggle_filesync_server"` -- follows the `toggle_ssh_server` convention.
- **Event name:** `"ToggleFileSyncServer"` -- PascalCase, maps to `onToggleFileSyncServer()`.
- **Section:** `general=true` -- the server is useful in any context (file manager or reader).
- **Category:** `"none"` -- no parameters needed for a simple toggle.
- **Battery check:** Use `checkBatteryAndStart()` (not bare `start()`) to preserve the low-battery warning behavior. Note: this shows a ConfirmBox which works fine from dispatcher since the UI is interactive.
- **No `condition` field needed** -- the action should always be visible. WiFi state is checked at runtime when the user actually triggers it.

### What This Enables for Users

Once registered, the FileSync toggle will appear in:
- **Gesture settings** -- users can assign a swipe/tap/hold gesture to toggle the server.
- **Profiles** -- users can include it in custom profiles (e.g., a "Transfer Mode" profile that enables WiFi + starts FileSync).
- **Quick Menu** -- if a user creates a quick menu profile that includes the action.

The action appears under the **"General"** section in all of these configuration UIs.

## Key Files / References

| Resource | Description |
|---|---|
| `frontend/dispatcher.lua` ([GitHub](https://github.com/koreader/koreader/blob/master/frontend/dispatcher.lua)) | Dispatcher core: `registerAction()`, `execute()`, `settingsList`, `section_list`, `dispatcher_menu_order` |
| `plugins/SSH.koplugin/main.lua` ([GitHub](https://github.com/koreader/koreader/blob/master/plugins/SSH.koplugin/main.lua)) | Best reference: server toggle pattern identical to FileSync's needs |
| `plugins/hello.koplugin/main.lua` ([GitHub](https://github.com/koreader/koreader/blob/master/plugins/hello.koplugin/main.lua)) | Official minimal example from KOReader |
| `plugins/calibre.koplugin/main.lua` ([GitHub](https://github.com/koreader/koreader/blob/master/plugins/calibre.koplugin/main.lua)) | Multi-action registration example with `arg` fields and `separator` |
| `plugins/statistics.koplugin/main.lua` ([GitHub](https://github.com/koreader/koreader/blob/master/plugins/statistics.koplugin/main.lua)) | Advanced example: toggle with enable/disable (category="string") + simple toggle (category="none") |
| `plugins/wallabag.koplugin/main.lua` ([GitHub](https://github.com/koreader/koreader/blob/master/plugins/wallabag.koplugin/main.lua)) | Multiple category="none" actions for network sync operations |

### All Plugins with Dispatcher Registration (from GitHub code search)

autosuspend (no dispatcher), autoturn (no dispatcher), SSH, hello, calibre, statistics, wallabag, OPDS, cloudstorage, bookshortcuts, movetoarchive, batterystat, systemstat, exporter, readtimer, terminal, kosync, texteditor, profiles, autowarmth, vocabbuilder, readerstyletweak.
