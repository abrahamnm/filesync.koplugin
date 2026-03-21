local logger = require("logger")
local socket = require("socket")
local UIManager = require("ui/uimanager")

local HttpServer = {
    port = 8080,
    root_dir = "/mnt/us",
    _server_socket = nil,
    _running = false,
    _static_cache = {},
    _fileops = nil,
}

function HttpServer:new(o)
    o = o or {}
    setmetatable(o, self)
    self.__index = self
    return o
end

function HttpServer:start()
    -- Load FileOps eagerly so require failures are caught at startup, not per-request
    local ok, result = pcall(require, "filesync/fileops")
    if not ok then
        -- Try loading relative to this file's directory
        local plugin_dir = self:_getPluginDir()
        ok, result = pcall(dofile, plugin_dir .. "/fileops.lua")
    end
    if not ok then
        error("Could not load fileops module: " .. tostring(result))
    end
    self._fileops = result
    self._fileops:setRootDir(self.root_dir)
    logger.info("FileSync HTTP: fileops module loaded, root_dir =", self.root_dir)

    local server, err = socket.bind("*", self.port)
    if not server then
        error("Could not bind to port " .. self.port .. ": " .. tostring(err))
    end
    server:settimeout(0) -- Non-blocking
    self._server_socket = server
    self._running = true
    logger.info("FileSync HTTP: Listening on port", self.port)

    -- Schedule polling via UIManager
    self:_schedulePoll()
end

function HttpServer:stop()
    self._running = false
    if self._server_socket then
        self._server_socket:close()
        self._server_socket = nil
    end
    self._static_cache = {}
    logger.info("FileSync HTTP: Server stopped")
end

function HttpServer:_schedulePoll()
    if not self._running then return end
    UIManager:scheduleIn(0.1, function()
        self:_poll()
    end)
end

function HttpServer:_poll()
    if not self._running or not self._server_socket then return end

    -- Process up to 4 pending connections per cycle (browser may open several at once)
    for _ = 1, 4 do
        local client = self._server_socket:accept()
        if not client then break end

        client:settimeout(5)
        local ok, err = pcall(function()
            self:_handleClient(client)
        end)
        if not ok then
            logger.warn("FileSync HTTP: Error handling client:", err)
            -- Use _sendError (HTML) not _sendJSON here — if _sendJSON itself
            -- is the thing that threw, calling it again would also fail silently
            pcall(function()
                self:_sendError(client, 500, tostring(err))
            end)
        end
        pcall(function() client:close() end)
    end

    self:_schedulePoll()
end

function HttpServer:_handleClient(client)
    -- Read the request line
    local request_line, recv_err = client:receive("*l")
    if not request_line then
        logger.warn("FileSync HTTP: receive failed:", recv_err)
        self:_sendError(client, 400, "Bad Request")
        return
    end

    local method, path, _ = request_line:match("^(%S+)%s+(%S+)%s+(%S+)")
    if not method or not path then
        self:_sendError(client, 400, "Bad Request")
        return
    end
    logger.dbg("FileSync HTTP:", method, path)

    -- Read headers
    local headers = {}
    while true do
        local line = client:receive("*l")
        if not line or line == "" then break end
        local key, value = line:match("^([^:]+):%s*(.+)")
        if key then
            headers[key:lower()] = value
        end
    end

    -- Read body if present
    local body = nil
    local content_length = tonumber(headers["content-length"])
    if content_length and content_length > 0 then
        body = self:_readBody(client, content_length)
    end

    -- Split path from query string BEFORE decoding (query params decoded individually)
    local raw_path, query_string = path:match("^([^?]*)%??(.*)")
    if not raw_path then
        raw_path = path
        query_string = ""
    end

    -- URL decode the path portion only
    local path_part = self:_urlDecode(raw_path)

    local query = self:_parseQuery(query_string or "")

    -- Route the request
    self:_route(client, method, path_part, query, headers, body)
end

function HttpServer:_readBody(client, length)
    -- Read body in chunks to avoid memory issues
    local MAX_CHUNK = 65536
    local parts = {}
    local remaining = length
    while remaining > 0 do
        local chunk_size = math.min(remaining, MAX_CHUNK)
        local data, err, partial = client:receive(chunk_size)
        if data then
            table.insert(parts, data)
            remaining = remaining - #data
        elseif partial and #partial > 0 then
            table.insert(parts, partial)
            remaining = remaining - #partial
        else
            break
        end
    end
    return table.concat(parts)
end

