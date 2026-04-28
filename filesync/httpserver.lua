--- Non-blocking HTTP server for the FileSync plugin.
--- Built on LuaSocket, integrated with KOReader's UIManager for cooperative scheduling.
--- Handles routing for static file serving (web UI) and JSON API endpoints.
--- Delegates file operations to the fileops module and uses the shared json module
--- for request/response serialization.
---
--- Key dependencies: socket (LuaSocket), UIManager (KOReader), filesync/json, filesync/fileops

local JSON = require("filesync/json")
local Utils = require("filesync/utils")
local logger = require("logger")
local socket = require("socket")
local UIManager = require("ui/uimanager")

-- Maximum allowed upload size (200 MB) — checked via Content-Length before
-- reading any body data.  The streaming multipart parser writes file data
-- directly to disk in chunks, so memory usage stays constant (~64-128 KB)
-- regardless of upload size.
local MAX_UPLOAD_SIZE = 1024 * 1024 * 1024
-- Maximum allowed body size for non-upload POST routes (JSON payloads).
-- These are small API bodies (rename, delete, mkdir) that are read fully
-- into memory, so keep the limit conservative.
local MAX_JSON_BODY_SIZE = 1 * 1024 * 1024
-- Maximum number of HTTP headers per request
local MAX_HEADER_COUNT = 100
-- Per-connection socket timeout in seconds. Kept short so a single slow
-- client cannot stall the UI event loop for too long.
local CONNECTION_TIMEOUT = 2
-- Per-chunk socket timeout for streaming uploads (seconds).  Each individual
-- receive() call during the upload gets this budget.  Must be generous
-- enough to accommodate slow WiFi but short enough to detect dead clients.
local UPLOAD_CHUNK_TIMEOUT = 10
-- Read buffer size for the streaming multipart parser (64 KB).
local STREAM_CHUNK_SIZE = 65536
-- Maximum wall-clock time (seconds) the poll loop may spend handling
-- connections before yielding back to the UIManager event loop.  This
-- prevents N slow clients from blocking the UI for N * CONNECTION_TIMEOUT.
local MAX_POLL_TIME = 3

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

--- Start the HTTP server: load fileops, bind to the configured port, and begin polling.
--- Throws an error if the port cannot be bound or fileops cannot be loaded.
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

--- Stop the HTTP server: close the socket, clear caches, and stop polling.
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

    local poll_start = socket.gettime()

    -- Process up to 4 pending connections per cycle (browser may open several at once).
    -- A per-poll time budget (MAX_POLL_TIME) prevents the full set of slow
    -- connections from blocking the UI for up to 4 * CONNECTION_TIMEOUT seconds.
    -- The budget is checked *before* starting each new connection so that a
    -- connection already in progress is never interrupted mid-handling.
    for _ = 1, 4 do
        -- Yield back to UIManager if this poll cycle has already consumed
        -- too much wall-clock time.  Remaining connections will be picked
        -- up on the next scheduled poll.
        if socket.gettime() - poll_start >= MAX_POLL_TIME then
            logger.dbg("FileSync HTTP: poll time budget exceeded, deferring remaining connections")
            break
        end

        local client = self._server_socket:accept()
        if not client then break end

        client:settimeout(CONNECTION_TIMEOUT)
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

    -- Read headers (limit count to prevent resource exhaustion)
    local headers = {}
    local header_count = 0
    while true do
        local line = client:receive("*l")
        if not line or line == "" then break end
        header_count = header_count + 1
        if header_count > MAX_HEADER_COUNT then
            self:_sendError(client, 431, "Request Header Fields Too Large")
            return
        end
        local key, value = line:match("^([^:]+):%s*(.+)")
        if key then
            headers[key:lower()] = value
        end
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

    local content_length = tonumber(headers["content-length"])

    -- Upload route: validate Content-Length then hand the socket to the
    -- streaming multipart parser — body is never buffered in memory.
    if method == "POST" and path_part == "/api/upload" then
        if not content_length or content_length <= 0 then
            self:_sendJSON(client, 400, {error = "Missing Content-Length"})
            return
        end
        if content_length > MAX_UPLOAD_SIZE then
            self:_sendJSON(client, 413, {error = "Payload too large (limit: 200 MB)"})
            return
        end
        local content_type = headers["content-type"] or ""
        local dir = query.path or "/"
        self:_handleStreamingUpload(client, content_length, content_type, dir)
        return
    end

    -- Non-upload routes: read the full body into memory (small JSON payloads)
    local body = nil
    if content_length and content_length > 0 then
        if content_length > MAX_JSON_BODY_SIZE then
            self:_sendError(client, 413, "Payload Too Large")
            return
        end
        body = self:_readBody(client, content_length)
    end

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

