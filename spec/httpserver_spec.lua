-- Stub heavy KOReader dependencies that httpserver.lua requires at load time
package.loaded["socket"] = {
    bind = function() return nil, "stub" end,
}
package.loaded["ui/uimanager"] = {
    scheduleIn = function() end,
    show = function() end,
}

local HttpServer = require("filesync/httpserver")

-- Create a fresh instance for testing so we don't pollute the module table
local function new_server()
    return HttpServer:new()
end

describe("filesync.httpserver", function()

    describe("_urlDecode", function()
        local server

        before_each(function()
            server = new_server()
        end)

        it("decodes a plain string unchanged", function()
            assert.are.equal("hello", server:_urlDecode("hello"))
        end)

        it("decodes plus as space", function()
            assert.are.equal("hello world", server:_urlDecode("hello+world"))
        end)

        it("decodes percent-encoded characters", function()
            assert.are.equal("hello world", server:_urlDecode("hello%20world"))
        end)

        it("decodes slash encoding", function()
            assert.are.equal("/path/to/file", server:_urlDecode("%2Fpath%2Fto%2Ffile"))
        end)

        it("decodes special characters", function()
            assert.are.equal("a&b=c", server:_urlDecode("a%26b%3Dc"))
        end)

        it("handles mixed encoding", function()
            assert.are.equal("hello world & goodbye", server:_urlDecode("hello+world+%26+goodbye"))
        end)

        it("handles empty string", function()
            assert.are.equal("", server:_urlDecode(""))
        end)

        it("passes through unencoded characters", function()
            assert.are.equal("abc123", server:_urlDecode("abc123"))
        end)

        it("decodes unicode percent sequences", function()
            -- %C3%A9 is UTF-8 for e-acute
            assert.are.equal("\xC3\xA9", server:_urlDecode("%C3%A9"))
        end)
    end)

    describe("_parseQuery", function()
        local server

        before_each(function()
            server = new_server()
        end)

        it("returns empty table for nil", function()
            assert.are.same({}, server:_parseQuery(nil))
        end)

        it("returns empty table for empty string", function()
            assert.are.same({}, server:_parseQuery(""))
        end)

        it("parses a single key-value pair", function()
            local result = server:_parseQuery("key=value")
            assert.are.equal("value", result.key)
        end)

        it("parses multiple key-value pairs", function()
            local result = server:_parseQuery("a=1&b=2&c=3")
            assert.are.equal("1", result.a)
            assert.are.equal("2", result.b)
            assert.are.equal("3", result.c)
        end)

        it("decodes percent-encoded keys and values", function()
            local result = server:_parseQuery("path=%2Fbooks%2Fnovel.epub")
            assert.are.equal("/books/novel.epub", result.path)
        end)

        it("decodes plus signs in values", function()
            local result = server:_parseQuery("filter=my+book")
            assert.are.equal("my book", result.filter)
        end)

        it("handles key with empty value", function()
            local result = server:_parseQuery("key=")
            assert.are.equal("", result.key)
        end)

        it("handles key without equals sign", function()
            local result = server:_parseQuery("flag")
            assert.are.equal("", result.flag)
        end)

        it("parses a realistic files API query", function()
            local result = server:_parseQuery("path=%2F&sort=name&order=asc&filter=")
            assert.are.equal("/", result.path)
            assert.are.equal("name", result.sort)
            assert.are.equal("asc", result.order)
            assert.are.equal("", result.filter)
        end)
    end)

    describe("_extractBoundary", function()
        local server

        before_each(function()
            server = new_server()
        end)

        it("extracts boundary from standard Content-Type", function()
            assert.are.equal("----WebKitFormBoundaryABC123",
                server:_extractBoundary("multipart/form-data; boundary=----WebKitFormBoundaryABC123"))
        end)

        it("extracts boundary without semicolon separator", function()
            assert.are.equal("myboundary",
                server:_extractBoundary("multipart/form-data; boundary=myboundary"))
        end)

        it("returns nil for missing boundary", function()
            assert.is_nil(server:_extractBoundary("multipart/form-data"))
        end)

        it("returns nil for non-multipart content type", function()
            assert.is_nil(server:_extractBoundary("application/json"))
        end)

        it("returns nil for nil input", function()
            assert.is_nil(server:_extractBoundary(nil))
        end)

        it("extracts boundary with extra parameters after it", function()
            assert.are.equal("bound123",
                server:_extractBoundary("multipart/form-data; boundary=bound123; charset=utf-8"))
        end)

        it("handles boundary with hyphens", function()
            assert.are.equal("------WebKitFormBoundaryXYZ",
                server:_extractBoundary("multipart/form-data; boundary=------WebKitFormBoundaryXYZ"))
        end)
    end)

    describe("_extractUploadFilename", function()
        local server

        before_each(function()
            server = new_server()
        end)

        it("extracts a simple filename", function()
            local headers = 'Content-Disposition: form-data; name="files"; filename="book.epub"'
            assert.are.equal("book.epub", server:_extractUploadFilename(headers, nil))
        end)

        it("strips Windows path components", function()
            local headers = 'Content-Disposition: form-data; name="files"; filename="C:\\Users\\test\\book.epub"'
            assert.are.equal("book.epub", server:_extractUploadFilename(headers, nil))
        end)

        it("strips Unix path components", function()
            local headers = 'Content-Disposition: form-data; name="files"; filename="/home/user/documents/book.pdf"'
            assert.are.equal("book.pdf", server:_extractUploadFilename(headers, nil))
        end)

        it("fixes iOS Safari .epub.zip suffix", function()
            local headers = 'Content-Disposition: form-data; name="files"; filename="novel.epub.zip"'
            assert.are.equal("novel.epub", server:_extractUploadFilename(headers, nil))
        end)

        it("fixes iOS Safari .cbz.zip suffix", function()
            local headers = 'Content-Disposition: form-data; name="files"; filename="comic.cbz.zip"'
            assert.are.equal("comic.cbz", server:_extractUploadFilename(headers, nil))
        end)

        it("does not strip .zip from regular zip files", function()
            local headers = 'Content-Disposition: form-data; name="files"; filename="archive.zip"'
            assert.are.equal("archive.zip", server:_extractUploadFilename(headers, nil))
        end)

        it("returns nil for missing filename", function()
            local headers = 'Content-Disposition: form-data; name="files"'
            local result, err = server:_extractUploadFilename(headers, nil)
            assert.is_nil(result)
            assert.is_not_nil(err)
        end)

        it("returns nil for empty filename", function()
            local headers = 'Content-Disposition: form-data; name="files"; filename=""'
            local result, err = server:_extractUploadFilename(headers, nil)
            assert.is_nil(result)
            assert.is_not_nil(err)
        end)

        it("handles filename with spaces", function()
            local headers = 'Content-Disposition: form-data; name="files"; filename="my book (2024).epub"'
            assert.are.equal("my book (2024).epub", server:_extractUploadFilename(headers, nil))
        end)

        it("handles multiline headers", function()
            local headers = 'Content-Disposition: form-data; name="files"; filename="test.pdf"\r\nContent-Type: application/pdf'
            assert.are.equal("test.pdf", server:_extractUploadFilename(headers, nil))
        end)

        it("handles filename with unicode characters", function()
            local headers = 'Content-Disposition: form-data; name="files"; filename="libro-español.epub"'
            assert.are.equal("libro-español.epub", server:_extractUploadFilename(headers, nil))
        end)
    end)
    describe("GET /api/health", function()
        local JSON = require("filesync/json")
        local DeviceInfo = require("filesync/deviceinfo")
        local previous_manager

        before_each(function()
            -- _route asks the manager for safe mode on every API call.
            previous_manager = package.loaded["filesync/filesyncmanager"]
            package.loaded["filesync/filesyncmanager"] = {
                getSafeMode = function() return true end,
            }
        end)

        after_each(function()
            package.loaded["filesync/filesyncmanager"] = previous_manager
        end)

        -- Send a request through the real router and _sendJSON, capture the
        -- raw HTTP response, and return its status line and decoded body.
        local function get_health(server)
            local raw
            server._sendAll = function(_self, _client, data) raw = data end
            server:_route({}, "GET", "/api/health", "", {}, nil)
            assert.is_not_nil(raw)
            local status_line = raw:match("^([^\r\n]+)")
            local body = raw:match("\r\n\r\n(.*)$")
            local decoded = JSON.decode(body)
            assert.is_not_nil(decoded, "health body is not valid JSON: " .. tostring(body))
            return status_line, decoded
        end

        local function kobo_colour()
            local yes = function() return true end
            local no = function() return false end
            return {
                model = "Kobo_monza",
                screen = {
                    -- Rotated to landscape right now; native size is portrait.
                    getWidth = function() return 1680 end,
                    getHeight = function() return 1264 end,
                    getScreenWidth = function() return 1264 end,
                    getScreenHeight = function() return 1680 end,
                    getDPI = function() return 300 end,
                    isColorEnabled = function() return true end,
                },
                isKobo = yes, isKindle = no, isPocketBook = no, isAndroid = no,
                isRemarkable = no, isCervantes = no, isSDL = no,
                hasColorScreen = yes,
            }
        end

        it("keeps the existing fields unchanged and adds the device block", function()
            local server = HttpServer:new{
                root_dir = "/mnt/onboard",
                device_info_provider = DeviceInfo.provider(kobo_colour(), {
                    getCurrentRevision = function() return "v2025.08" end,
                }),
            }
            server._fileops = {}
            local status_line, body = get_health(server)
            assert.are.equal("HTTP/1.1 200 OK", status_line)
            assert.are.same({
                status = "ok",
                root_dir = "/mnt/onboard",
                fileops_loaded = true,
                device = {
                    model = "Kobo_monza",
                    platform = "kobo",
                    screen = { width = 1264, height = 1680, dpi = 300 },
                    color_screen = true,
                    color_enabled = true,
                    koreader_version = "v2025.08",
                },
            }, body)
        end)

        it("answers in safe mode and outside it", function()
            for _, safe in ipairs({ true, false }) do
                package.loaded["filesync/filesyncmanager"] = {
                    getSafeMode = function() return safe end,
                }
                local server = HttpServer:new{
                    root_dir = "/mnt/onboard",
                    device_info_provider = function() return { platform = "kobo" } end,
                }
                local _, body = get_health(server)
                assert.are.same({ platform = "kobo" }, body.device)
            end
        end)

        it("omits the device block when no provider is set", function()
            local server = HttpServer:new{ root_dir = "/mnt/us" }
            local status_line, body = get_health(server)
            assert.are.equal("HTTP/1.1 200 OK", status_line)
            assert.are.same({ status = "ok", root_dir = "/mnt/us", fileops_loaded = false }, body)
        end)

        it("still answers when the provider throws", function()
            local server = HttpServer:new{
                root_dir = "/mnt/us",
                device_info_provider = function() error("device exploded") end,
            }
            server._fileops = {}
            local status_line, body = get_health(server)
            assert.are.equal("HTTP/1.1 200 OK", status_line)
            assert.are.same({ status = "ok", root_dir = "/mnt/us", fileops_loaded = true }, body)
        end)

        it("still answers when every device API throws", function()
            local boom = function() error("boom") end
            local device = setmetatable({ screen = setmetatable({}, { __index = boom }) },
                                        { __index = boom })
            local server = HttpServer:new{
                root_dir = "/mnt/us",
                device_info_provider = DeviceInfo.provider(device, { getCurrentRevision = boom }),
            }
            local status_line, body = get_health(server)
            assert.are.equal("HTTP/1.1 200 OK", status_line)
            assert.are.equal("ok", body.status)
            assert.are.same({ platform = "other" }, body.device)
        end)

        it("ignores a provider that returns something other than a table", function()
            for _, bad in ipairs({ "nope", 42, true }) do
                local server = HttpServer:new{
                    root_dir = "/mnt/us",
                    device_info_provider = function() return bad end,
                }
                local _, body = get_health(server)
                assert.is_nil(body.device)
            end
            -- An empty table would encode as [] and must be left out too.
            local server = HttpServer:new{
                root_dir = "/mnt/us",
                device_info_provider = function() return {} end,
            }
            local _, body = get_health(server)
            assert.is_nil(body.device)
        end)
    end)

    describe("GET / and e-ink mode", function()
        local JSON = require("filesync/json")
        local KOBO_UA = "Mozilla/5.0 (Linux; U; Android 2.0; en-us;) AppleWebKit/538.1 (KHTML, like Gecko) "
            .. "Version/4.0 Mobile Safari/538.1 (Kobo Touch 0390/4.46.23836)"
        local IPHONE_UA = "Mozilla/5.0 (iPhone; CPU iPhone OS 17_5 like Mac OS X) AppleWebKit/605.1.15 "
            .. "(KHTML, like Gecko) Version/17.5 Mobile/15E148 Safari/604.1"
        local previous_manager, previous_settings, settings, listed

        before_each(function()
            previous_manager = package.loaded["filesync/filesyncmanager"]
            package.loaded["filesync/filesyncmanager"] = {
                getSafeMode = function() return true end,
            }
            previous_settings = _G.G_reader_settings
            settings = { language = "en", home_dir = "/mnt/onboard/Books" }
            _G.G_reader_settings = {
                readSetting = function(_, key) return settings[key] end,
            }
            listed = nil
        end)

        after_each(function()
            package.loaded["filesync/filesyncmanager"] = previous_manager
            _G.G_reader_settings = previous_settings
        end)

        -- A server whose FileOps records the listDirectory call and returns
        -- one book in /Books.
        local function new_eink_server()
            local server = HttpServer:new{ root_dir = "/mnt/onboard" }
            server._fileops = {
                listDirectory = function(_, path, sort, order, filter, safe_mode)
                    listed = { path = path, sort = sort, order = order, filter = filter, safe_mode = safe_mode }
                    return {
                        path = path,
                        entries = { { name = "Sample.epub", path = "/Books/Sample.epub", is_dir = false,
                                      size = 1417, size_formatted = "1.4 KB", modified = 0 } },
                        breadcrumbs = { { name = "Home", path = "/" }, { name = "Books", path = "/Books" } },
                    }
                end,
            }
            return server
        end

        -- Route a request and return the raw response, its status line,
        -- its Set-Cookie values and its body.
        local function request(server, path, query, headers)
            local raw
            server._sendAll = function(_self, _client, data) raw = data end
            server:_route({}, "GET", path, query or {}, headers or {}, nil)
            assert.is_not_nil(raw)
            local cookies = {}
            for cookie in raw:match("^(.-)\r\n\r\n"):gmatch("\r\nSet%-Cookie: ([^\r]+)") do
                table.insert(cookies, cookie)
            end
            return raw, raw:match("^([^\r\n]+)"), cookies, raw:match("\r\n\r\n(.*)$")
        end

        local function static_index()
            local f = assert(io.open("filesync/static/index.html", "r"))
            local html = f:read("*all")
            f:close()
            return html
        end

        it("serves phones and desktops exactly the same bytes as before", function()
            local html = static_index()
            local expected = "HTTP/1.1 200 OK\r\n"
                .. "Content-Type: text/html; charset=utf-8\r\n"
                .. "Content-Length: " .. #html .. "\r\n"
                .. "Connection: close\r\n"
                .. "Cache-Control: no-cache\r\n"
                .. "\r\n"
                .. html
            for _, path in ipairs({ "/", "/index.html" }) do
                for _, headers in ipairs({ { ["user-agent"] = IPHONE_UA }, {} }) do
                    local raw = request(new_eink_server(), path, {}, headers)
                    assert.is_true(raw == expected, "response differs for " .. path)
                end
            end
            assert.is_nil(listed)
        end)

        it("serves the e-ink page to a Kobo, starting at the home folder", function()
            local _, status_line, cookies, body = request(new_eink_server(), "/", {}, { ["user-agent"] = KOBO_UA })
            assert.are.equal("HTTP/1.1 200 OK", status_line)
            assert.are.same({}, cookies)
            assert.is_truthy(body:find('href="/api/download?path=/Books/Sample.epub"', 1, true))
            assert.is_nil(body:find("TRANSLATIONS", 1, true)) -- not the main UI's bundle
            assert.are.same({ path = "/Books", sort = "name", order = "asc", filter = "", safe_mode = true }, listed)
        end)

        it("passes the folder, sort and filter to listDirectory", function()
            request(new_eink_server(), "/",
                { path = "/Books/Sub", sort = "date", order = "desc", filter = "tolkien" },
                { ["user-agent"] = KOBO_UA })
            assert.are.same({ path = "/Books/Sub", sort = "date", order = "desc", filter = "tolkien",
                              safe_mode = true }, listed)
        end)

        it("starts at the root when the home folder is outside root_dir", function()
            settings.home_dir = "/somewhere/else"
            request(new_eink_server(), "/", {}, { ["user-agent"] = KOBO_UA })
            assert.are.equal("/", listed.path)
        end)

        it("turns e-ink on for any browser with ?eink=1, and remembers it", function()
            local _, _, cookies, body = request(new_eink_server(), "/", { eink = "1" }, { ["user-agent"] = IPHONE_UA })
            assert.are.same({ "filesync_eink=1; Path=/; Max-Age=31536000" }, cookies)
            assert.is_truthy(body:find("Sample.epub", 1, true))
        end)

        it("gives a Kobo the full page with ?eink=0 and clears the cookie", function()
            local raw, _, cookies = request(new_eink_server(), "/", { eink = "0" },
                { ["user-agent"] = KOBO_UA, cookie = "filesync_eink=1" })
            assert.are.same({ "filesync_eink=; Path=/; Max-Age=0" }, cookies)
            assert.are.equal(static_index(), raw:match("\r\n\r\n(.*)$"))
        end)

        it("remembers the page size and covers choice along with the mode", function()
            local _, _, cookies = request(new_eink_server(), "/", { eink = "1", per_page = "10", covers = "0" }, {})
            assert.are.same({ "filesync_eink=1; Path=/; Max-Age=31536000",
                              "filesync_eink_per_page=10; Path=/; Max-Age=31536000",
                              "filesync_eink_covers=0; Path=/; Max-Age=31536000" }, cookies)
        end)

        it("asks for covers from /api/cover unless they are turned off", function()
            local _, _, _, body = request(new_eink_server(), "/", {}, { ["user-agent"] = KOBO_UA })
            assert.is_truthy(body:find('url("/api/cover?path=/Books/Sample.epub")', 1, true))
            _, _, _, body = request(new_eink_server(), "/", {},
                { ["user-agent"] = KOBO_UA, cookie = "filesync_eink_covers=0" })
            assert.is_nil(body:find("/api/cover", 1, true))
        end)

        it("answers 400 with a page when the folder cannot be listed", function()
            local server = HttpServer:new{ root_dir = "/mnt/onboard" }
            server._fileops = require("filesync/fileops"):new()
            server._fileops:setRootDir("/mnt/onboard")
            local _, status_line, _, body = request(server, "/", { path = "/../etc" }, { ["user-agent"] = KOBO_UA })
            assert.are.equal("HTTP/1.1 400 Bad Request", status_line)
            assert.is_truthy(body:lower():find("traversal", 1, true))
            assert.is_truthy(body:find('<a href="/?path=/">Home</a>', 1, true))
        end)

        it("answers 400 with a page when fileops is not loaded", function()
            local server = HttpServer:new{ root_dir = "/mnt/onboard" }
            local _, status_line, _, body = request(server, "/", {}, { ["user-agent"] = KOBO_UA })
            assert.are.equal("HTTP/1.1 400 Bad Request", status_line)
            assert.is_truthy(body:find("File operations module not loaded", 1, true))
        end)

        it("keeps /api/home answering as before", function()
            local function home(home_dir)
                settings.home_dir = home_dir
                local _, _, _, body = request(new_eink_server(), "/api/home")
                return JSON.decode(body)
            end
            assert.are.same({ home = "/Books" }, home("/mnt/onboard/Books"))
            assert.are.same({ home = "/" }, home("/mnt/onboard"))
            assert.are.same({}, home("/mnt/onboardX"))
            assert.are.same({}, home("/elsewhere"))
            assert.are.same({}, home(nil))
        end)
    end)
end)