function HttpServer:_route(client, method, path, query, headers, body)
    -- Handle CORS preflight
    if method == "OPTIONS" then
        local resp = table.concat({
            "HTTP/1.1 204 No Content\r\n",
            "Access-Control-Allow-Origin: *\r\n",
            "Access-Control-Allow-Methods: GET, POST, OPTIONS\r\n",
            "Access-Control-Allow-Headers: Content-Type\r\n",
            "Access-Control-Max-Age: 86400\r\n",
            "Content-Length: 0\r\n",
            "Connection: close\r\n",
            "\r\n",
        })
        self:_sendAll(client, resp)
        return
    end

    -- Serve static files
    if method == "GET" and (path == "/" or path == "/index.html") then
        self:_serveIndex(client)
        return
    end

    -- Favicon (prevent 404 spam in browser console)
    if method == "GET" and path == "/favicon.ico" then
        self:_sendError(client, 204, "No Content")
        return
    end

    -- API routes
    if path:match("^/api/") then
        local FileOps = self._fileops
        local FileSyncManager = require("filesync/filesyncmanager")
        local safe_mode = FileSyncManager:getSafeMode()

        -- Language endpoint for web UI i18n
        if method == "GET" and path == "/api/lang" then
            local lang = G_reader_settings:readSetting("language") or "en"
            self:_sendJSON(client, 200, {lang = lang})
            return
        end

        -- Health check endpoint for debugging
        if method == "GET" and path == "/api/health" then
            self:_sendJSON(client, 200, {
                status = "ok",
                root_dir = self.root_dir,
                fileops_loaded = FileOps ~= nil,
            })
            return
        end

        if not FileOps then
            self:_sendJSON(client, 500, {error = "File operations module not loaded"})
            return
        end

        if method == "GET" and path == "/api/metadata" then
            local file_path = query.path
            if not file_path then
                self:_sendJSON(client, 400, {error = "Missing path parameter"})
                return
            end
            -- Block non-whitelisted files in safe mode
            if safe_mode then
                local filename = file_path:match("([^/]+)$")
                if filename and not FileOps:isExtensionSafe(filename) then
                    self:_sendJSON(client, 403, {error = "Access denied: file type not allowed in safe mode"})
                    return
                end
            end
            local result, err_msg = FileOps:getMetadata(file_path)
            if result then
                self:_sendJSON(client, 200, result)
            else
                self:_sendJSON(client, 400, {error = err_msg or "Cannot get metadata"})
            end

        elseif method == "GET" and path == "/api/cover" then
            local file_path = query.path
            if not file_path then
                self:_sendJSON(client, 400, {error = "Missing path parameter"})
                return
            end
            local ok, err_msg = FileOps:getBookCover(client, file_path, self)
            if not ok then
                self:_sendJSON(client, 404, {error = err_msg or "Cover not found"})
            end

        elseif method == "GET" and path == "/api/files" then
            local dir = query.path or "/"
            local sort_by = query.sort or "name"
            local sort_order = query.order or "asc"
            local filter = query.filter or ""
            local result, err_msg = FileOps:listDirectory(dir, sort_by, sort_order, filter, safe_mode)
            if result then
                self:_sendJSON(client, 200, result)
            else
                self:_sendJSON(client, 400, {error = err_msg or "Cannot list directory"})
            end

        elseif method == "GET" and path == "/api/download" then
            local file_path = query.path
            if not file_path then
                self:_sendJSON(client, 400, {error = "Missing path parameter"})
                return
            end
            -- Block non-whitelisted files in safe mode
            if safe_mode then
                local filename = file_path:match("([^/]+)$")
                if filename and not FileOps:isExtensionSafe(filename) then
                    self:_sendJSON(client, 403, {error = "Access denied: file type not allowed in safe mode"})
                    return
                end
            end
            local inline = query.preview == "1"
            local ok, err_msg = FileOps:downloadFile(client, file_path, self, inline)
            if not ok then
                self:_sendJSON(client, 400, {error = err_msg or "Cannot download file"})
            end

        elseif method == "POST" and path == "/api/upload" then
            local dir = query.path or "/"
            local content_type = headers["content-type"] or ""
            if content_type:match("multipart/form%-data") then
                local boundary = content_type:match("boundary=([^\r\n;]+)")
                if boundary then
                    local ok, err_msg = FileOps:handleUpload(dir, body, boundary)
                    if ok then
                        self:_sendJSON(client, 200, {success = true, message = "Upload complete"})
                    else
                        self:_sendJSON(client, 400, {error = err_msg or "Upload failed"})
                    end
                else
                    self:_sendJSON(client, 400, {error = "Missing boundary in content-type"})
                end
            else
                self:_sendJSON(client, 400, {error = "Expected multipart/form-data"})
            end

        elseif method == "POST" and path == "/api/mkdir" then
            local data = self:_parseJSON(body)
            if data and data.path then
                local ok, err_msg = FileOps:createDirectory(data.path)
                if ok then
                    self:_sendJSON(client, 200, {success = true})
                else
                    self:_sendJSON(client, 400, {error = err_msg or "Cannot create directory"})
                end
            else
                self:_sendJSON(client, 400, {error = "Missing path"})
            end

        elseif method == "POST" and path == "/api/rename" then
            local data = self:_parseJSON(body)
            if data and data.old_path and data.new_path then
                local ok, err_msg = FileOps:rename(data.old_path, data.new_path)
                if ok then
                    self:_sendJSON(client, 200, {success = true})
                else
                    self:_sendJSON(client, 400, {error = err_msg or "Cannot rename"})
                end
            else
                self:_sendJSON(client, 400, {error = "Missing old_path or new_path"})
            end

        elseif method == "POST" and path == "/api/move" then
            local data = self:_parseJSON(body)
            if data and data.old_path and data.new_path then
                local ok, err_msg = FileOps:move(data.old_path, data.new_path)
                if ok then
                    self:_sendJSON(client, 200, {success = true})
                else
                    self:_sendJSON(client, 400, {error = err_msg or "Cannot move"})
                end
            else
                self:_sendJSON(client, 400, {error = "Missing old_path or new_path"})
            end

        elseif method == "POST" and path == "/api/copy" then
            local data = self:_parseJSON(body)
            if data and data.old_path and data.new_path then
                local ok, err_msg = FileOps:copyFile(data.old_path, data.new_path)
                if ok then
                    self:_sendJSON(client, 200, {success = true})
                else
                    self:_sendJSON(client, 400, {error = err_msg or "Cannot copy"})
                end
            else
                self:_sendJSON(client, 400, {error = "Missing old_path or new_path"})
            end

        elseif method == "POST" and path == "/api/delete" then
            local data = self:_parseJSON(body)
            if data and data.path then
                local delete_options = {
                    safe_mode = safe_mode,
                    delete_sdr = data.delete_sdr == true,
                    recursive = data.recursive == true,
                }
                local ok, err_msg = FileOps:delete(data.path, delete_options)
                if ok then
                    self:_sendJSON(client, 200, {success = true})
                else
                    self:_sendJSON(client, 400, {error = err_msg or "Cannot delete"})
                end
            else
                self:_sendJSON(client, 400, {error = "Missing path"})
            end

        else
            self:_sendError(client, 404, "Not Found")
        end
    else
        self:_sendError(client, 404, "Not Found")
    end
