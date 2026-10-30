--- Detection of removable storage (SD cards) for the FileSync plugin.
---
--- The server is rooted at the device's internal storage (see
--- FileSyncManager:getDefaultRootDir). Some readers also take an SD card, which
--- is mounted elsewhere; this module finds it so it can be offered as a second
--- storage location, reached under "/@sd".
---
--- Mount points are hard-coded per platform, the same way the internal roots
--- are. A directory only counts as a card when something is actually mounted
--- there: the mount point exists on devices without a card too, so its
--- filesystem id (`dev`) must differ from both its parent's and the internal
--- storage's.
---
--- Platforms handled, and where each path comes from:
---   kobo        /mnt/sd    confirmed on a Kobo with a card
---   pocketbook  /mnt/ext2  mount output of an InkPad (internal storage is
---                          /mnt/ext1); not tested by the plugin author
--- Everything else (Kindle, Android, reMarkable, Cervantes, desktop...) reports
--- no card, so those devices behave exactly as before. Supporting another
--- platform means adding one line to SD_CARD_PATHS.

local DeviceInfo = require("filesync/deviceinfo")

local Storage = {}

--- Where each platform mounts its SD card (platform names as in DeviceInfo.platform).
Storage.SD_CARD_PATHS = {
    kobo = "/mnt/sd",
    pocketbook = "/mnt/ext2",
}

-- LuaFileSystem, the way the other modules load it.
local function loadLfs()
    local ok, lfs = pcall(require, "lfs")
    if not ok then lfs = require("libs/libkoreader-lfs") end
    return lfs
end

-- Whether `path` is a mount point of its own: a directory whose filesystem id
-- differs from its parent's.
local function isMountPoint(lfs, path)
    local attr = lfs.attributes(path)
    if not attr or attr.mode ~= "directory" or attr.dev == nil then
        return false, nil
    end
    local parent = lfs.attributes(path .. "/..")
    if not parent or parent.dev == nil or parent.dev == attr.dev then
        return false, nil
    end
    return true, attr.dev
end

--- Path of the SD card if one is inserted right now.
--- @param Device table: KOReader's Device object
--- @param internal_root string: root of the internal storage
--- @param lfs table|nil: LuaFileSystem (attributes() is used); loaded here when omitted
--- @return string|nil: the mount point, or nil when there is no card
function Storage.sdCardPath(Device, internal_root, lfs)
    local path = Storage.SD_CARD_PATHS[DeviceInfo.platform(Device)]
    if not path then return nil end
    lfs = lfs or loadLfs()

    local mounted, dev = isMountPoint(lfs, path)
    if not mounted then return nil end

    -- A mount of the very same filesystem as the internal storage is not a card.
    local internal = internal_root and lfs.attributes(internal_root)
    if internal and internal.dev ~= nil and internal.dev == dev then
        return nil
    end
    return path
end

--- Extra storage locations of this device, in the shape FileOps expects.
--- On a platform that takes a card, the card is always listed: with its
--- `path` when it is inserted, without one when it is not, so that "/@sd"
--- stays reserved for it and never falls back to the internal storage.
--- @param lfs table|nil: LuaFileSystem; loaded here when omitted
--- @return table: list of {id = "sd", name = "SD card", path = string|nil},
---   empty on platforms without a card slot
function Storage.extraRoots(Device, internal_root, lfs)
    if not Storage.SD_CARD_PATHS[DeviceInfo.platform(Device)] then
        return {}
    end
    return {{id = "sd", name = "SD card", path = Storage.sdCardPath(Device, internal_root, lfs)}}
end

return Storage
