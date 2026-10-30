local Storage = require("filesync/storage")

describe("filesync.storage", function()

    local function device(platform)
        local d = {}
        for _, name in ipairs({"isKobo", "isKindle", "isPocketBook", "isAndroid",
                               "isRemarkable", "isCervantes", "isSDL"}) do
            d[name] = function() return false end
        end
        if platform then d["is" .. platform] = function() return true end end
        return d
    end

    -- Fake lfs: every path maps to {mode, dev}; "<path>/.." resolves to the parent.
    local function fake_lfs(tree)
        return {
            attributes = function(path)
                local parent = path:match("^(.*)/%.%.$")
                if parent then
                    parent = parent:match("^(.*)/[^/]+$")
                    if parent == "" then parent = "/" end
                    return tree[parent]
                end
                return tree[path]
            end,
        }
    end

    local ROOT_FS = {mode = "directory", dev = 1}
    local INTERNAL_FS = {mode = "directory", dev = 2}
    local CARD_FS = {mode = "directory", dev = 3}

    it("finds a mounted card on a Kobo", function()
        local lfs = fake_lfs({["/"] = ROOT_FS, ["/mnt"] = ROOT_FS,
            ["/mnt/onboard"] = INTERNAL_FS, ["/mnt/sd"] = CARD_FS})
        assert.are.equal("/mnt/sd", Storage.sdCardPath(device("Kobo"), "/mnt/onboard", lfs))
        assert.are.same({{id = "sd", name = "SD card", path = "/mnt/sd"}},
            Storage.extraRoots(device("Kobo"), "/mnt/onboard", lfs))
    end)

    it("finds a mounted card on a PocketBook", function()
        local lfs = fake_lfs({["/"] = ROOT_FS, ["/mnt"] = ROOT_FS,
            ["/mnt/ext1"] = INTERNAL_FS, ["/mnt/ext2"] = CARD_FS})
        assert.are.equal("/mnt/ext2", Storage.sdCardPath(device("PocketBook"), "/mnt/ext1", lfs))
    end)

    it("reports no card when the mount point is an empty directory", function()
        local lfs = fake_lfs({["/"] = ROOT_FS, ["/mnt"] = ROOT_FS,
            ["/mnt/onboard"] = INTERNAL_FS, ["/mnt/sd"] = ROOT_FS})
        assert.is_nil(Storage.sdCardPath(device("Kobo"), "/mnt/onboard", lfs))
        -- The card stays listed without a path, so "/@sd" remains reserved.
        assert.are.same({{id = "sd", name = "SD card"}},
            Storage.extraRoots(device("Kobo"), "/mnt/onboard", lfs))
    end)

    it("reports no card when the mount point does not exist", function()
        local lfs = fake_lfs({["/"] = ROOT_FS, ["/mnt"] = ROOT_FS, ["/mnt/onboard"] = INTERNAL_FS})
        assert.is_nil(Storage.sdCardPath(device("Kobo"), "/mnt/onboard", lfs))
    end)

    it("does not take the internal filesystem for a card", function()
        local lfs = fake_lfs({["/"] = ROOT_FS, ["/mnt"] = ROOT_FS,
            ["/mnt/onboard"] = INTERNAL_FS, ["/mnt/sd"] = INTERNAL_FS})
        assert.is_nil(Storage.sdCardPath(device("Kobo"), "/mnt/onboard", lfs))
    end)

    it("ignores a mount point that is a file", function()
        local lfs = fake_lfs({["/"] = ROOT_FS, ["/mnt"] = ROOT_FS,
            ["/mnt/onboard"] = INTERNAL_FS, ["/mnt/sd"] = {mode = "file", dev = 3}})
        assert.is_nil(Storage.sdCardPath(device("Kobo"), "/mnt/onboard", lfs))
    end)

    it("reports no card where no path is known", function()
        local lfs = fake_lfs({["/"] = ROOT_FS, ["/mnt"] = ROOT_FS, ["/mnt/sd"] = CARD_FS,
            ["/mnt/ext2"] = CARD_FS, ["/mnt/us"] = INTERNAL_FS})
        for _, platform in ipairs({"Kindle", "Android", "Remarkable", "Cervantes", "SDL"}) do
            assert.is_nil(Storage.sdCardPath(device(platform), "/mnt/us", lfs))
        end
        assert.is_nil(Storage.sdCardPath(device(nil), "/mnt/us", lfs))
        assert.are.same({}, Storage.extraRoots(device("Kindle"), "/mnt/us", lfs))
    end)

    it("copes with attributes that lack a filesystem id", function()
        local lfs = fake_lfs({["/"] = {mode = "directory"}, ["/mnt"] = {mode = "directory"},
            ["/mnt/onboard"] = {mode = "directory"}, ["/mnt/sd"] = {mode = "directory"}})
        assert.is_nil(Storage.sdCardPath(device("Kobo"), "/mnt/onboard", lfs))
    end)
end)