end

function HttpServer:_serveIndex(client)
    if not self._static_cache.index then
        -- Load the HTML file from the static directory
        local plugin_dir = self:_getPluginDir()
        local f = io.open(plugin_dir .. "/static/index.html", "r")
        if not f then
            self:_sendError(client, 500, "Web interface not found")
            return
        end
        self._static_cache.index = f:read("*all")
        f:close()
    end

    local html = self._static_cache.index
    local response = table.concat({
        "HTTP/1.1 200 OK\r\n",
        "Content-Type: text/html; charset=utf-8\r\n",
        "Content-Length: " .. #html .. "\r\n",
        "Connection: close\r\n",
        "Cache-Control: no-cache\r\n",
        "\r\n",
        html,
    })
    self:_sendAll(client, response)
end

function HttpServer:_getPluginDir()
    -- Locate the plugin directory
    local info = debug.getinfo(1, "S")
    local script_path = info.source:match("@(.+)")
    if script_path then
        return script_path:match("(.+)/[^/]+$") or "."
    end
    return "."
end

--- Send all data on a socket, handling partial sends
function HttpServer:_sendAll(client, data)
    local total = #data
    local sent = 0
    while sent < total do
        local bytes, err, partial = client:send(data, sent + 1)
        if bytes then
            sent = bytes
        elseif partial and partial > 0 then
            sent = partial
        else
            return nil, err
        end
    end
    return sent
end

