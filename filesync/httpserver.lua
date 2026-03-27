local logger = require("logger")
local socket = require("socket")
local UIManager = require("ui/uimanager")

local ROOT_SESSION_COOKIE_NAME = "filesync_root_session"
local ROOT_SESSION_TTL = 15 * 60
local UNLOCK_FAILURE_RESET_AFTER = 15 * 60
local UNLOCK_RATE_LIMIT_TTL = 24 * 60 * 60
local UNLOCK_BACKOFF_STEPS = {0, 0, 5, 15, 30, 60, 120, 300}

local HttpServer = {
    port = 80,
    root_dir = "/mnt/us",
    _server_socket = nil,
    _running = false,
    _static_cache = {},
    _fileops = nil,
    _root_sessions = nil,
    _unlock_rate_limits = nil,
    _random_seeded = false,
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
    self._root_sessions = {}
    self._unlock_rate_limits = {}
    logger.info("FileSync HTTP: Listening on port", self.port)

    -- Schedule polling via UIManager
    self:_schedulePoll()
end

function HttpServer:stop()
    self._running = false
    self._root_sessions = {}
    self._unlock_rate_limits = {}
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

function HttpServer:invalidateAllRootSessions()
    self._root_sessions = {}
end

function HttpServer:_appendHeader(extra_headers, header)
    local headers = {}
    if extra_headers then
        for i = 1, #extra_headers do
            headers[#headers + 1] = extra_headers[i]
        end
    end
    headers[#headers + 1] = header
    return headers
end

function HttpServer:_seedRandom()
    if self._random_seeded then
        return
    end

    local seed = os.time()
    if socket.gettime then
        seed = seed + math.floor((socket.gettime() % 1) * 1000000)
    end
    math.randomseed(seed)
    self._random_seeded = true

    -- Discard the first values after seeding to avoid predictable repeats.
    for _ = 1, 4 do
        math.random()
    end
end

function HttpServer:_generateSessionToken()
    local bytes = 32
    local fh = io.open("/dev/urandom", "rb")
    if fh then
        local data = fh:read(bytes)
        fh:close()
        if data and #data == bytes then
            return (data:gsub(".", function(char)
                return string.format("%02x", string.byte(char))
            end))
        end
    end

    self:_seedRandom()
    local parts = {}
    for _ = 1, bytes do
        parts[#parts + 1] = string.format("%02x", math.random(0, 255))
    end
    return table.concat(parts)
end

function HttpServer:_parseCookies(cookie_header)
    local cookies = {}
    if not cookie_header or cookie_header == "" then
        return cookies
    end

    for pair in cookie_header:gmatch("[^;]+") do
        local key, value = pair:match("^%s*([^=]+)%s*=%s*(.-)%s*$")
        if key and value then
            cookies[key] = value
        end
    end
    return cookies
end

function HttpServer:_getRequestToken(headers, query)
    if headers then
        local header_token = headers["x-filesync-token"]
        if header_token and header_token ~= "" then
            return header_token
        end

        local authorization = headers["authorization"]
        if authorization then
            local bearer_token = authorization:match("^[Bb]earer%s+(.+)$")
            if bearer_token and bearer_token ~= "" then
                return bearer_token
            end
        end

        if query and query.token and query.token ~= "" then
            return query.token
        end

        local cookies = self:_parseCookies(headers["cookie"])
        local cookie_token = cookies[ROOT_SESSION_COOKIE_NAME]
        if cookie_token and cookie_token ~= "" then
            return cookie_token
        end
    end

    return nil
end

function HttpServer:_getClientIP(client)
    local ok, ip = pcall(function()
        return client:getpeername()
    end)
    if ok and ip and ip ~= "" then
        return tostring(ip)
    end
    return ""
end

function HttpServer:_pruneRootSessions()
    local sessions = self._root_sessions
    if not sessions then
        self._root_sessions = {}
        return
    end

    local now = self:_getNow()
    for token, session in pairs(sessions) do
        if not session or not session.expires_at or session.expires_at <= now then
            sessions[token] = nil
        end
    end
end

function HttpServer:_createRootSession(client_ip)
    self:_pruneRootSessions()

    local token
    repeat
        token = self:_generateSessionToken()
    until self._root_sessions[token] == nil

    local expires_at = self:_getNow() + ROOT_SESSION_TTL
    self._root_sessions[token] = {
        client_ip = client_ip or "",
        expires_at = expires_at,
    }
    return token, math.ceil(expires_at - self:_getNow())
end

function HttpServer:_invalidateRootSession(token)
    if token and self._root_sessions then
        self._root_sessions[token] = nil
    end
end

function HttpServer:_buildSessionCookie(token)
    return "Set-Cookie: " .. ROOT_SESSION_COOKIE_NAME .. "=" .. token
        .. "; Path=/; HttpOnly; SameSite=Strict"
end

function HttpServer:_buildClearedSessionCookie()
    return "Set-Cookie: " .. ROOT_SESSION_COOKIE_NAME .. "="
        .. "; Path=/; HttpOnly; SameSite=Strict; Max-Age=0"
end

function HttpServer:_getRequestSession(headers, query, client_ip)
    self:_pruneRootSessions()

    local token = self:_getRequestToken(headers, query)
    if not token then
        return {
            token = nil,
            has_token = false,
            valid = false,
            invalid = false,
            clear_cookie = false,
            expires_in = 0,
        }
    end

    local session = self._root_sessions and self._root_sessions[token]
    if not session then
        return {
            token = token,
            has_token = true,
            valid = false,
            invalid = true,
            clear_cookie = true,
            expires_in = 0,
        }
    end

    local now = self:_getNow()
    if not session.expires_at or session.expires_at <= now then
        self._root_sessions[token] = nil
        return {
            token = token,
            has_token = true,
            valid = false,
            invalid = true,
            clear_cookie = true,
            expires_in = 0,
        }
    end

    if session.client_ip ~= "" and client_ip ~= "" and session.client_ip ~= client_ip then
        self._root_sessions[token] = nil
        return {
            token = token,
            has_token = true,
            valid = false,
            invalid = true,
            clear_cookie = true,
            expires_in = 0,
        }
    end

    session.expires_at = now + ROOT_SESSION_TTL
    return {
        token = token,
        has_token = true,
        valid = true,
        invalid = false,
        clear_cookie = false,
        expires_in = math.ceil(session.expires_at - now),
    }
end

function HttpServer:_getNow()
    if socket.gettime then
        return socket.gettime()
    end
    return os.time()
end

function HttpServer:_pruneUnlockRateLimits()
    local rate_limits = self._unlock_rate_limits
    if not rate_limits then
        self._unlock_rate_limits = {}
        return
    end

    local now = self:_getNow()
    for key, entry in pairs(rate_limits) do
        local failures = entry and entry.failures or 0
        local blocked_until = entry and entry.blocked_until or 0
        local updated_at = entry and entry.updated_at or 0
        local last_failure_at = entry and entry.last_failure_at or 0
        local expired_state = updated_at > 0 and (now - updated_at) >= UNLOCK_RATE_LIMIT_TTL
        local reset_window_elapsed = last_failure_at > 0 and (now - last_failure_at) >= UNLOCK_FAILURE_RESET_AFTER
        local block_expired = blocked_until <= now

        if expired_state or (failures <= 0 and block_expired) or (reset_window_elapsed and block_expired) then
            rate_limits[key] = nil
        end
    end
end

function HttpServer:_buildUnlockRateLimitKey(prefix, value)
    if value == nil then
        return nil
    end

    value = tostring(value):gsub("^%s+", ""):gsub("%s+$", "")
    if value == "" then
        return nil
    end
    if #value > 160 then
        value = value:sub(1, 160)
    end
    return prefix .. value
end

function HttpServer:_getUnlockRateLimitKeys(auth_session, client_ip, headers)
    local keys = {}
    local seen = {}

    local function addKey(key)
        if key and not seen[key] then
            seen[key] = true
            keys[#keys + 1] = key
        end
    end

    addKey(self:_buildUnlockRateLimitKey("ip:", client_ip))

    if auth_session and auth_session.has_token and auth_session.token then
        addKey(self:_buildUnlockRateLimitKey("session:", auth_session.token))
    end

    if #keys == 0 and headers then
        addKey(self:_buildUnlockRateLimitKey("ua:", headers["user-agent"]))
    end

    if #keys == 0 then
        keys[1] = "unlock:fallback"
    end

    return keys
end

function HttpServer:_getUnlockBackoffSeconds(failures)
    failures = math.max(0, math.floor(tonumber(failures) or 0))
    if failures <= 0 then
        return 0
    end
    local index = math.min(failures, #UNLOCK_BACKOFF_STEPS)
    return UNLOCK_BACKOFF_STEPS[index] or UNLOCK_BACKOFF_STEPS[#UNLOCK_BACKOFF_STEPS]
end

function HttpServer:_resetUnlockAttempts(keys)
    if not keys then
        self._unlock_rate_limits = {}
        return
    end

    if not self._unlock_rate_limits then
        self._unlock_rate_limits = {}
        return
    end

    for _, key in ipairs(keys) do
        self._unlock_rate_limits[key] = nil
    end
end

function HttpServer:_getUnlockThrottleInfo(keys)
    self:_pruneUnlockRateLimits()

    local rate_limits = self._unlock_rate_limits
    if not rate_limits then
        return false, 0, 0
    end

    local now = self:_getNow()
    local max_retry_after = 0
    local max_failures = 0

    for _, key in ipairs(keys or {}) do
        local entry = rate_limits[key]
        if entry then
            local failures = entry.failures or 0
            if failures > max_failures then
                max_failures = failures
            end

            local blocked_until = entry.blocked_until or 0
            if blocked_until > now then
                local retry_after = math.ceil(blocked_until - now)
                if retry_after > max_retry_after then
                    max_retry_after = retry_after
                end
            end
        end
    end

    return max_retry_after > 0, max_retry_after, max_failures
end

function HttpServer:_registerUnlockFailure(keys)
    self:_pruneUnlockRateLimits()

    if not self._unlock_rate_limits then
        self._unlock_rate_limits = {}
    end

    local now = self:_getNow()
    local max_retry_after = 0
    local max_failures = 0

    for _, key in ipairs(keys or {}) do
        local entry = self._unlock_rate_limits[key]
        if not entry then
            entry = {
                failures = 0,
                blocked_until = 0,
                last_failure_at = 0,
                updated_at = now,
            }
            self._unlock_rate_limits[key] = entry
        end

        local blocked_until = entry.blocked_until or 0
        local last_failure_at = entry.last_failure_at or 0
        if blocked_until <= now
            and last_failure_at > 0
            and (now - last_failure_at) >= UNLOCK_FAILURE_RESET_AFTER then
            entry.failures = 0
            entry.blocked_until = 0
        end

        entry.failures = (entry.failures or 0) + 1
        entry.last_failure_at = now
        entry.updated_at = now

        local backoff = self:_getUnlockBackoffSeconds(entry.failures)
        if backoff > 0 then
            entry.blocked_until = now + backoff
            if backoff > max_retry_after then
                max_retry_after = backoff
            end
        else
            entry.blocked_until = 0
        end

        if entry.failures > max_failures then
            max_failures = entry.failures
        end
    end

    return max_retry_after > 0, max_retry_after, max_failures
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
    self:_route(client, method, path_part, query, headers, body, self:_getClientIP(client))
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

function HttpServer:_route(client, method, path, query, headers, body, client_ip)
    -- Handle CORS preflight
    if method == "OPTIONS" then
        local resp = table.concat({
            "HTTP/1.1 204 No Content\r\n",
            "Content-Length: 0\r\n",
            "Connection: close\r\n",
            "\r\n",
        })
        self:_sendAll(client, resp)
        return
    end

    -- Serve the SPA entrypoint for the root page and clean navigation routes.
    if method == "GET" and (
        path == "/"
        or path == "/index.html"
        or path == "/files"
        or path == "/system"
        or path:match("^/files/")
        or path:match("^/system/")
    ) then
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
        local auth_session = self:_getRequestSession(headers, query, client_ip)
        local root_unlocked = auth_session.valid
        local session_safe_mode = self:_getSessionSafeMode(has_root_pin, root_unlocked)
        local invalid_session_headers = auth_session.clear_cookie and { self:_buildClearedSessionCookie() } or nil

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
                session_invalid = auth_session.invalid,
                session_expires_in = auth_session.valid and auth_session.expires_in or 0,
                safe_extensions = FileOps:getSafeExtensions(),
                default_scope = navigation.default_scope,
                available_scopes = navigation.available_scopes,
                can_show_hidden = navigation.can_show_hidden,
                safe_root_path = navigation.safe_root_path,
                root_start_path = navigation.root_start_path,
            }, invalid_session_headers)
            return
        end

        if auth_session.invalid
            and path ~= "/api/auth/unlock"
            and path ~= "/api/auth/lock" then
            self:_sendJSON(client, 401, {
                error = "Authentication session expired",
                code = "auth_session_invalid",
            }, invalid_session_headers)
            return
        end

        if method == "POST" and path == "/api/auth/unlock" then
            local data = self:_parseJSON(body)
            local unlock_keys = self:_getUnlockRateLimitKeys(auth_session, client_ip, headers)
            local throttled, retry_after = self:_getUnlockThrottleInfo(unlock_keys)
            if not has_root_pin then
                self:_sendJSON(client, 400, {
                    error = "Root PIN is not configured",
                    code = "root_pin_missing",
                }, invalid_session_headers)
            elseif not data or data.pin == nil then
                self:_sendJSON(client, 400, {
                    error = "Missing pin",
                    code = "missing_pin",
                }, invalid_session_headers)
            elseif throttled then
                self:_sendJSON(client, 429, {
                    error = "Too many attempts. Try again soon.",
                    code = "auth_throttled",
                    retry_after = retry_after,
                }, self:_appendHeader(invalid_session_headers, "Retry-After: " .. retry_after))
            elseif FileSyncManager:verifyRootPin(data.pin) then
                self:_invalidateRootSession(auth_session.token)
                local token, expires_in = self:_createRootSession(client_ip)
                self:_resetUnlockAttempts(unlock_keys)
                self:_sendJSON(client, 200, {
                    success = true,
                    root_unlocked = true,
                    session_expires_in = expires_in,
                }, { self:_buildSessionCookie(token) })
            else
                local now_throttled, retry_after_after_failure, failure_count = self:_registerUnlockFailure(unlock_keys)
                if now_throttled then
                    self:_sendJSON(client, 429, {
                        error = "Too many attempts. Try again soon.",
                        code = "auth_throttled",
                        retry_after = retry_after_after_failure,
                        failed_attempts = failure_count,
                    }, self:_appendHeader(invalid_session_headers, "Retry-After: " .. retry_after_after_failure))
                else
                    self:_sendJSON(client, 403, {
                        error = "Invalid Root PIN",
                        code = "invalid_root_pin",
                        failed_attempts = failure_count,
                    }, invalid_session_headers)
                end
            end
            return
        end

        if method == "POST" and path == "/api/auth/lock" then
            self:_invalidateRootSession(auth_session.token)
            self:_sendJSON(client, 200, {
                success = true,
                root_unlocked = false,
            }, { self:_buildClearedSessionCookie() })
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
                    local ok, err_msg, err_details = FileOps:handleUpload(dir, body, boundary, file_options)
                    if ok then
                        self:_sendJSON(client, 200, {success = true, message = "Upload complete"})
                    elseif err_msg == "Root mode required for this file type" then
                        self:_sendJSON(client, 403, {
                            error = err_msg,
                            code = "root_required_upload",
                        })
                    else
                        local payload = {error = err_msg or "Upload failed"}
                        if err_details then
                            for key, value in pairs(err_details) do
                                payload[key] = value
                            end
                        end
                        self:_sendJSON(client, err_details and err_details.code == "destination_exists" and 409 or 400, payload)
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
                local ok, err_msg, err_details = FileOps:move(data.old_path, data.new_path, {
                    old_scope = data.old_scope,
                    new_scope = data.new_scope,
                    allow_root_scopes = true,
                    conflict_strategy = data.conflict_strategy,
                })
                if ok then
                    self:_sendJSON(client, 200, {success = true})
                else
                    local payload = {error = err_msg or "Cannot move"}
                    if err_details then
                        for key, value in pairs(err_details) do
                            payload[key] = value
                        end
                    end
                    self:_sendJSON(client, err_details and err_details.code == "destination_exists" and 409 or 400, payload)
                end
            else
                self:_sendJSON(client, 400, {error = "Missing old_path or new_path"})
            end

        elseif method == "POST" and path == "/api/copy" then
            local data = self:_parseJSON(body)
            if not root_unlocked then
                self:_sendJSON(client, 403, {error = "Root mode required", code = "root_required"})
            elseif data and data.old_path and data.new_path then
                local ok, err_msg, err_details = FileOps:copyFile(data.old_path, data.new_path, {
                    old_scope = data.old_scope,
                    new_scope = data.new_scope,
                    allow_root_scopes = true,
                    conflict_strategy = data.conflict_strategy,
                })
                if ok then
                    self:_sendJSON(client, 200, {success = true})
                else
                    local payload = {error = err_msg or "Cannot copy"}
                    if err_details then
                        for key, value in pairs(err_details) do
                            payload[key] = value
                        end
                    end
                    self:_sendJSON(client, err_details and err_details.code == "destination_exists" and 409 or 400, payload)
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

function HttpServer:_sendJSON(client, status, data, extra_headers)
    local json_body = self:_encodeJSON(data)
    local status_text = ({
        [200] = "OK",
        [401] = "Unauthorized",
        [400] = "Bad Request",
        [403] = "Forbidden",
        [404] = "Not Found",
        [429] = "Too Many Requests",
        [500] = "Internal Server Error",
    })[status] or "OK"

    local parts = {
        "HTTP/1.1 " .. status .. " " .. status_text .. "\r\n",
        "Content-Type: application/json; charset=utf-8\r\n",
        "Content-Length: " .. #json_body .. "\r\n",
        "Connection: close\r\n",
    }
    if extra_headers then
        for _, header in ipairs(extra_headers) do
            parts[#parts + 1] = header .. "\r\n"
        end
    end
    parts[#parts + 1] = "\r\n"
    parts[#parts + 1] = json_body
    self:_sendAll(client, table.concat(parts))
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
