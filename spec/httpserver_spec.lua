-- Stub heavy KOReader dependencies that httpserver.lua requires at load time
-- Controllable clock so _sendAll's idle deadline can be exercised without
-- real waiting; tests advance it via socket_stub.advance().
local socket_stub = {
    bind = function() return nil, "stub" end,
    _now = 0,
}
function socket_stub.gettime() return socket_stub._now end
function socket_stub.advance(seconds) socket_stub._now = socket_stub._now + seconds end
package.loaded["socket"] = socket_stub
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

    --- Regression coverage for issue #53: the Kindle froze on the QR screen
    --- when the hotspot went away mid-upload.  The drain loop that runs after
    --- a failed upload treated receive()'s empty `partial` string as progress
    --- and looped forever, blocking the UI thread with no way out but a hard
    --- reset.  Each test caps the call count so a regression fails loudly
    --- instead of hanging the suite.
    describe("_drainBody", function()
        local server

        before_each(function()
            server = new_server()
        end)

        --- Mock client whose receive() replays `script` and then repeats its
        --- last entry forever, recording how many times it was called.
        local function mock_client(script)
            local client = { calls = 0 }
            function client:receive()
                self.calls = self.calls + 1
                if self.calls > 1000 then error("runaway drain loop") end
                local step = script[math.min(self.calls, #script)]
                return step[1], step[2], step[3]
            end
            return client
        end

        it("stops on a timeout with an empty partial", function()
            -- Peer vanished (hotspot off): (nil, "timeout", "") forever.
            local client = mock_client({ { nil, "timeout", "" } })
            server:_drainBody(client, 4096)
            assert.are.equal(1, client.calls)
        end)

        it("stops on a closed connection with an empty partial", function()
            local client = mock_client({ { nil, "closed", "" } })
            server:_drainBody(client, 4096)
            assert.are.equal(1, client.calls)
        end)

        it("stops when receive returns no partial at all", function()
            local client = mock_client({ { nil, "closed", nil } })
            server:_drainBody(client, 4096)
            assert.are.equal(1, client.calls)
        end)

        it("consumes the expected bytes and stops", function()
            local client = mock_client({
                { string.rep("x", 100) },
                { string.rep("x", 100) },
                { nil, "timeout", "" },
            })
            server:_drainBody(client, 200)
            assert.are.equal(2, client.calls)
        end)

        it("counts a non-empty partial as progress, then stops", function()
            local client = mock_client({
                { nil, "timeout", string.rep("x", 50) },
                { nil, "timeout", "" },
            })
            server:_drainBody(client, 50)
            assert.are.equal(1, client.calls)
        end)

        it("does nothing when there is nothing left to drain", function()
            local client = mock_client({ { nil, "timeout", "" } })
            server:_drainBody(client, 0)
            assert.are.equal(0, client.calls)
        end)

        it("does nothing when more was read than announced", function()
            local client = mock_client({ { nil, "timeout", "" } })
            server:_drainBody(client, -10)
            assert.are.equal(0, client.calls)
        end)
    end)

    --- Regression coverage for issue #54: _sendAll spun forever once a client
    --- went away mid-response, freezing KOReader hard enough to need a reset.
    --- send() reports the last byte written within [i, j], which equals the
    --- current `sent` when nothing goes out, so only a strictly larger index
    --- is progress.  Each test caps the call count so a regression fails
    --- loudly instead of hanging the suite.
    describe("_sendAll", function()
        local server

        before_each(function()
            server = new_server()
            socket_stub._now = 0
        end)

        --- Mock client whose send() replays `script` and then repeats its last
        --- entry forever, recording how many times it was called.  Each entry
        --- is returned verbatim as (bytes, err, partial).
        local function mock_client(script)
            local client = { calls = 0 }
            function client:send()
                self.calls = self.calls + 1
                if self.calls > 1000 then error("runaway send loop") end
                local step = script[math.min(self.calls, #script)]
                return step[1], step[2], step[3]
            end
            return client
        end

        it("returns the byte count when the whole buffer goes out at once", function()
            local client = mock_client({ { 10 } })
            assert.are.equal(10, server:_sendAll(client, string.rep("x", 10)))
            assert.are.equal(1, client.calls)
        end)

        it("resumes after a partial write", function()
            local client = mock_client({ { 4 }, { 10 } })
            assert.are.equal(10, server:_sendAll(client, string.rep("x", 10)))
            assert.are.equal(2, client.calls)
        end)

        it("gives up at once when the peer closed after a partial write", function()
            -- The freeze: partial == sent (4), which the old code read as progress.
            local client = mock_client({ { 4 }, { nil, "closed", 4 } })
            local ok, err = server:_sendAll(client, string.rep("x", 10))
            assert.is_nil(ok)
            assert.are.equal("closed", err)
            assert.are.equal(2, client.calls)
        end)

        it("gives up at once when the network is unreachable", function()
            local client = mock_client({ { 4 }, { nil, "Network is unreachable", 4 } })
            local ok, err = server:_sendAll(client, string.rep("x", 10))
            assert.is_nil(ok)
            assert.are.equal("Network is unreachable", err)
            assert.are.equal(2, client.calls)
        end)

        it("gives up when nothing was sent at all", function()
            local client = mock_client({ { nil, "closed", 0 } })
            local ok, err = server:_sendAll(client, string.rep("x", 10))
            assert.is_nil(ok)
            assert.are.equal("closed", err)
            assert.are.equal(1, client.calls)
        end)

        it("retries a timeout while inside the idle budget", function()
            local client = mock_client({ { 4 }, { nil, "timeout", 4 }, { 10 } })
            assert.are.equal(10, server:_sendAll(client, string.rep("x", 10)))
            assert.are.equal(3, client.calls)
        end)

        it("gives up on a timeout that never makes progress", function()
            local client = mock_client({ { 4 }, { nil, "timeout", 4 } })
            -- Each retry burns CONNECTION_TIMEOUT of wall clock.
            local real_send = client.send
            function client:send(...)
                socket_stub.advance(2)
                return real_send(self, ...)
            end
            local ok, err = server:_sendAll(client, string.rep("x", 10))
            assert.is_nil(ok)
            assert.are.equal("timeout", err)
            -- 15s budget / 2s per retry, not 1000.
            assert.is_true(client.calls < 12)
        end)

        it("extends the idle budget whenever bytes actually move", function()
            -- A slow but live peer: one byte per call, each taking 2s. Without
            -- the extension the 15s budget would cut it off partway.
            local client = { calls = 0, sent = 0 }
            function client:send()
                self.calls = self.calls + 1
                if self.calls > 1000 then error("runaway send loop") end
                socket_stub.advance(2)
                self.sent = self.sent + 1
                if self.sent >= 20 then return 20 end
                return nil, "timeout", self.sent
            end
            assert.are.equal(20, server:_sendAll(client, string.rep("x", 20)))
            assert.are.equal(20, client.calls)
        end)

        it("sends nothing for an empty buffer", function()
            local client = mock_client({ { 0 } })
            assert.are.equal(0, server:_sendAll(client, ""))
            assert.are.equal(0, client.calls)
        end)
    end)
end)