function HttpServer:_sendJSON(client, status, data)
    local json_body = self:_encodeJSON(data)
    local status_text = ({
        [200] = "OK",
        [400] = "Bad Request",
        [403] = "Forbidden",
        [404] = "Not Found",
        [500] = "Internal Server Error",
    })[status] or "OK"

    local response = table.concat({
        "HTTP/1.1 " .. status .. " " .. status_text .. "\r\n",
        "Content-Type: application/json; charset=utf-8\r\n",
        "Content-Length: " .. #json_body .. "\r\n",
        "Connection: close\r\n",
        "Access-Control-Allow-Origin: *\r\n",
        "\r\n",
        json_body,
    })
    self:_sendAll(client, response)
end

function HttpServer:_sendError(client, status, message)
    local body = "<html><body><h1>" .. status .. " " .. message .. "</h1></body></html>"
    local response = table.concat({
        "HTTP/1.1 " .. status .. " " .. message .. "\r\n",
        "Content-Type: text/html; charset=utf-8\r\n",
        "Content-Length: " .. #body .. "\r\n",
        "Connection: close\r\n",
        "\r\n",
        body,
    })
    self:_sendAll(client, response)
end

--- Send raw response headers for file download (used by FileOps)
function HttpServer:sendResponseHeaders(client, status, headers_table)
    local status_text = ({
        [200] = "OK",
        [206] = "Partial Content",
        [400] = "Bad Request",
        [404] = "Not Found",
        [500] = "Internal Server Error",
    })[status] or "OK"

    local parts = {"HTTP/1.1 " .. status .. " " .. status_text .. "\r\n"}
    for key, value in pairs(headers_table) do
        table.insert(parts, key .. ": " .. value .. "\r\n")
    end
    table.insert(parts, "\r\n")
    self:_sendAll(client, table.concat(parts))
end

function HttpServer:_urlDecode(str)
    str = str:gsub("+", " ")
    str = str:gsub("%%(%x%x)", function(h)
        return string.char(tonumber(h, 16))
    end)
    return str
end

function HttpServer:_parseQuery(query_string)
    local query = {}
    if not query_string or query_string == "" then
        return query
    end
    for pair in query_string:gmatch("[^&]+") do
        local key, value = pair:match("^([^=]+)=?(.*)")
        if key then
            query[self:_urlDecode(key)] = self:_urlDecode(value or "")
        end
    end
    return query
end

--- Minimal JSON encoder (handles strings, numbers, booleans, tables, arrays)
function HttpServer:_encodeJSON(value)
    local t = type(value)
    if t == "nil" then
        return "null"
    elseif t == "boolean" then
        return value and "true" or "false"
    elseif t == "number" then
        -- Guard against nan/inf which are not valid JSON
        if value ~= value then return "0" end -- NaN
        if value == math.huge or value == -math.huge then return "0" end
        return tostring(value)
    elseif t == "string" then
        return '"' .. self:_escapeJSONString(value) .. '"'
    elseif t == "table" then
        -- Check if it's an array
        if #value > 0 or next(value) == nil then
            local is_array = true
            local max_idx = 0
            for k, _ in pairs(value) do
                if type(k) ~= "number" or k < 1 or k ~= math.floor(k) then
                    is_array = false
                    break
                end
                if k > max_idx then max_idx = k end
            end
            if is_array and max_idx == #value then
                local items = {}
                for i = 1, #value do
                    table.insert(items, self:_encodeJSON(value[i]))
                end
                return "[" .. table.concat(items, ",") .. "]"
            end
        end
        -- Object
        local items = {}
        for k, v in pairs(value) do
            table.insert(items, '"' .. self:_escapeJSONString(tostring(k)) .. '":' .. self:_encodeJSON(v))
        end
        return "{" .. table.concat(items, ",") .. "}"
    end
    return "null"
end