--- Route an HTTP request to the appropriate handler.
--- API endpoints:
---   GET  /api/lang       - returns {lang: string} (KOReader UI language)
---   GET  /api/health     - returns {status, root_dir, fileops_loaded}
---   GET  /api/home       - returns {home: string|null} (KOReader home_dir, relative to root_dir)
---   GET  /api/files      - list directory (query: path, sort, order, filter)
---   GET  /api/dirinfo    - recursive file count (query: path)
---   GET  /api/metadata   - file metadata (query: path)
---   GET  /api/cover      - book cover image (query: path)
---   GET  /api/download   - file download (query: path, preview)
---   POST /api/upload     - multipart file upload (query: path)
---   POST /api/mkdir      - create directory (body: {path})
---   POST /api/rename     - rename file/dir (body: {old_path, new_path})
---   POST /api/delete     - delete file/dir (body: {path, delete_sdr})
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

        -- KOReader home folder, returned as a path relative to root_dir.
        -- Returns null if home_dir is unset or lies outside root_dir, so the
        -- frontend can decide its own fallback (currently: open at root).
        if method == "GET" and path == "/api/home" then
            local home_dir = G_reader_settings:readSetting("home_dir")
            local home_rel = nil
            if home_dir and home_dir ~= "" and self.root_dir then
                local root = self.root_dir
                if home_dir == root then
                    home_rel = "/"
                elseif home_dir:sub(1, #root) == root
                    and (home_dir:sub(#root + 1, #root + 1) == "/" or #home_dir == #root) then
                    home_rel = home_dir:sub(#root + 1)
                    if home_rel == "" then home_rel = "/" end
                end
            end
            self:_sendJSON(client, 200, {home = home_rel})
            return
        end

        if not FileOps then
            self:_sendJSON(client, 500, {error = "File operations module not loaded"})
            return
        end

        if method == "GET" and path == "/api/dirinfo" then
            local dir_path = query.path
            if not dir_path then
                self:_sendJSON(client, 400, {error = "Missing path parameter"})
                return
            end
            local file_count, err_msg = FileOps:getDirInfo(dir_path)
            if file_count then
                self:_sendJSON(client, 200, {file_count = file_count})
            else
                self:_sendJSON(client, 400, {error = err_msg or "Cannot get directory info"})
            end

        elseif method == "GET" and path == "/api/metadata" then
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
            local cover, err_msg = FileOps:getBookCover(file_path)
            if not cover then
                self:_sendJSON(client, 404, {error = err_msg or "Cover not found"})
            else
                self:sendResponseHeaders(client, 200, {
                    ["Content-Type"] = cover.content_type,
                    ["Content-Length"] = tostring(#cover.data),
                    ["Cache-Control"] = "public, max-age=86400",
                    ["Connection"] = "close",
                })
                self:_sendAll(client, cover.data)
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
            local result, err_msg = FileOps:downloadFile(file_path, inline)
            if not result then
                self:_sendJSON(client, 400, {error = err_msg or "Cannot download file"})
            else
                local disposition = result.inline
                    and ('inline; filename="' .. result.filename .. '"')
                    or ('attachment; filename="' .. result.filename .. '"')
                self:sendResponseHeaders(client, 200, {
                    ["Content-Type"] = result.mime_type,
                    ["Content-Length"] = tostring(result.size),
                    ["Content-Disposition"] = disposition,
                    ["Connection"] = "close",
                })
                -- Stream file in chunks, yielding to UIManager periodically
                -- to keep the e-reader UI responsive during large downloads.
                local CHUNK_SIZE = 65536
                local YIELD_INTERVAL = 32 -- yield every 32 chunks (~2 MB)
                local stream_ok = true
                local chunk_count = 0
                while stream_ok do
                    local chunk = result.file_handle:read(CHUNK_SIZE)
                    if not chunk then break end
                    local sent, send_err = self:_sendAll(client, chunk)
                    if not sent then
                        logger.warn("FileSync HTTP: send error during download:", send_err)
                        stream_ok = false
                    end
                    chunk_count = chunk_count + 1
                    if chunk_count % YIELD_INTERVAL == 0 then
                        -- Let UIManager process pending events so the UI stays responsive
                        pcall(function() UIManager:handleInput() end)
                    end
                end
                result.file_handle:close()
            end

        elseif method == "POST" and path == "/api/mkdir" then
            local data = JSON.decode(body)
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
            local data = JSON.decode(body)
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

        elseif method == "POST" and path == "/api/delete" then
            local data = JSON.decode(body)
            if data and data.path then
                local delete_options = {
                    safe_mode = safe_mode,
                    delete_sdr = data.delete_sdr == true,
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

--- Extract the multipart boundary string from a Content-Type header value.
--- @param content_type string: the Content-Type header value
--- @return string|nil: the boundary string, or nil if not found
function HttpServer:_extractBoundary(content_type)
    if not content_type or not content_type:match("multipart/form%-data") then
        return nil
    end
    return content_type:match("boundary=([^\r\n;%s]+)")
end

--- Extract and sanitize a filename from multipart part headers.
--- Strips path components, fixes iOS Safari .zip suffix on EPUB/CBZ files,
--- and validates the result.
--- @param headers_str string: the raw headers of a multipart part
--- @param file_ops table: FileOps instance for filename validation
--- @return string|nil: sanitized filename, or nil on failure
--- @return string|nil: error message on failure
function HttpServer:_extractUploadFilename(headers_str, file_ops)
    local filename = headers_str:match('filename="([^"]+)"')
    if not filename or filename == "" then
        return nil, "No filename in part"
    end
    -- Strip path components (some browsers send full paths)
    filename = filename:match("([^/\\]+)$") or filename
    -- Fix iOS Safari appending .zip to EPUB/CBZ files (they are ZIP-based)
    if filename:match("%.epub%.zip$") then
        filename = filename:gsub("%.zip$", "")
    elseif filename:match("%.cbz%.zip$") then
        filename = filename:gsub("%.zip$", "")
    end
    if file_ops then
        local valid, valid_err = file_ops:_validateFilename(filename)
        if not valid then
            return nil, valid_err
        end
    end
    return filename
end

--- Handle a streaming multipart file upload.
--- Reads from the socket in fixed-size chunks, parses multipart boundaries
--- on the fly, and writes file data directly to disk as it arrives.
--- Memory usage stays constant (~64-128 KB) regardless of upload size.
---
--- @param client userdata: the connected client socket
--- @param content_length number: total bytes to read from the socket
--- @param content_type string: Content-Type header value
--- @param rel_dir string: relative directory path for uploaded files
function HttpServer:_handleStreamingUpload(client, content_length, content_type, rel_dir)
    local FileOps = self._fileops
    if not FileOps then
        self:_sendJSON(client, 500, {error = "File operations module not loaded"})
        return
    end

    -- Validate content type and extract boundary
    local boundary = self:_extractBoundary(content_type)
    if not boundary then
        self:_sendJSON(client, 400, {error = "Missing boundary in content-type"})
        return
    end

    -- Resolve and validate the upload directory
    local dir_path, dir_err = FileOps:_resolvePath(rel_dir)
    if not dir_path then
        self:_sendJSON(client, 400, {error = dir_err or "Invalid upload path"})
        return
    end

    local ok_lfs, lfs_mod = pcall(require, "lfs")
    if not ok_lfs then
        ok_lfs, lfs_mod = pcall(require, "libs/libkoreader-lfs")
    end
    local dir_attr = lfs_mod and lfs_mod.attributes(dir_path)
    if not dir_attr or dir_attr.mode ~= "directory" then
        self:_sendJSON(client, 400, {error = "Upload directory does not exist"})
        return
    end

    -- Set a longer per-chunk timeout for uploads
    local original_timeout = CONNECTION_TIMEOUT
    client:settimeout(UPLOAD_CHUNK_TIMEOUT)

    -- Multipart delimiter: "\r\n--boundary" separates parts in the body.
    -- The closing boundary is detected by checking for "--" after the delimiter.
    local delimiter = "\r\n--" .. boundary
    local delimiter_len = #delimiter

    -- State machine: PREAMBLE -> HEADERS -> FILE_DATA -> (loop or DONE)
    local state = "PREAMBLE"
    local buffer = ""           -- accumulation buffer (kept small via flushing)
    local bytes_read = 0        -- total bytes consumed from the socket
    local current_file = nil    -- file handle for the file being written
    local current_path = nil    -- full path to the file being written
    local uploaded_files = {}
    local errors = {}

    --- Clean up the current file on error: close and remove partial file.
    local function cleanup_current_file()
        if current_file then
            pcall(function() current_file:close() end)
            current_file = nil
        end
        if current_path then
            pcall(function() os.remove(current_path) end)
            current_path = nil
        end
    end

    --- Extract filename from Content-Disposition header string.
    local function extract_filename(headers_str)
        return self:_extractUploadFilename(headers_str, FileOps)
    end

    --- Read the next chunk from the socket and append it to the buffer.
    --- Yields to UIManager every 32 chunks (~2 MB) to keep the UI responsive.
    --- Returns true on success, false on connection error.
    local upload_chunk_count = 0
    local UPLOAD_YIELD_INTERVAL = 32 -- yield every ~2 MB
    local function read_next_chunk()
        local to_read = math.min(STREAM_CHUNK_SIZE, content_length - bytes_read)
        if to_read <= 0 then
            return false -- nothing left to read
        end
        local data, err, partial = client:receive(to_read)
        if data then
            buffer = buffer .. data
            bytes_read = bytes_read + #data
        elseif partial and #partial > 0 then
            buffer = buffer .. partial
            bytes_read = bytes_read + #partial
        else
            return false, err or "connection lost"
        end
        upload_chunk_count = upload_chunk_count + 1
        if upload_chunk_count % UPLOAD_YIELD_INTERVAL == 0 then
            pcall(function() UIManager:handleInput() end)
        end
        return true
    end

    -- Read the entire body in chunks and parse the multipart stream.
    -- The outer loop reads from the socket; the inner logic is a state machine.
    local parse_error = nil

    -- Seed the buffer with the first chunk
    local ok, recv_err = read_next_chunk()
    if not ok then
        client:settimeout(original_timeout)
        self:_sendJSON(client, 400, {error = "Failed to read upload data: " .. tostring(recv_err)})
        return
    end

    while true do
        if state == "PREAMBLE" then
            -- The preamble is everything before the first boundary.
            -- The first boundary in the body starts with "--boundary" (no leading \r\n).
            local first_delim = "--" .. boundary
            local pos = buffer:find(first_delim, 1, true)
            if pos then
                -- Skip past the boundary line and its trailing \r\n
                local after_boundary = pos + #first_delim
                -- Check for closing marker right away (empty body)
                if buffer:sub(after_boundary, after_boundary + 1) == "--" then
                    state = "DONE"
                else
                    -- Skip the \r\n after the boundary
                    if buffer:sub(after_boundary, after_boundary + 1) == "\r\n" then
                        after_boundary = after_boundary + 2
                    end
                    buffer = buffer:sub(after_boundary)
                    state = "HEADERS"
                end
            else
                -- Need more data to find the first boundary
                if bytes_read >= content_length then
                    parse_error = "Invalid multipart format: no boundary found"
                    break
                end
                local chunk_ok, chunk_err = read_next_chunk()
                if not chunk_ok then
                    parse_error = "Connection lost while reading preamble: " .. tostring(chunk_err)
                    break
                end
            end

        elseif state == "HEADERS" then
            -- Accumulate until we find the blank line (\r\n\r\n) separating
            -- part headers from the part body.
            local header_end = buffer:find("\r\n\r\n", 1, true)
            if header_end then
                local headers_str = buffer:sub(1, header_end - 1)
                buffer = buffer:sub(header_end + 4)

                local filename, fn_err = extract_filename(headers_str)
                if filename then
                    local file_path = dir_path .. "/" .. filename
                    local f, open_err = io.open(file_path, "wb")
                    if f then
                        current_file = f
                        current_path = file_path
                    else
                        table.insert(errors, filename .. ": " .. tostring(open_err))
                        logger.warn("FileSync HTTP: cannot open file for writing:", file_path, open_err)
                    end
                else
                    -- Non-file form field or invalid filename — skip this part's data
                    if fn_err then
                        logger.dbg("FileSync HTTP: skipping part:", fn_err)
                    end
                end
                state = "FILE_DATA"
            else
                -- Headers not yet complete — need more data.
                -- Guard against absurdly large headers (> 64 KB is suspicious).
                if #buffer > STREAM_CHUNK_SIZE then
                    parse_error = "Multipart part headers too large"
                    break
                end
                if bytes_read >= content_length then
                    parse_error = "Unexpected end of data while reading part headers"
                    break
                end
                local chunk_ok, chunk_err = read_next_chunk()
                if not chunk_ok then
                    parse_error = "Connection lost while reading part headers: " .. tostring(chunk_err)
                    break
                end
            end

        elseif state == "FILE_DATA" then
            -- Scan the buffer for the next boundary delimiter.
            -- The delimiter in the body is "\r\n--boundary" (the \r\n belongs
            -- to the multipart framing, NOT to the file data).
            --
            -- To handle boundaries that straddle chunk boundaries, we keep
            -- at least (delimiter_len - 1) bytes at the tail of the buffer
            -- as overlap.  Everything before that "safe zone" can be flushed
            -- to disk immediately.

            local found_boundary = false
            local boundary_pos = buffer:find(delimiter, 1, true)

            if boundary_pos then
                local after_delim = boundary_pos + delimiter_len

                -- We need at least 2 bytes after the delimiter to determine
                -- if this is a closing boundary ("--") or a next-part
                -- boundary ("\r\n").  If the buffer is too short, read more.
                if after_delim + 1 > #buffer and bytes_read < content_length then
                    -- Don't flush anything yet — read another chunk so
                    -- we can inspect the bytes after the delimiter.
                    local chunk_ok, chunk_err = read_next_chunk()
                    if not chunk_ok then
                        if current_file then
                            table.insert(errors, (current_path or "?") .. ": connection lost at boundary")
                            cleanup_current_file()
                        end
                        parse_error = "Connection lost at boundary: " .. tostring(chunk_err)
                        break
                    end
                    -- Re-enter the loop; the boundary will be found again
                    -- with a larger buffer and enough trailing bytes.
                else
                    -- The file data is everything before the boundary.
                    local file_chunk = buffer:sub(1, boundary_pos - 1)
                    if current_file and #file_chunk > 0 then
                        local write_ok, write_err = current_file:write(file_chunk)
                        if not write_ok then
                            table.insert(errors, (current_path or "?") .. ": write failed: " .. tostring(write_err))
                            cleanup_current_file()
                        end
                    end

                    -- Close current file and record success
                    local function finish_current_file()
                        if current_file then
                            current_file:close()
                            current_file = nil
                            local fname = current_path and current_path:match("([^/]+)$")
                            if fname then
                                table.insert(uploaded_files, fname)
                                logger.info("FileSync: Uploaded", fname, "to", dir_path)
                            end
                            current_path = nil
                        end
                    end

                    -- Check if this is the closing boundary (--boundary--)
                    if buffer:sub(after_delim, after_delim + 1) == "--" then
                        finish_current_file()
                        state = "DONE"
                    else
                        finish_current_file()
                        -- Skip the \r\n after the boundary
                        if buffer:sub(after_delim, after_delim + 1) == "\r\n" then
                            after_delim = after_delim + 2
                        end
                        buffer = buffer:sub(after_delim)
                        state = "HEADERS"
                    end
                    found_boundary = true
                end
            end

            if not found_boundary then
                -- No boundary found in the current buffer.  Flush all
                -- data that is safely before any possible boundary overlap
                -- to disk, keeping the last (delimiter_len - 1) bytes.
                local safe_len = #buffer - (delimiter_len - 1)
                if safe_len > 0 then
                    local safe_data = buffer:sub(1, safe_len)
                    if current_file then
                        local write_ok, write_err = current_file:write(safe_data)
                        if not write_ok then
                            table.insert(errors, (current_path or "?") .. ": write failed: " .. tostring(write_err))
                            cleanup_current_file()
                        end
                    end
                    buffer = buffer:sub(safe_len + 1)
                end

                -- Read more data from the socket
                if bytes_read >= content_length then
                    -- We've read everything but didn't find a closing boundary.
                    -- Flush remaining buffer.
                    if current_file and #buffer > 0 then
                        current_file:write(buffer)
                    end
                    if current_file then
                        -- No proper closing boundary — treat as an error
                        table.insert(errors, (current_path or "?") .. ": incomplete upload (missing closing boundary)")
                        cleanup_current_file()
                    end
                    parse_error = "Invalid multipart format: missing closing boundary"
                    break
                end

                local chunk_ok, chunk_err = read_next_chunk()
                if not chunk_ok then
                    -- Connection dropped — clean up partial file
                    if current_file then
                        table.insert(errors, (current_path or "?") .. ": connection lost during upload")
                        cleanup_current_file()
                    end
                    parse_error = "Connection lost during file upload: " .. tostring(chunk_err)
                    break
                end
            end

        elseif state == "DONE" then
            break
        end
    end -- while true

    -- Final cleanup: if a file is still open, something went wrong
    cleanup_current_file()

    -- Restore original timeout
    client:settimeout(original_timeout)

    -- Drain any remaining body data from the socket that we haven't read
    -- (e.g. trailing whitespace after the closing boundary).
    if bytes_read < content_length then
        local leftover = content_length - bytes_read
        while leftover > 0 do
            local drain_size = math.min(STREAM_CHUNK_SIZE, leftover)
            local data, _, partial = client:receive(drain_size)
            if data then
                leftover = leftover - #data
            elseif partial then
                leftover = leftover - #partial
            else
                break
            end
        end
    end

    -- Release the buffer and force garbage collection to reclaim memory
    -- from string fragments accumulated during streaming. On devices with
    -- 256-512 MB RAM, this prevents memory pressure when the web UI
    -- immediately requests a directory listing after the upload.
    buffer = nil
    collectgarbage("collect")

    -- Send response
    if #uploaded_files > 0 then
        self:_sendJSON(client, 200, {success = true, message = "Upload complete"})
    elseif parse_error then
        self:_sendJSON(client, 400, {error = parse_error})
    elseif #errors > 0 then
        self:_sendJSON(client, 400, {error = errors[1]})
    else
        self:_sendJSON(client, 400, {error = "No files were uploaded"})
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

--- Get the directory containing this module's source files (filesync/).
--- Used for locating the static/ subdirectory for serving the web UI.
--- @return string: path to the filesync/ directory
function HttpServer:_getPluginDir()
    return Utils.getPluginDir() .. "/filesync"
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
    local json_body = JSON.encode(data)
    local status_text = ({
        [200] = "OK",
        [400] = "Bad Request",
        [403] = "Forbidden",
        [404] = "Not Found",
        [413] = "Payload Too Large",
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

return HttpServer
