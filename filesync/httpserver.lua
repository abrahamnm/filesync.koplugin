local logger = require("logger")
local socket = require("socket")
local UIManager = require("ui/uimanager")

local HttpServer = {
    port = 80,
    root_dir = "/mnt/us",
    _server_socket = nil,
    _running = false,
    _static_cache = {},
    _fileops = nil,
    _root_unlocked = false,
    _unlock_failed_attempts = 0,
    _unlock_blocked_until = 0,
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
        error("Could not bind to port " .. self.port .. ": " .. tostring(err)
              .. (self.port < 1024 and " (ports below 1024 may require root privileges)" or ""))
    end
    server:settimeout(0) -- Non-blocking
    self._server_socket = server
    self._running = true
    self._root_unlocked = false
    self._unlock_failed_attempts = 0
    self._unlock_blocked_until = 0
    logger.info("FileSync HTTP: Listening on port", self.port)

    -- Schedule polling via UIManager
    self:_schedulePoll()
end

function HttpServer:stop()
    self._running = false
    self._root_unlocked = false
    self._unlock_failed_attempts = 0
    self._unlock_blocked_until = 0
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

function HttpServer:setRootUnlocked(enabled)
    self._root_unlocked = enabled == true
end

function HttpServer:isRootUnlocked()
    return self._root_unlocked == true
end

function HttpServer:_getNow()
    if socket.gettime then
        return socket.gettime()
    end
    return os.time()
end

function HttpServer:_resetUnlockAttempts()
    self._unlock_failed_attempts = 0
    self._unlock_blocked_until = 0
end

function HttpServer:_getUnlockRetryAfter()
    local remaining = self._unlock_blocked_until - self:_getNow()
    if remaining <= 0 then
        return 0
    end
    return math.ceil(remaining)
end

function HttpServer:_registerUnlockFailure()
    self._unlock_failed_attempts = (self._unlock_failed_attempts or 0) + 1
    if self._unlock_failed_attempts >= 3 then
        self._unlock_failed_attempts = 0
        self._unlock_blocked_until = self:_getNow() + 5
        return true, self:_getUnlockRetryAfter()
    end
    return false, 0
end

function HttpServer:_getSessionSafeMode(has_root_pin, root_unlocked)
    return not (has_root_pin and root_unlocked)
end

function HttpServer:_parseHiddenFlag(value)
    return value == "1" or value == "true"
end

function HttpServer:_getNavigationContext(session_safe_mode)
    local FileOps = self._fileops
    local safe_scope = FileOps:getScopeInfo("storage", false)
    local root_scope = FileOps:getScopeInfo("system", true) or safe_scope

    if session_safe_mode then
        return {
            default_scope = safe_scope.id,
            available_scopes = { safe_scope },
            can_show_hidden = false,
            safe_root_path = safe_scope.root_path,
            root_start_path = safe_scope.root_path,
        }
    end

    return {
        default_scope = root_scope.id,
        available_scopes = { root_scope },
        can_show_hidden = root_scope.id == "system",
        safe_root_path = safe_scope.root_path,
        root_start_path = safe_scope.root_path,
    }
end

function HttpServer:_buildFileOptions(scope_id, session_safe_mode, include_hidden)
    local navigation = self:_getNavigationContext(session_safe_mode)
    return {
        scope = scope_id or navigation.default_scope,
        allow_root_scopes = not session_safe_mode,
        safe_mode = session_safe_mode,
        include_hidden = (not session_safe_mode) and include_hidden == true,
    }
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
        local has_root_pin = FileSyncManager:hasRootPin()
        local root_unlocked = self:isRootUnlocked()
        local session_safe_mode = self:_getSessionSafeMode(has_root_pin, root_unlocked)

        -- Language endpoint for web UI i18n
        if method == "GET" and path == "/api/lang" then
            local lang = G_reader_settings:readSetting("language") or "en"
            self:_sendJSON(client, 200, {lang = lang})
            return
        end

        if method == "GET" and path == "/api/auth/status" then
            local navigation = self:_getNavigationContext(session_safe_mode)
            self:_sendJSON(client, 200, {
                has_root_pin = has_root_pin,
                root_unlocked = root_unlocked,
                root_pin_length = FileSyncManager:getRootPinLength(),
                safe_extensions = FileOps:getSafeExtensions(),
                default_scope = navigation.default_scope,
                available_scopes = navigation.available_scopes,
                can_show_hidden = navigation.can_show_hidden,
                safe_root_path = navigation.safe_root_path,
                root_start_path = navigation.root_start_path,
            })
            return
        end

        if method == "POST" and path == "/api/auth/unlock" then
            local data = self:_parseJSON(body)
            if not has_root_pin then
                self:setRootUnlocked(false)
                self:_sendJSON(client, 400, {error = "Root PIN is not configured", code = "root_pin_missing"})
            elseif not data or data.pin == nil then
                self:setRootUnlocked(false)
                self:_sendJSON(client, 400, {error = "Missing pin", code = "missing_pin"})
            elseif self:_getUnlockRetryAfter() > 0 then
                self:setRootUnlocked(false)
                self:_sendJSON(client, 429, {
                    error = "Too many attempts. Try again soon.",
                    code = "auth_throttled",
                    retry_after = self:_getUnlockRetryAfter(),
                })
            elseif FileSyncManager:verifyRootPin(data.pin) then
                self:setRootUnlocked(true)
                self:_resetUnlockAttempts()
                self:_sendJSON(client, 200, {success = true, root_unlocked = true})
            else
                self:setRootUnlocked(false)
                local throttled, retry_after = self:_registerUnlockFailure()
                if throttled then
                    self:_sendJSON(client, 429, {
                        error = "Too many attempts. Try again soon.",
                        code = "auth_throttled",
                        retry_after = retry_after,
                    })
                else
                    self:_sendJSON(client, 403, {error = "Invalid Root PIN", code = "invalid_root_pin"})
                end
            end
            return
        end

        if method == "POST" and path == "/api/auth/lock" then
            self:setRootUnlocked(false)
            self:_resetUnlockAttempts()
            self:_sendJSON(client, 200, {success = true, root_unlocked = false})
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
            local file_options = self:_buildFileOptions(query.scope, session_safe_mode, false)
            if not file_path then
                self:_sendJSON(client, 400, {error = "Missing path parameter"})
                return
            end
            -- Block non-whitelisted files in safe mode
            if session_safe_mode then
                local filename = file_path:match("([^/]+)$")
                if filename and not FileOps:isExtensionSafe(filename) then
                    self:_sendJSON(client, 403, {error = "Access denied: file type not allowed in safe mode"})
                    return
                end
            end
            local result, err_msg = FileOps:getMetadata(file_path, file_options)
            if result then
                self:_sendJSON(client, 200, result)
            else
                self:_sendJSON(client, 400, {error = err_msg or "Cannot get metadata"})
            end

        elseif method == "GET" and path == "/api/metadata/editable" then
            local file_path = query.path
            local file_options = self:_buildFileOptions(query.scope, session_safe_mode, false)
            if not file_path then
                self:_sendJSON(client, 400, {error = "Missing path parameter"})
                return
            end
            local result, err_msg = FileOps:readEpubEditableMetadata(file_path, file_options)
            if result then
                self:_sendJSON(client, 200, result)
            else
                self:_sendJSON(client, 400, {error = err_msg or "Cannot read editable metadata"})
            end

        elseif method == "POST" and path == "/api/metadata/update" then
            local data = self:_parseJSON(body)
            if not root_unlocked then
                self:_sendJSON(client, 403, {error = "Root mode required to edit metadata", code = "root_required_metadata"})
            elseif not data or not data.path then
                self:_sendJSON(client, 400, {error = "Missing path"})
            else
                local file_options = self:_buildFileOptions(data.scope, session_safe_mode, false)
                file_options.allow_root_scopes = not session_safe_mode
                local ok, err_msg = FileOps:updateEpubMetadata(data.path, {
                    title = data.title,
                    author = data.author,
                    publisher = data.publisher,
                    description = data.description,
                }, file_options)
                if ok then
                    self:_sendJSON(client, 200, {success = true})
                else
                    self:_sendJSON(client, 400, {error = err_msg or "Cannot update metadata"})
                end
            end

        elseif method == "GET" and path == "/api/cover" then
            local file_path = query.path
            local file_options = self:_buildFileOptions(query.scope, session_safe_mode, false)
            if not file_path then
                self:_sendJSON(client, 400, {error = "Missing path parameter"})
                return
            end
            local ok, err_msg = FileOps:getBookCover(client, file_path, self, file_options)
            if not ok then
                self:_sendJSON(client, 404, {error = err_msg or "Cover not found"})
            end

        elseif method == "GET" and path == "/api/files" then
            local dir = query.path or "/"
            local sort_by = query.sort or "name"
            local sort_order = query.order or "asc"
            local filter = query.filter or ""
            local file_options = self:_buildFileOptions(query.scope, session_safe_mode, self:_parseHiddenFlag(query.hidden))
            local navigation = self:_getNavigationContext(session_safe_mode)
            local result, err_msg = FileOps:listDirectory(dir, sort_by, sort_order, filter, file_options)
            if result then
                result.available_scopes = navigation.available_scopes
                result.default_scope = navigation.default_scope
                result.can_show_hidden = navigation.can_show_hidden
                result.include_hidden = file_options.include_hidden
                result.safe_root_path = navigation.safe_root_path
                result.root_start_path = navigation.root_start_path
                self:_sendJSON(client, 200, result)
            else
                self:_sendJSON(client, 400, {error = err_msg or "Cannot list directory"})
            end

        elseif method == "GET" and path == "/api/download" then
            local file_path = query.path
            local file_options = self:_buildFileOptions(query.scope, session_safe_mode, false)
            if not file_path then
                self:_sendJSON(client, 400, {error = "Missing path parameter"})
                return
            end
            -- Block non-whitelisted files in safe mode
            if session_safe_mode then
                local filename = file_path:match("([^/]+)$")
                if filename and not FileOps:isExtensionSafe(filename) then
                    self:_sendJSON(client, 403, {error = "Access denied: file type not allowed in safe mode"})
                    return
                end
            end
            local inline = query.preview == "1"
            local ok, err_msg = FileOps:downloadFile(client, file_path, self, inline, file_options)
            if not ok then
                self:_sendJSON(client, 400, {error = err_msg or "Cannot download file"})
            end

        elseif method == "POST" and path == "/api/upload" then
            local dir = query.path or "/"
            local file_options = self:_buildFileOptions(query.scope, session_safe_mode, false)
            local content_type = headers["content-type"] or ""
            if content_type:match("multipart/form%-data") then
                local boundary = content_type:match("boundary=([^\r\n;]+)")
                if boundary then
                    local ok, err_msg = FileOps:handleUpload(dir, body, boundary, file_options)
                    if ok then
                        self:_sendJSON(client, 200, {success = true, message = "Upload complete"})
                    elseif err_msg == "Root mode required for this file type" then
                        self:_sendJSON(client, 403, {
                            error = err_msg,
                            code = "root_required_upload",
                        })
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
            if session_safe_mode then
                self:_sendJSON(client, 403, {error = "Root mode required to create folders", code = "root_required_create_folder"})
            elseif data and data.path then
                local ok, err_msg = FileOps:createDirectory(data.path, self:_buildFileOptions(data.scope, session_safe_mode, false))
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
                local ok, err_msg = FileOps:rename(data.old_path, data.new_path, self:_buildFileOptions(data.scope, session_safe_mode, false))
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
            if not root_unlocked then
                self:_sendJSON(client, 403, {error = "Root mode required", code = "root_required"})
            elseif data and data.old_path and data.new_path then
                local ok, err_msg = FileOps:move(data.old_path, data.new_path, {
                    old_scope = data.old_scope,
                    new_scope = data.new_scope,
                    allow_root_scopes = true,
                })
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
            if not root_unlocked then
                self:_sendJSON(client, 403, {error = "Root mode required", code = "root_required"})
            elseif data and data.old_path and data.new_path then
                local ok, err_msg = FileOps:copyFile(data.old_path, data.new_path, {
                    old_scope = data.old_scope,
                    new_scope = data.new_scope,
                    allow_root_scopes = true,
                })
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
                if session_safe_mode then
                    self:_sendJSON(client, 403, {error = "Root mode required to delete items", code = "root_required_delete"})
                    return
                end
                local delete_options = {
                    safe_mode = session_safe_mode,
                    delete_sdr = data.delete_sdr == true,
                    recursive = data.recursive == true,
                    scope = data.scope,
                    allow_root_scopes = not session_safe_mode,
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