function HttpServer:_escapeJSONString(s)
    local result = {}
    for i = 1, #s do
        local b = string.byte(s, i)
        if b == 34 then         -- "
            result[#result + 1] = '\\"'
        elseif b == 92 then     -- \
            result[#result + 1] = '\\\\'
        elseif b == 47 then     -- /
            result[#result + 1] = '\\/'
        elseif b == 8 then      -- backspace
            result[#result + 1] = '\\b'
        elseif b == 12 then     -- form feed
            result[#result + 1] = '\\f'
        elseif b == 10 then     -- newline
            result[#result + 1] = '\\n'
        elseif b == 13 then     -- carriage return
            result[#result + 1] = '\\r'
        elseif b == 9 then      -- tab
            result[#result + 1] = '\\t'
        elseif b < 32 then      -- other control chars
            result[#result + 1] = string.format("\\u%04x", b)
        else
            result[#result + 1] = string.char(b)
        end
    end
    return table.concat(result)
end

--- Minimal JSON decoder
function HttpServer:_parseJSON(str)
    if not str or str == "" then return nil end
    -- Use a simple recursive descent parser
    local pos = 1

    local function skip_whitespace()
        while pos <= #str and str:sub(pos, pos):match("%s") do
            pos = pos + 1
        end
    end

    local parse_value -- forward declaration

    local function parse_string()
        if str:sub(pos, pos) ~= '"' then return nil end
        pos = pos + 1
        local start = pos
        local result = {}
        while pos <= #str do
            local c = str:sub(pos, pos)
            if c == '"' then
                pos = pos + 1
                return table.concat(result)
            elseif c == '\\' then
                pos = pos + 1
                local esc = str:sub(pos, pos)
                if esc == '"' or esc == '\\' or esc == '/' then
                    table.insert(result, esc)
                elseif esc == 'n' then table.insert(result, '\n')
                elseif esc == 'r' then table.insert(result, '\r')
                elseif esc == 't' then table.insert(result, '\t')
                elseif esc == 'b' then table.insert(result, '\b')
                elseif esc == 'f' then table.insert(result, '\f')
                elseif esc == 'u' then
                    local hex = str:sub(pos + 1, pos + 4)
                    local code = tonumber(hex, 16)
                    if code then
                        if code < 128 then
                            table.insert(result, string.char(code))
                        end
                    end
                    pos = pos + 4
                end
                pos = pos + 1
            else
                table.insert(result, c)
                pos = pos + 1
            end
        end
        return nil
    end

    local function parse_number()
        local start = pos
        if str:sub(pos, pos) == '-' then pos = pos + 1 end
        while pos <= #str and str:sub(pos, pos):match("%d") do pos = pos + 1 end
        if pos <= #str and str:sub(pos, pos) == '.' then
            pos = pos + 1
            while pos <= #str and str:sub(pos, pos):match("%d") do pos = pos + 1 end
        end
        if pos <= #str and str:sub(pos, pos):lower() == 'e' then
            pos = pos + 1
            if pos <= #str and (str:sub(pos, pos) == '+' or str:sub(pos, pos) == '-') then
                pos = pos + 1
            end
            while pos <= #str and str:sub(pos, pos):match("%d") do pos = pos + 1 end
        end
        return tonumber(str:sub(start, pos - 1))
    end

    local function parse_object()
        pos = pos + 1 -- skip '{'
        skip_whitespace()
        local obj = {}
        if str:sub(pos, pos) == '}' then
            pos = pos + 1
            return obj
        end
        while true do
            skip_whitespace()
            local key = parse_string()
            if not key then return nil end
            skip_whitespace()
            if str:sub(pos, pos) ~= ':' then return nil end
            pos = pos + 1
            skip_whitespace()
            local val = parse_value()
            obj[key] = val
            skip_whitespace()
            if str:sub(pos, pos) == '}' then
                pos = pos + 1
                return obj
            end
            if str:sub(pos, pos) ~= ',' then return nil end
            pos = pos + 1
        end
    end

    local function parse_array()
        pos = pos + 1 -- skip '['
        skip_whitespace()
        local arr = {}
        if str:sub(pos, pos) == ']' then
            pos = pos + 1
            return arr
        end
        while true do
            skip_whitespace()
            local val = parse_value()
            table.insert(arr, val)
            skip_whitespace()
            if str:sub(pos, pos) == ']' then
                pos = pos + 1
                return arr
            end
            if str:sub(pos, pos) ~= ',' then return nil end
            pos = pos + 1
        end
    end

    parse_value = function()
        skip_whitespace()
        local c = str:sub(pos, pos)
        if c == '"' then return parse_string()
        elseif c == '{' then return parse_object()
        elseif c == '[' then return parse_array()
        elseif c == 't' then
            if str:sub(pos, pos + 3) == "true" then
                pos = pos + 4
                return true
            end
        elseif c == 'f' then
            if str:sub(pos, pos + 4) == "false" then
                pos = pos + 5
                return false
            end
        elseif c == 'n' then
            if str:sub(pos, pos + 3) == "null" then
                pos = pos + 4
                return nil
            end
        elseif c == '-' or c:match("%d") then
            return parse_number()
        end
        return nil
    end

    local ok, result = pcall(parse_value)
    if ok then return result end
    return nil
end

return HttpServer
