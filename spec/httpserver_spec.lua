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
end)
