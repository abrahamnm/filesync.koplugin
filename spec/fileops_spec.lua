-- Stub lfs before requiring fileops, since fileops tries to load it at require-time.
-- Most of the helpers we test are pure logic and never touch it; listDirectory does,
-- so the stub is programmable via mountTree() below. fileops keeps a reference to
-- this exact table, so replacing its fields in place is enough to steer it.
local lfs_stub = {
    attributes = function() return nil end,
    dir = function() return function() return nil end end,
    mkdir = function() return nil, "not mounted" end,
}
package.loaded["lfs"] = lfs_stub

--- Point the lfs stub at a virtual filesystem.
--- @param tree table: map of absolute path -> {mode = "directory"|"file", size, modification}
local function mountTree(tree)
    lfs_stub.attributes = function(path)
        return tree[path]
    end
    lfs_stub.dir = function(path)
        local names = {".", ".."}
        local prefix = path .. "/"
        for entry_path, _ in pairs(tree) do
            local name = entry_path:sub(#prefix + 1)
            -- Direct children only: starts with the prefix, no further slash
            if entry_path:sub(1, #prefix) == prefix and name ~= "" and not name:find("/") then
                table.insert(names, name)
            end
        end
        table.sort(names)
        local i = 0
        return function()
            i = i + 1
            return names[i]
        end
    end
end

--- Restore the inert default stub so unrelated tests are unaffected.
local function unmountTree()
    lfs_stub.attributes = function() return nil end
    lfs_stub.dir = function() return function() return nil end end
    lfs_stub.mkdir = function() return nil, "not mounted" end
end

--- Make lfs.mkdir write into a mounted tree, recording the creation order.
--- Mirrors the real thing: it fails when the parent does not exist.
--- @param tree table: the same table passed to mountTree()
--- @return table: list of created paths, in creation order
local function recordMkdir(tree)
    local created = {}
    lfs_stub.mkdir = function(path)
        local parent = path:match("(.+)/[^/]+$")
        if parent and not tree[parent] then
            return nil, "No such file or directory"
        end
        tree[path] = {mode = "directory"}
        table.insert(created, path)
        return true
    end
    return created
end

--- Collect entry names from a listDirectory result into a lookup table.
local function nameSet(result)
    local set = {}
    for _, entry in ipairs(result.entries) do
        set[entry.name] = true
    end
    return set
end

local FileOps = require("filesync/fileops")

describe("filesync.fileops", function()

    describe("_resolvePath", function()

        before_each(function()
            FileOps:setRootDir("/mnt/us")
        end)

        it("resolves a simple relative path", function()
            local path, err = FileOps:_resolvePath("/books")
            assert.is_nil(err)
            assert.are.equal("/mnt/us/books", path)
        end)

        it("resolves root path", function()
            local path, err = FileOps:_resolvePath("/")
            assert.is_nil(err)
            assert.are.equal("/mnt/us", path)
        end)

        it("resolves nil as root", function()
            local path, err = FileOps:_resolvePath(nil)
            assert.is_nil(err)
            assert.are.equal("/mnt/us", path)
        end)

        it("resolves empty string as root", function()
            local path, err = FileOps:_resolvePath("")
            assert.is_nil(err)
            assert.are.equal("/mnt/us", path)
        end)

        it("blocks path traversal with ..", function()
            local path, err = FileOps:_resolvePath("/../etc/passwd")
            assert.is_nil(path)
            assert.is_truthy(err:find("traversal"))
        end)

        it("blocks path traversal with embedded ..", function()
            local path, err = FileOps:_resolvePath("/books/../../../etc")
            assert.is_nil(path)
            assert.is_truthy(err:find("traversal"))
        end)

        it("normalizes double slashes", function()
            local path, err = FileOps:_resolvePath("//books///test//")
            assert.is_nil(err)
            assert.are.equal("/mnt/us/books/test", path)
        end)

        it("strips leading and trailing whitespace", function()
            local path, err = FileOps:_resolvePath("  /books  ")
            assert.is_nil(err)
            assert.are.equal("/mnt/us/books", path)
        end)

        it("prepends slash if missing", function()
            local path, err = FileOps:_resolvePath("books/fiction")
            assert.is_nil(err)
            assert.are.equal("/mnt/us/books/fiction", path)
        end)

        it("removes trailing slash except for root", function()
            local path, err = FileOps:_resolvePath("/books/")
            assert.is_nil(err)
            assert.are.equal("/mnt/us/books", path)
        end)

        it("works with a different root_dir", function()
            FileOps:setRootDir("/home/user")
            local path, err = FileOps:_resolvePath("/documents")
            assert.is_nil(err)
            assert.are.equal("/home/user/documents", path)
        end)
    end)

    describe("_validateFilename", function()

        it("accepts a normal filename", function()
            local ok, err = FileOps:_validateFilename("book.epub")
            assert.is_true(ok)
            assert.is_nil(err)
        end)

        it("accepts a filename with spaces", function()
            local ok, err = FileOps:_validateFilename("my book.epub")
            assert.is_true(ok)
            assert.is_nil(err)
        end)

        it("accepts a filename with dots", function()
            local ok, err = FileOps:_validateFilename("archive.fb2.zip")
            assert.is_true(ok)
            assert.is_nil(err)
        end)

        it("rejects nil filename", function()
            local ok, err = FileOps:_validateFilename(nil)
            assert.is_false(ok)
            assert.is_truthy(err:find("Empty"))
        end)

        it("rejects empty string", function()
            local ok, err = FileOps:_validateFilename("")
            assert.is_false(ok)
            assert.is_truthy(err:find("Empty"))
        end)

        it("rejects filename with forward slash", function()
            local ok, err = FileOps:_validateFilename("path/file.txt")
            assert.is_false(ok)
            assert.is_truthy(err:find("Invalid characters"))
        end)

        it("rejects filename with null byte", function()
            local ok, err = FileOps:_validateFilename("file\0name")
            assert.is_false(ok)
            assert.is_truthy(err:find("Invalid characters"))
        end)

        it("rejects single dot", function()
            local ok, err = FileOps:_validateFilename(".")
            assert.is_false(ok)
            assert.is_truthy(err:find("Invalid filename"))
        end)

        it("rejects double dot", function()
            local ok, err = FileOps:_validateFilename("..")
            assert.is_false(ok)
            assert.is_truthy(err:find("Invalid filename"))
        end)

        it("rejects filename longer than 255 characters", function()
            local long_name = string.rep("a", 256)
            local ok, err = FileOps:_validateFilename(long_name)
            assert.is_false(ok)
            assert.is_truthy(err:find("too long"))
        end)

        it("accepts filename of exactly 255 characters", function()
            local name = string.rep("a", 255)
            local ok, err = FileOps:_validateFilename(name)
            assert.is_true(ok)
            assert.is_nil(err)
        end)
    end)

    describe("_formatSize", function()

        it("formats bytes", function()
            assert.are.equal("0 B", FileOps:_formatSize(0))
            assert.are.equal("512 B", FileOps:_formatSize(512))
            assert.are.equal("1023 B", FileOps:_formatSize(1023))
        end)

        it("formats kilobytes", function()
            assert.are.equal("1.0 KB", FileOps:_formatSize(1024))
            assert.are.equal("1.5 KB", FileOps:_formatSize(1536))
            assert.are.equal("10.0 KB", FileOps:_formatSize(10240))
        end)

        it("formats megabytes", function()
            assert.are.equal("1.0 MB", FileOps:_formatSize(1024 * 1024))
            assert.are.equal("5.0 MB", FileOps:_formatSize(5 * 1024 * 1024))
        end)

        it("formats gigabytes", function()
            assert.are.equal("1.0 GB", FileOps:_formatSize(1024 * 1024 * 1024))
            assert.are.equal("2.5 GB", FileOps:_formatSize(2.5 * 1024 * 1024 * 1024))
        end)
    end)

    describe("_getMimeType", function()

        it("returns correct MIME for epub", function()
            assert.are.equal("application/epub+zip", FileOps:_getMimeType("book.epub"))
        end)

        it("returns correct MIME for pdf", function()
            assert.are.equal("application/pdf", FileOps:_getMimeType("doc.pdf"))
        end)

        it("returns correct MIME for mobi", function()
            assert.are.equal("application/x-mobipocket-ebook", FileOps:_getMimeType("book.mobi"))
        end)

        it("returns correct MIME for txt", function()
            assert.are.equal("text/plain", FileOps:_getMimeType("readme.txt"))
        end)

        it("returns correct MIME for html", function()
            assert.are.equal("text/html", FileOps:_getMimeType("page.html"))
        end)

        it("returns correct MIME for htm", function()
            assert.are.equal("text/html", FileOps:_getMimeType("page.htm"))
        end)

        it("returns correct MIME for json", function()
            assert.are.equal("application/json", FileOps:_getMimeType("data.json"))
        end)

        it("returns correct MIME for png", function()
            assert.are.equal("image/png", FileOps:_getMimeType("image.png"))
        end)

        it("returns correct MIME for jpg", function()
            assert.are.equal("image/jpeg", FileOps:_getMimeType("photo.jpg"))
        end)

        it("returns correct MIME for jpeg", function()
            assert.are.equal("image/jpeg", FileOps:_getMimeType("photo.jpeg"))
        end)

        it("returns correct MIME for gif", function()
            assert.are.equal("image/gif", FileOps:_getMimeType("anim.gif"))
        end)

        it("returns correct MIME for svg", function()
            assert.are.equal("image/svg+xml", FileOps:_getMimeType("icon.svg"))
        end)

        it("returns correct MIME for zip", function()
            assert.are.equal("application/zip", FileOps:_getMimeType("archive.zip"))
        end)

        it("returns octet-stream for unknown extension", function()
            assert.are.equal("application/octet-stream", FileOps:_getMimeType("data.xyz"))
        end)

        it("returns octet-stream for no extension", function()
            assert.are.equal("application/octet-stream", FileOps:_getMimeType("Makefile"))
        end)
    end)

    describe("_getFileType", function()

        it("classifies epub as ebook", function()
            assert.are.equal("ebook", FileOps:_getFileType("book.epub"))
        end)

        it("classifies pdf as ebook", function()
            assert.are.equal("ebook", FileOps:_getFileType("doc.pdf"))
        end)

        it("classifies mobi as ebook", function()
            assert.are.equal("ebook", FileOps:_getFileType("book.mobi"))
        end)

        it("classifies azw3 as ebook", function()
            assert.are.equal("ebook", FileOps:_getFileType("book.azw3"))
        end)

        it("classifies cbz as ebook", function()
            assert.are.equal("ebook", FileOps:_getFileType("comic.cbz"))
        end)

        it("classifies txt as document", function()
            assert.are.equal("document", FileOps:_getFileType("readme.txt"))
        end)

        it("classifies html as document", function()
            assert.are.equal("document", FileOps:_getFileType("page.html"))
        end)

        it("classifies md as document", function()
            assert.are.equal("document", FileOps:_getFileType("notes.md"))
        end)

        it("classifies png as image", function()
            assert.are.equal("image", FileOps:_getFileType("photo.png"))
        end)

        it("classifies jpg as image", function()
            assert.are.equal("image", FileOps:_getFileType("photo.jpg"))
        end)

        it("classifies webp as image", function()
            assert.are.equal("image", FileOps:_getFileType("photo.webp"))
        end)

        it("classifies unknown extensions as file", function()
            assert.are.equal("file", FileOps:_getFileType("data.xyz"))
        end)

        it("classifies extensionless files as file", function()
            assert.are.equal("file", FileOps:_getFileType("Makefile"))
        end)
    end)

    describe("isExtensionSafe", function()

        it("returns true for epub", function()
            assert.is_true(FileOps:isExtensionSafe("book.epub"))
        end)

        it("returns true for pdf", function()
            assert.is_true(FileOps:isExtensionSafe("doc.pdf"))
        end)

        it("returns true for mobi", function()
            assert.is_true(FileOps:isExtensionSafe("book.mobi"))
        end)

        it("returns true for txt", function()
            assert.is_true(FileOps:isExtensionSafe("notes.txt"))
        end)

        it("returns true for jpg", function()
            assert.is_true(FileOps:isExtensionSafe("photo.jpg"))
        end)

        it("returns true for png", function()
            assert.is_true(FileOps:isExtensionSafe("image.png"))
        end)

        it("returns true for compound extension fb2.zip", function()
            assert.is_true(FileOps:isExtensionSafe("book.fb2.zip"))
        end)

        it("is case insensitive", function()
            assert.is_true(FileOps:isExtensionSafe("BOOK.EPUB"))
            assert.is_true(FileOps:isExtensionSafe("Photo.JPG"))
        end)

        it("returns false for unsafe extensions", function()
            assert.is_false(FileOps:isExtensionSafe("script.sh"))
            assert.is_false(FileOps:isExtensionSafe("program.exe"))
            assert.is_false(FileOps:isExtensionSafe("archive.tar.gz"))
        end)

        it("returns false for files without extension", function()
            assert.is_false(FileOps:isExtensionSafe("Makefile"))
        end)

        it("returns false for nil", function()
            assert.is_false(FileOps:isExtensionSafe(nil))
        end)
    end)
    describe("listDirectory hidden entries", function()

        -- A root holding every interesting category: hidden dir, hidden dotfile
        -- with a non-whitelisted name, hidden dotfile that *is* whitelisted,
        -- a sidecar .sdr directory, and ordinary safe/unsafe files.
        local TREE = {
            ["/mnt/us"]              = {mode = "directory", size = 4096, modification = 100},
            ["/mnt/us/.config"]      = {mode = "directory", size = 4096, modification = 100},
            ["/mnt/us/.gitignore"]   = {mode = "file",      size = 12,   modification = 100},
            ["/mnt/us/.hidden.epub"] = {mode = "file",      size = 34,   modification = 100},
            ["/mnt/us/Books"]        = {mode = "directory", size = 4096, modification = 100},
            ["/mnt/us/book.epub"]    = {mode = "file",      size = 56,   modification = 100},
            ["/mnt/us/book.sdr"]     = {mode = "directory", size = 4096, modification = 100},
            ["/mnt/us/notes.txt"]    = {mode = "file",      size = 78,   modification = 100},
            ["/mnt/us/script.sh"]    = {mode = "file",      size = 90,   modification = 100},
        }

        before_each(function()
            FileOps:setRootDir("/mnt/us")
            mountTree(TREE)
        end)

        after_each(function()
            unmountTree()
        end)

        it("hides dotfiles and dot-directories in safe mode", function()
            local result = FileOps:listDirectory("/", "name", "asc", "", true)
            local names = nameSet(result)
            assert.is_nil(names[".config"])
            assert.is_nil(names[".gitignore"])
        end)

        it("hides dotfiles in safe mode even with a whitelisted extension", function()
            local result = FileOps:listDirectory("/", "name", "asc", "", true)
            assert.is_nil(nameSet(result)[".hidden.epub"])
        end)

        it("lists dotfiles and dot-directories when safe mode is off", function()
            local result = FileOps:listDirectory("/", "name", "asc", "", false)
            local names = nameSet(result)
            assert.is_true(names[".config"])
            assert.is_true(names[".gitignore"])
            assert.is_true(names[".hidden.epub"])
        end)

        it("still applies the extension whitelist in safe mode", function()
            local result = FileOps:listDirectory("/", "name", "asc", "", true)
            local names = nameSet(result)
            assert.is_true(names["book.epub"])
            assert.is_true(names["notes.txt"])
            assert.is_nil(names["script.sh"])
        end)

        it("still hides .sdr directories in safe mode", function()
            local result = FileOps:listDirectory("/", "name", "asc", "", true)
            assert.is_nil(nameSet(result)["book.sdr"])
        end)

        it("lists .sdr directories and every extension when safe mode is off", function()
            local result = FileOps:listDirectory("/", "name", "asc", "", false)
            local names = nameSet(result)
            assert.is_true(names["book.sdr"])
            assert.is_true(names["script.sh"])
        end)

        it("keeps the name filter applied to hidden entries", function()
            local result = FileOps:listDirectory("/", "name", "asc", "git", false)
            local names = nameSet(result)
            assert.is_true(names[".gitignore"])
            assert.is_nil(names["book.epub"])
        end)

        it("reports a count matching the visible entries", function()
            local safe = FileOps:listDirectory("/", "name", "asc", "", true)
            local unsafe = FileOps:listDirectory("/", "name", "asc", "", false)
            assert.are.equal(3, safe.count)
            assert.are.equal(8, unsafe.count)
        end)
    end)

    describe("_looksLikeText", function()
        it("treats ASCII and UTF-8 content as text", function()
            assert.is_true(FileOps:_looksLikeText("hello world\nsecond line\n"))
            assert.is_true(FileOps:_looksLikeText("caf\xc3\xa9 \xe2\x9c\x93 utf8")) -- café ✓
        end)

        it("treats a NUL byte as binary", function()
            assert.is_false(FileOps:_looksLikeText("abc\0def"))
            assert.is_false(FileOps:_looksLikeText("\0\0\0"))
        end)

        it("only samples the requested number of leading bytes", function()
            -- NUL appears after the sample window -> still text
            assert.is_true(FileOps:_looksLikeText("12345\0rest", 5))
            -- NUL inside the sample window -> binary
            assert.is_false(FileOps:_looksLikeText("12345\0rest", 10))
        end)

        it("treats empty and nil content as text", function()
            assert.is_true(FileOps:_looksLikeText(""))
            assert.is_true(FileOps:_looksLikeText(nil))
        end)
    end)

    describe("readTextFile", function()

        before_each(function()
            FileOps:setRootDir("/mnt/us")
            mountTree({
                ["/mnt/us"] = {mode = "directory"},
                ["/mnt/us/notes.txt"] = {mode = "file", size = 10},
                ["/mnt/us/huge.log"] = {mode = "file", size = 1024 * 1024},
                ["/mnt/us/subdir"] = {mode = "directory"},
            })
        end)

        after_each(function()
            unmountTree()
        end)

        it("rejects path traversal", function()
            local result, err = FileOps:readTextFile("/../etc/passwd")
            assert.is_nil(result)
            assert.is_truthy(err:find("traversal"))
        end)

        it("returns 'Not a file' for a directory", function()
            local result, err = FileOps:readTextFile("/subdir")
            assert.is_nil(result)
            assert.are.equal("Not a file", err)
        end)

        it("returns 'Not a file' for a missing path", function()
            local result, err = FileOps:readTextFile("/missing.txt")
            assert.is_nil(result)
            assert.are.equal("Not a file", err)
        end)

        it("refuses files over the size cap", function()
            -- MAX_EDIT_SIZE is 256 KB; huge.log is 1 MB.
            local result, err = FileOps:readTextFile("/huge.log")
            assert.is_nil(result)
            assert.are.equal("File is too large to edit", err)
        end)
    end)

    describe("writeTextFile", function()

        before_each(function()
            FileOps:setRootDir("/mnt/us")
            mountTree({
                ["/mnt/us"] = {mode = "directory"},
                ["/mnt/us/notes.txt"] = {mode = "file", size = 10},
                ["/mnt/us/subdir"] = {mode = "directory"},
            })
        end)

        after_each(function()
            unmountTree()
        end)

        it("rejects nil content", function()
            local ok, err = FileOps:writeTextFile("/notes.txt", nil)
            assert.is_false(ok)
            assert.are.equal("Invalid content", err)
        end)

        it("rejects non-string content", function()
            local ok, err = FileOps:writeTextFile("/notes.txt", 12345)
            assert.is_false(ok)
            assert.are.equal("Invalid content", err)
        end)

        it("rejects a missing target file", function()
            local ok, err = FileOps:writeTextFile("/missing.txt", "data")
            assert.is_false(ok)
            assert.are.equal("Not a file", err)
        end)

        it("rejects a directory target", function()
            local ok, err = FileOps:writeTextFile("/subdir", "data")
            assert.is_false(ok)
            assert.are.equal("Not a file", err)
        end)

        it("rejects path traversal", function()
            local ok, err = FileOps:writeTextFile("/../etc/passwd", "data")
            assert.is_false(ok)
            assert.is_truthy(err:find("traversal"))
        end)
    end)

    describe("createDirectory", function()

        local tree, created

        before_each(function()
            FileOps:setRootDir("/mnt/us")
            tree = {
                ["/mnt/us"] = {mode = "directory"},
                ["/mnt/us/books"] = {mode = "directory"},
                ["/mnt/us/notes.txt"] = {mode = "file", size = 10},
            }
            mountTree(tree)
            created = recordMkdir(tree)
        end)

        after_each(function()
            unmountTree()
        end)

        it("creates a single directory under an existing parent", function()
            assert.is_true(FileOps:createDirectory("/books/scifi"))
            assert.are.same({"/mnt/us/books/scifi"}, created)
        end)

        it("refuses a missing parent when not recursive", function()
            local ok, err = FileOps:createDirectory("/plugins/deep/leaf")
            assert.is_false(ok)
            assert.are.equal("Parent directory does not exist", err)
            assert.are.same({}, created)
        end)

        it("creates every missing parent when recursive", function()
            assert.is_true(FileOps:createDirectory("/plugins/deep/leaf", {recursive = true}))
            assert.are.same({
                "/mnt/us/plugins",
                "/mnt/us/plugins/deep",
                "/mnt/us/plugins/deep/leaf",
            }, created)
        end)

        it("skips parents that already exist when recursive", function()
            assert.is_true(FileOps:createDirectory("/books/scifi/asimov", {recursive = true}))
            assert.are.same({
                "/mnt/us/books/scifi",
                "/mnt/us/books/scifi/asimov",
            }, created)
        end)

        it("treats an existing directory as success when recursive", function()
            assert.is_true(FileOps:createDirectory("/books", {recursive = true}))
            assert.are.same({}, created)
        end)

        it("still reports an existing directory as an error when not recursive", function()
            local ok, err = FileOps:createDirectory("/books")
            assert.is_false(ok)
            assert.are.equal("Path already exists", err)
        end)

        it("refuses to overwrite a file that shadows a parent segment", function()
            local ok, err = FileOps:createDirectory("/notes.txt/inner", {recursive = true})
            assert.is_false(ok)
            assert.are.equal("Path already exists", err)
            assert.are.same({}, created)
        end)

        it("rejects path traversal in a recursive path", function()
            local ok, err = FileOps:createDirectory("/plugins/../../etc", {recursive = true})
            assert.is_false(ok)
            assert.are.equal("Path traversal not allowed", err)
            assert.are.same({}, created)
        end)

        it("refuses to create the root itself", function()
            local ok, err = FileOps:createDirectory("/", {recursive = true})
            assert.is_false(ok)
            assert.are.equal("Path already exists", err)
        end)
    end)
end)
