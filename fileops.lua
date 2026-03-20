-- Try standard require first, then KOReader's internal path
local ok, lfs = pcall(require, "lfs")
if not ok then
    ok, lfs = pcall(require, "libs/libkoreader-lfs")
end
if not ok then
    error("FileSync: cannot load LFS filesystem module")
end
local logger = require("logger")

local SAFE_MODE_EXTENSIONS = {
    epub = true, pdf = true, mobi = true, azw = true, azw3 = true,
    fb2 = true, ["fb2.zip"] = true, djvu = true, cbz = true, cbr = true, kfx = true,
    txt = true, doc = true, docx = true, rtf = true,
    html = true, htm = true, md = true, chm = true, pdb = true, prc = true, lit = true,
}

--- Read a big-endian uint16 from a binary string at 1-based offset
local function read_uint16_be(data, offset)
    return string.byte(data, offset) * 256 + string.byte(data, offset + 1)
end

--- Read a big-endian uint32 from a binary string at 1-based offset
local function read_uint32_be(data, offset)
    return string.byte(data, offset) * 16777216 + string.byte(data, offset + 1) * 65536
           + string.byte(data, offset + 2) * 256 + string.byte(data, offset + 3)
end

--- MOBI/AZW3 extensions lookup
local MOBI_EXTENSIONS = {
    mobi = true, azw = true, azw3 = true, prc = true, pdb = true,
}

local FileOps = {
    _root_dir = "/mnt/us",
}

function FileOps:setRootDir(dir)
    self._root_dir = dir
end

--- Resolve and validate a path, preventing path traversal.
--- Returns the full absolute path, or nil and an error message.
function FileOps:_resolvePath(rel_path)
    if not rel_path or rel_path == "" then
        rel_path = "/"
    end

    -- Normalize: remove double slashes, trim whitespace
    rel_path = rel_path:gsub("//+", "/"):gsub("^%s+", ""):gsub("%s+$", "")

    -- Block path traversal
    if rel_path:match("%.%.") then
        return nil, "Path traversal not allowed"
    end

    -- Ensure it starts with /
    if rel_path:sub(1, 1) ~= "/" then
        rel_path = "/" .. rel_path
    end

    local full_path = self._root_dir .. rel_path

    -- Normalize again after combining
    full_path = full_path:gsub("//+", "/")

    -- Remove trailing slash (except for root)
    if #full_path > 1 and full_path:sub(-1) == "/" then
        full_path = full_path:sub(1, -2)
    end

    -- Verify the resolved path is under root_dir
    if full_path:sub(1, #self._root_dir) ~= self._root_dir then
        return nil, "Access denied: path outside root directory"
    end

    return full_path
end

--- Validate a filename (no slashes, no dots-only, no null bytes)
function FileOps:_validateFilename(name)
    if not name or name == "" then
        return false, "Empty filename"
    end
    if name:find("/", 1, true) or name:find("\0", 1, true) then
        return false, "Invalid characters in filename"
    end
    if name == "." or name == ".." then
        return false, "Invalid filename"
    end
    if #name > 255 then
        return false, "Filename too long"
    end
    return true
end

--- Get the relative path from root_dir
function FileOps:_getRelativePath(full_path)
    if full_path:sub(1, #self._root_dir) == self._root_dir then
        local rel = full_path:sub(#self._root_dir + 1)
        if rel == "" then rel = "/" end
        return rel
    end
    return full_path
end

--- Format file size for display
function FileOps:_formatSize(size)
    if size < 1024 then
        return size .. " B"
    elseif size < 1024 * 1024 then
        return string.format("%.1f KB", size / 1024)
    elseif size < 1024 * 1024 * 1024 then
        return string.format("%.1f MB", size / (1024 * 1024))
    else
        return string.format("%.1f GB", size / (1024 * 1024 * 1024))
    end
end

--- Detect MIME type from extension
function FileOps:_getMimeType(filename)
    local ext = filename:match("%.([^%.]+)$")
    if not ext then return "application/octet-stream" end
    ext = ext:lower()

    local mime_types = {
        -- Ebook formats
        epub = "application/epub+zip",
        pdf = "application/pdf",
        mobi = "application/x-mobipocket-ebook",
        azw = "application/vnd.amazon.ebook",
        azw3 = "application/vnd.amazon.ebook",
        fb2 = "application/x-fictionbook+xml",
        djvu = "image/vnd.djvu",
        cbz = "application/x-cbz",
        cbr = "application/x-cbr",
        -- Text
        txt = "text/plain",
        html = "text/html",
        htm = "text/html",
        css = "text/css",
        js = "application/javascript",
        json = "application/json",
        xml = "application/xml",
        -- Documents
        doc = "application/msword",
        docx = "application/vnd.openxmlformats-officedocument.wordprocessingml.document",
        rtf = "application/rtf",
        -- Images
        png = "image/png",
        jpg = "image/jpeg",
        jpeg = "image/jpeg",
        gif = "image/gif",
        svg = "image/svg+xml",
        -- Archives
        zip = "application/zip",
        gz = "application/gzip",
        tar = "application/x-tar",
    }

    return mime_types[ext] or "application/octet-stream"
end

--- Get file type category
function FileOps:_getFileType(filename)
    local ext = filename:match("%.([^%.]+)$")
    if not ext then return "file" end
    ext = ext:lower()

    local ebook_exts = {epub=true, pdf=true, mobi=true, azw=true, azw3=true, fb2=true, djvu=true, cbz=true, cbr=true, kfx=true}
    local doc_exts = {txt=true, doc=true, docx=true, rtf=true, html=true, htm=true, md=true}
    local image_exts = {png=true, jpg=true, jpeg=true, gif=true, svg=true, bmp=true}

    if ebook_exts[ext] then return "ebook"
    elseif doc_exts[ext] then return "document"
    elseif image_exts[ext] then return "image"
    else return "file"
    end
end

--- Check if a filename has a safe mode whitelisted extension
function FileOps:isExtensionSafe(filename)
    if not filename then return false end
    -- Check compound extension first (e.g. "fb2.zip")
    local compound_ext = filename:match("%.([^/]+%.[^%.]+)$")
    if compound_ext and SAFE_MODE_EXTENSIONS[compound_ext:lower()] then
        return true
    end
    local ext = filename:match("%.([^%.]+)$")
    if not ext then return false end
    return SAFE_MODE_EXTENSIONS[ext:lower()] == true
end

--- List directory contents
function FileOps:listDirectory(rel_path, sort_by, sort_order, filter, safe_mode)
    local full_path, err = self:_resolvePath(rel_path)
    if not full_path then
        return nil, err
    end

    local attr = lfs.attributes(full_path)
    if not attr or attr.mode ~= "directory" then
        return nil, "Not a directory"
    end

    local entries = {}
    local ok, iter_err = pcall(function()
        for name in lfs.dir(full_path) do
            if name ~= "." and name ~= ".." then
                -- Skip hidden files starting with .
                if name:sub(1, 1) ~= "." then
                    -- Apply filter if present
                    local include = true
                    if filter and filter ~= "" then
                        include = name:lower():find(filter:lower(), 1, true) ~= nil
                    end

                    if include then
                        local entry_path = full_path .. "/" .. name
                        local entry_attr = lfs.attributes(entry_path)
                        if entry_attr then
                            local is_dir = entry_attr.mode == "directory"
                            -- Apply safe mode filter: only dirs and whitelisted extensions
                            if safe_mode and not is_dir and not self:isExtensionSafe(name) then
                                -- skip non-whitelisted file
                            elseif safe_mode and is_dir and name:match("%.sdr$") then
                                -- skip .sdr metadata directories in safe mode
                            else
                                local entry = {
                                    name = name,
                                    path = self:_getRelativePath(entry_path),
                                    is_dir = is_dir,
                                    size = entry_attr.size or 0,
                                    size_formatted = self:_formatSize(entry_attr.size or 0),
                                    modified = entry_attr.modification or 0,
                                    type = is_dir and "directory" or self:_getFileType(name),
                                }
                                -- For non-directory files, check if a corresponding .sdr directory exists
                                if not is_dir then
                                    local sdr_attr = lfs.attributes(entry_path .. ".sdr")
                                    if sdr_attr and sdr_attr.mode == "directory" then
                                        entry.has_sdr = true
                                    end
                                end
                                table.insert(entries, entry)
                            end
                        end
                    end
                end
            end
        end
    end)

    if not ok then
        return nil, "Cannot read directory: " .. tostring(iter_err)
    end

    -- Sort entries (directories first, then by specified criteria)
    sort_by = sort_by or "name"
    sort_order = sort_order or "asc"

    table.sort(entries, function(a, b)
        -- Directories always come first
        if a.is_dir and not b.is_dir then return true end
        if not a.is_dir and b.is_dir then return false end

        -- For descending, swap a and b so the same < operator works correctly
        -- (using "not result" breaks strict weak ordering for equal values)
        if sort_order == "desc" then
            a, b = b, a
        end

        if sort_by == "name" then
            return a.name:lower() < b.name:lower()
        elseif sort_by == "size" then
            return a.size < b.size
        elseif sort_by == "date" then
            return a.modified < b.modified
        elseif sort_by == "type" then
            if a.type == b.type then
                return a.name:lower() < b.name:lower()
            else
                return a.type < b.type
            end
        else
            return a.name:lower() < b.name:lower()
        end
    end)

    -- Build breadcrumbs
    local breadcrumbs = {{name = "Home", path = "/"}}
    if rel_path and rel_path ~= "/" then
        local parts = {}
        for part in rel_path:gmatch("[^/]+") do
            table.insert(parts, part)
        end
        local cumulative = ""
        for _, part in ipairs(parts) do
            cumulative = cumulative .. "/" .. part
            table.insert(breadcrumbs, {name = part, path = cumulative})
        end
    end

    return {
        path = rel_path or "/",
        entries = entries,
        breadcrumbs = breadcrumbs,
        count = #entries,
    }
end

--- Download a file, sending it directly to the client socket
function FileOps:downloadFile(client, rel_path, server)
    local full_path, err = self:_resolvePath(rel_path)
    if not full_path then
        return false, err
    end

    local attr = lfs.attributes(full_path)
    if not attr or attr.mode ~= "file" then
        return false, "Not a file"
    end

    local f = io.open(full_path, "rb")
    if not f then
        return false, "Cannot open file"
    end

    local filename = full_path:match("([^/]+)$") or "download"
    local mime_type = self:_getMimeType(filename)
    local file_size = attr.size

    -- Send headers
    server:sendResponseHeaders(client, 200, {
        ["Content-Type"] = mime_type,
        ["Content-Length"] = tostring(file_size),
        ["Content-Disposition"] = 'attachment; filename="' .. filename .. '"',
        ["Connection"] = "close",
    })

    -- Send file in chunks
    local CHUNK_SIZE = 65536
    while true do
        local chunk = f:read(CHUNK_SIZE)
        if not chunk then break end
        local sent, send_err = client:send(chunk)
        if not sent then
            f:close()
            return false, "Send error: " .. tostring(send_err)
        end
    end

    f:close()
    return true
end

--- Handle multipart file upload
function FileOps:handleUpload(rel_dir, body, boundary)
    local dir_path, err = self:_resolvePath(rel_dir)
    if not dir_path then
        return false, err
    end

    local attr = lfs.attributes(dir_path)
    if not attr or attr.mode ~= "directory" then
        return false, "Upload directory does not exist"
    end

    -- Parse multipart form data
    local delimiter = "--" .. boundary
    local end_delimiter = delimiter .. "--"

    -- Split by boundary
    local parts = {}
    local search_start = 1
    while true do
        local boundary_start = body:find(delimiter, search_start, true)
        if not boundary_start then break end

        local part_start = body:find("\r\n", boundary_start, true)
        if not part_start then break end
        part_start = part_start + 2

        local next_boundary = body:find(delimiter, part_start, true)
        if not next_boundary then break end

        local part_data = body:sub(part_start, next_boundary - 3) -- -3 for preceding \r\n
        table.insert(parts, part_data)
        search_start = next_boundary
    end

    local uploaded_count = 0
    for _, part in ipairs(parts) do
        -- Split headers from body
        local header_end = part:find("\r\n\r\n", 1, true)
        if header_end then
            local headers_str = part:sub(1, header_end - 1)
            local file_data = part:sub(header_end + 4)

            -- Extract filename from Content-Disposition
            local filename = headers_str:match('filename="([^"]+)"')
            if filename and filename ~= "" then
                -- Clean up filename (remove path components from some browsers)
                filename = filename:match("([^/\\]+)$") or filename

                -- Validate filename
                local valid, valid_err = self:_validateFilename(filename)
                if valid then
                    local file_path = dir_path .. "/" .. filename
                    local f = io.open(file_path, "wb")
                    if f then
                        f:write(file_data)
                        f:close()
                        uploaded_count = uploaded_count + 1
                        logger.info("FileSync: Uploaded", filename, "to", dir_path)
                    else
                        logger.warn("FileSync: Cannot write file", file_path)
                    end
                else
                    logger.warn("FileSync: Invalid filename:", filename, valid_err)
                end
            end
        end
    end

    if uploaded_count > 0 then
        return true
    else
        return false, "No files were uploaded"
    end
end

--- Create a directory
function FileOps:createDirectory(rel_path)
    local full_path, err = self:_resolvePath(rel_path)
    if not full_path then
        return false, err
    end

    -- Check parent directory exists
    local parent = full_path:match("(.+)/[^/]+$")
    if parent then
        local parent_attr = lfs.attributes(parent)
        if not parent_attr or parent_attr.mode ~= "directory" then
            return false, "Parent directory does not exist"
        end
    end

    -- Check if already exists
    local attr = lfs.attributes(full_path)
    if attr then
        return false, "Path already exists"
    end

    -- Validate directory name
    local dir_name = full_path:match("([^/]+)$")
    local valid, valid_err = self:_validateFilename(dir_name)
    if not valid then
        return false, valid_err
    end

    local ok, mkdir_err = lfs.mkdir(full_path)
    if not ok then
        return false, "Cannot create directory: " .. tostring(mkdir_err)
    end

    logger.info("FileSync: Created directory", full_path)
    return true
end

--- Rename a file or directory
function FileOps:rename(old_rel_path, new_rel_path)
    local old_path, err1 = self:_resolvePath(old_rel_path)
    if not old_path then
        return false, err1
    end

    local new_path, err2 = self:_resolvePath(new_rel_path)
    if not new_path then
        return false, err2
    end

    -- Check source exists
    local attr = lfs.attributes(old_path)
    if not attr then
        return false, "Source does not exist"
    end

    -- Check destination doesn't exist
    local dest_attr = lfs.attributes(new_path)
    if dest_attr then
        return false, "Destination already exists"
    end

    -- Validate new name
    local new_name = new_path:match("([^/]+)$")
    local valid, valid_err = self:_validateFilename(new_name)
    if not valid then
        return false, valid_err
    end

    local ok, rename_err = os.rename(old_path, new_path)
    if not ok then
        return false, "Cannot rename: " .. tostring(rename_err)
    end

    logger.info("FileSync: Renamed", old_path, "to", new_path)
    return true
end

--- Delete a file or directory (directory must be empty)
--- @param rel_path string: relative path to delete
--- @param options table|nil: optional settings
---   - safe_mode (bool): when true, auto-delete associated .sdr directory for book files
---   - delete_sdr (bool): when true (and not safe_mode), delete associated .sdr directory
function FileOps:delete(rel_path, options)
    local full_path, err = self:_resolvePath(rel_path)
    if not full_path then
        return false, err
    end

    -- Prevent deleting the root directory
    if full_path == self._root_dir then
        return false, "Cannot delete root directory"
    end

    local attr = lfs.attributes(full_path)
    if not attr then
        return false, "Path does not exist"
    end

    local is_file = attr.mode ~= "directory"

    if attr.mode == "directory" then
        -- Recursively delete directory contents
        local ok, del_err = self:_deleteRecursive(full_path)
        if not ok then
            return false, del_err
        end
    else
        local ok, del_err = os.remove(full_path)
        if not ok then
            return false, "Cannot delete file: " .. tostring(del_err)
        end
    end

    logger.info("FileSync: Deleted", full_path)

    -- Handle .sdr metadata directory cleanup for files
    if is_file and options then
        local should_delete_sdr = false
        if options.safe_mode then
            -- In safe mode, always auto-delete the associated .sdr directory
            should_delete_sdr = true
        elseif options.delete_sdr then
            -- Outside safe mode, delete .sdr only if explicitly requested
            should_delete_sdr = true
        end

        if should_delete_sdr then
            local sdr_path = full_path .. ".sdr"
            local sdr_attr = lfs.attributes(sdr_path)
            if sdr_attr and sdr_attr.mode == "directory" then
                local sdr_ok, sdr_err = self:_deleteRecursive(sdr_path)
                if sdr_ok then
                    logger.info("FileSync: Deleted .sdr metadata directory", sdr_path)
                else
                    logger.warn("FileSync: Failed to delete .sdr directory", sdr_path, sdr_err)
                end
            end
        end
    end

    return true
end

--- Recursively delete a directory and its contents
function FileOps:_deleteRecursive(path)
    for name in lfs.dir(path) do
        if name ~= "." and name ~= ".." then
            local entry_path = path .. "/" .. name
            local entry_attr = lfs.attributes(entry_path)
            if entry_attr then
                if entry_attr.mode == "directory" then
                    local ok, err = self:_deleteRecursive(entry_path)
                    if not ok then return false, err end
                else
                    local ok, err = os.remove(entry_path)
                    if not ok then
                        return false, "Cannot delete: " .. tostring(err)
                    end
                end
            end
        end
    end

    local ok, err = lfs.rmdir(path)
    if not ok then
        return false, "Cannot remove directory: " .. tostring(err)
    end
    return true
end

--- Escape a string for safe use in a shell command (wrap in single quotes)
function FileOps:_shellEscape(str)
    if not str then return "''" end
    -- Replace each single quote with: end quote, escaped quote, start quote
    local escaped = str:gsub("'", "'\\''")
    return "'" .. escaped .. "'"
end

--- Try to read metadata from KOReader's .sdr cache directory.
--- Returns a table with title, author, description (or nil if not available).
function FileOps:_readSdrMetadata(full_path)
    local filename = full_path:match("([^/]+)$")
    if not filename then return nil end

    local sdr_dir = full_path .. ".sdr"
    local meta_file = sdr_dir .. "/metadata." .. filename .. ".lua"

    local sdr_attr = lfs.attributes(meta_file)
    if not sdr_attr then return nil end

    local ok, meta = pcall(dofile, meta_file)
    if not ok or type(meta) ~= "table" then return nil end

    local doc_props = meta.doc_props
    if not doc_props or type(doc_props) ~= "table" then return nil end

    local result = {}
    if doc_props.title and doc_props.title ~= "" then
        result.title = doc_props.title
    end
    if doc_props.authors and doc_props.authors ~= "" then
        result.author = doc_props.authors
    end
    if doc_props.description and doc_props.description ~= "" then
        result.description = doc_props.description
    end

    -- Only return if we actually found something
    if result.title or result.author then
        return result
    end
    return nil
end

--- Parse MOBI/AZW3 binary headers and extract metadata.
--- Returns a table with title, author, has_cover, cover_record_index (or nil on failure).
function FileOps:_parseMobiMetadata(full_path)
    local ok, result = pcall(function()
        local f = io.open(full_path, "rb")
        if not f then return nil end

        -- Read first 64KB which covers all headers
        local header_data = f:read(65536)
        if not header_data or #header_data < 78 then
            f:close()
            return nil
        end

        -- PalmDB header: bytes 1-32 = database name (1-based in Lua)
        local pdb_name = header_data:sub(1, 32):match("^([^%z]+)") or ""

        -- Number of records: bytes 77-78 (1-based)
        local num_records = read_uint16_be(header_data, 77)
        if num_records < 1 then
            f:close()
            return nil
        end

        -- Record offset table starts at byte 79 (1-based). Each entry is 8 bytes.
        local record_table_start = 79
        if #header_data < record_table_start + num_records * 8 then
            f:close()
            return nil
        end

        -- Read first record offset
        local first_record_offset = read_uint32_be(header_data, record_table_start)

        -- We need to read the first record. If it's beyond our buffer, seek and read more.
        local record_data
        if first_record_offset + 4096 <= #header_data then
            -- First record is within our buffer; extract from there onward
            record_data = header_data:sub(first_record_offset + 1)
        else
            -- Seek to the first record and read enough data
            f:seek("set", first_record_offset)
            record_data = f:read(65536)
        end

        if not record_data or #record_data < 132 then
            f:close()
            return nil
        end

        -- PalmDOC header is first 16 bytes of the record.
        -- MOBI header starts at byte 17 (offset 16 within record, 1-based = 17)
        local mobi_start = 17

        -- Verify "MOBI" identifier at mobi_start
        local mobi_id = record_data:sub(mobi_start, mobi_start + 3)
        if mobi_id ~= "MOBI" then
            f:close()
            return nil
        end

        -- MOBI header length
        local mobi_header_length = read_uint32_be(record_data, mobi_start + 4)

        -- Full title offset and length (relative to record start, 0-based)
        -- At mobi_start + 84 and mobi_start + 88 (0-based offsets 84, 88 within MOBI header)
        local full_title_offset = read_uint32_be(record_data, mobi_start + 84)
        local full_title_length = read_uint32_be(record_data, mobi_start + 88)

        -- EXTH flags at mobi_start + 96 (offset 96 within MOBI header portion)
        local exth_flags = read_uint32_be(record_data, mobi_start + 96)
        local has_exth = (exth_flags % 128) >= 64 -- bit 6

        -- First image record index at mobi_start + 108
        local first_image_record = nil
        if #record_data >= mobi_start + 111 then
            first_image_record = read_uint32_be(record_data, mobi_start + 108)
        end

        -- Extract the full title from the record
        local full_title = nil
        -- full_title_offset is relative to record start (0-based), convert to 1-based
        local title_start = full_title_offset + 1
        if full_title_length > 0 and full_title_length < 1024 and
           title_start + full_title_length - 1 <= #record_data then
            full_title = record_data:sub(title_start, title_start + full_title_length - 1)
        end

        -- Parse EXTH header if present
        local exth_title = nil
        local author = nil
        local cover_offset = nil
        local thumb_offset = nil

        if has_exth then
            -- EXTH header follows the MOBI header
            local exth_start = mobi_start + mobi_header_length
            if exth_start + 12 <= #record_data then
                local exth_id = record_data:sub(exth_start, exth_start + 3)
                if exth_id == "EXTH" then
                    local exth_record_count = read_uint32_be(record_data, exth_start + 8)

                    local pos = exth_start + 12
                    for _ = 1, exth_record_count do
                        if pos + 8 > #record_data then break end
                        local rec_type = read_uint32_be(record_data, pos)
                        local rec_length = read_uint32_be(record_data, pos + 4)
                        if rec_length < 8 then break end -- malformed

                        local data_length = rec_length - 8
                        local rec_data = nil
                        if data_length > 0 and pos + 7 + data_length <= #record_data then
                            rec_data = record_data:sub(pos + 8, pos + 7 + data_length)
                        end

                        if rec_type == 100 and rec_data then
                            -- Author
                            author = rec_data:gsub("^%s+", ""):gsub("%s+$", "")
                        elseif rec_type == 503 and rec_data then
                            -- Updated title (preferred)
                            exth_title = rec_data:gsub("^%s+", ""):gsub("%s+$", "")
                        elseif rec_type == 201 and rec_data and #rec_data >= 4 then
                            -- Cover offset (index relative to first image record)
                            cover_offset = read_uint32_be(rec_data, 1)
                        elseif rec_type == 202 and rec_data and #rec_data >= 4 then
                            -- Thumbnail offset
                            thumb_offset = read_uint32_be(rec_data, 1)
                        end

                        pos = pos + rec_length
                    end
                end
            end
        end

        f:close()

        -- Build result: prefer EXTH title > full title > PDB name
        local title = exth_title
        if (not title or title == "") and full_title and full_title ~= "" then
            title = full_title
        end
        if (not title or title == "") and pdb_name ~= "" then
            title = pdb_name:gsub("_", " ")
        end

        local meta = {}
        if title and title ~= "" then meta.title = title end
        if author and author ~= "" then meta.author = author end

        -- Compute cover record index (absolute PDB record number)
        if cover_offset and first_image_record then
            meta.has_cover = true
            meta.cover_record_index = first_image_record + cover_offset
        elseif thumb_offset and first_image_record then
            meta.has_cover = true
            meta.cover_record_index = first_image_record + thumb_offset
        end

        -- Store record info needed for cover extraction
        meta.num_records = num_records

        return meta
    end)

    if ok and result then
        return result
    end
    return nil
end

--- Extract cover image data from a MOBI/AZW3 file.
--- Returns image_data, content_type (or nil, error_message).
function FileOps:_extractMobiCover(full_path)
    local ok, img_data, content_type = pcall(function()
        -- First parse metadata to find the cover record index
        local meta = self:_parseMobiMetadata(full_path)
        if not meta or not meta.has_cover or not meta.cover_record_index then
            return nil, nil
        end

        local cover_index = meta.cover_record_index
        local num_records = meta.num_records

        if cover_index < 0 or cover_index >= num_records then
            return nil, nil
        end

        local f = io.open(full_path, "rb")
        if not f then return nil, nil end

        -- Re-read the PDB header to get record offsets
        -- We need record_table_start (byte 79) and the cover record's offset
        f:seek("set", 76)
        local num_rec_bytes = f:read(2)
        if not num_rec_bytes or #num_rec_bytes < 2 then
            f:close()
            return nil, nil
        end

        -- Read the record offset table entries we need
        -- We need the offset for cover_index and cover_index+1 (to know record size)
        local record_table_file_offset = 78 -- 0-based file offset for record table
        local entry_offset = record_table_file_offset + cover_index * 8

        f:seek("set", entry_offset)
        -- Read this record's offset (4 bytes) + attributes (4 bytes) + next record's offset (4 bytes)
        local entry_data = f:read(12)
        if not entry_data or #entry_data < 4 then
            f:close()
            return nil, nil
        end

        local record_offset = read_uint32_be(entry_data, 1)

        -- Determine record size: difference to next record, or read to a limit
        local record_size
        if #entry_data >= 12 and cover_index + 1 < num_records then
            local next_offset = read_uint32_be(entry_data, 9)
            record_size = next_offset - record_offset
        else
            -- Last record or can't determine size: read up to 2MB (generous limit for cover)
            record_size = 2 * 1024 * 1024
        end

        -- Sanity check
        if record_size <= 0 or record_size > 5 * 1024 * 1024 then
            f:close()
            return nil, nil
        end

        -- Seek to the record and read the image data
        f:seek("set", record_offset)
        local data = f:read(record_size)
        f:close()

        if not data or #data < 4 then
            return nil, nil
        end

        -- Detect image type from magic bytes
        local ctype = "image/jpeg" -- default
        local b1, b2, b3, b4 = string.byte(data, 1, 4)
        if b1 == 0xFF and b2 == 0xD8 then
            ctype = "image/jpeg"
        elseif b1 == 0x89 and data:sub(2, 4) == "PNG" then
            ctype = "image/png"
        elseif data:sub(1, 4) == "GIF8" then
            ctype = "image/gif"
        elseif data:sub(1, 4) == "RIFF" and #data >= 12 and data:sub(9, 12) == "WEBP" then
            ctype = "image/webp"
        end

        return data, ctype
    end)

    if ok and img_data then
        return img_data, content_type
    end
    return nil, "Cannot extract cover from MOBI/AZW3"
end

--- Quick check whether an EPUB file has a cover image (for .sdr cache path).
--- Returns true/false.
function FileOps:_epubHasCover(full_path)
    local ok, has = pcall(function()
        local escaped_path = self:_shellEscape(full_path)
        local container_cmd = "unzip -p " .. escaped_path .. " META-INF/container.xml 2>/dev/null"
        local container_handle = io.popen(container_cmd)
        if not container_handle then return false end
        local container_xml = container_handle:read("*all")
        container_handle:close()
        if not container_xml or #container_xml == 0 then return false end

        local opf_path = container_xml:match('full%-path="([^"]+)"')
        if not opf_path then return false end

        local opf_cmd = "unzip -p " .. escaped_path .. " " .. self:_shellEscape(opf_path) .. " 2>/dev/null"
        local opf_handle = io.popen(opf_cmd)
        if not opf_handle then return false end
        local opf_content = opf_handle:read("*all")
        opf_handle:close()
        if not opf_content or #opf_content == 0 then return false end

        -- Check for cover via meta element
        local cover_id = opf_content:match('<meta[^>]*name="cover"[^>]*content="([^"]+)"')
        if not cover_id then
            cover_id = opf_content:match('<meta[^>]*content="([^"]+)"[^>]*name="cover"')
        end
        if cover_id then return true end

        -- Check for items with cover-like id and image media-type
        for item in opf_content:gmatch('<item[^>]+/?>') do
            local item_id = item:match('id="([^"]+)"')
            local media = item:match('media%-type="([^"]+)"')
            if item_id and media and item_id:lower():find("cover") and media:match("^image/") then
                return true
            end
        end
        return false
    end)
    return ok and has
end

--- Get metadata for a file
function FileOps:getMetadata(rel_path)
    local full_path, err = self:_resolvePath(rel_path)
    if not full_path then
        return nil, err
    end

    local attr = lfs.attributes(full_path)
    if not attr then
        return nil, "File does not exist"
    end

    local filename = full_path:match("([^/]+)$") or ""
    local extension = filename:match("%.([^%.]+)$") or ""

    local result = {
        name = filename,
        size = attr.size or 0,
        size_formatted = self:_formatSize(attr.size or 0),
        modified = attr.modification or 0,
        type = attr.mode == "directory" and "directory" or self:_getFileType(filename),
        extension = extension:lower(),
    }

    -- Step 1: Try KOReader's .sdr metadata cache first (works for any format)
    if attr.mode == "file" then
        local sdr_meta = self:_readSdrMetadata(full_path)
        if sdr_meta then
            if sdr_meta.title then result.title = sdr_meta.title end
            if sdr_meta.author then result.author = sdr_meta.author end
            if sdr_meta.description then result.description = sdr_meta.description end
            -- For MOBI/AZW3, still check if cover exists in the binary
            if MOBI_EXTENSIONS[extension:lower()] then
                local mobi_meta = self:_parseMobiMetadata(full_path)
                if mobi_meta and mobi_meta.has_cover then
                    result.has_cover = true
                end
            elseif extension:lower() == "epub" then
                -- For EPUB with .sdr cache, still check for cover in the OPF
                result.has_cover = self:_epubHasCover(full_path)
            end
        end
    end

    -- Step 2: For EPUB files without .sdr cache data, extract from OPF
    if not result.title and extension:lower() == "epub" and attr.mode == "file" then
        local escaped_path = self:_shellEscape(full_path)
        -- Try to find the OPF file path from container.xml
        local container_cmd = "unzip -p " .. escaped_path .. " META-INF/container.xml 2>/dev/null"
        local container_handle = io.popen(container_cmd)
        if container_handle then
            local container_xml = container_handle:read("*all")
            container_handle:close()

            if container_xml and #container_xml > 0 then
                -- Extract the rootfile path from container.xml
                local opf_path = container_xml:match('full%-path="([^"]+)"')
                if opf_path then
                    local opf_cmd = "unzip -p " .. escaped_path .. " " .. self:_shellEscape(opf_path) .. " 2>/dev/null"
                    local opf_handle = io.popen(opf_cmd)
                    if opf_handle then
                        local opf_content = opf_handle:read("*all")
                        opf_handle:close()

                        if opf_content and #opf_content > 0 then
                            -- Extract title
                            local title = opf_content:match("<dc:title[^>]*>([^<]+)</dc:title>")
                            if title then
                                result.title = title:gsub("^%s+", ""):gsub("%s+$", "")
                            end

                            -- Extract author/creator
                            local author = opf_content:match("<dc:creator[^>]*>([^<]+)</dc:creator>")
                            if author then
                                result.author = author:gsub("^%s+", ""):gsub("%s+$", "")
                            end

                            -- Check for cover image
                            -- Method 1: Look for <meta name="cover" content="cover-id"/>
                            local cover_id = opf_content:match('<meta[^>]*name="cover"[^>]*content="([^"]+)"')
                            if not cover_id then
                                cover_id = opf_content:match('<meta[^>]*content="([^"]+)"[^>]*name="cover"')
                            end
                            if cover_id then
                                -- Check that the item with this id exists and is an image
                                local item_pattern = '<item[^>]*id="' .. cover_id:gsub("([%(%)%.%%%+%-%*%?%[%]%^%$])", "%%%1") .. '"[^>]*/>'
                                local cover_item = opf_content:match(item_pattern)
                                if not cover_item then
                                    -- Try non-self-closing item tag
                                    item_pattern = '<item[^>]*id="' .. cover_id:gsub("([%(%)%.%%%+%-%*%?%[%]%^%$])", "%%%1") .. '"[^>]*>'
                                    cover_item = opf_content:match(item_pattern)
                                end
                                if cover_item then
                                    result.has_cover = true
                                end
                            end

                            -- Method 2: Look for items with id containing "cover" and image media-type
                            if not result.has_cover then
                                for item in opf_content:gmatch('<item[^>]+>') do
                                    local item_id = item:match('id="([^"]+)"')
                                    local media = item:match('media%-type="([^"]+)"')
                                    if item_id and media and item_id:lower():find("cover") and media:match("^image/") then
                                        result.has_cover = true
                                        break
                                    end
                                end
                                -- Also check self-closing items
                                if not result.has_cover then
                                    for item in opf_content:gmatch('<item[^>]+/>') do
                                        local item_id = item:match('id="([^"]+)"')
                                        local media = item:match('media%-type="([^"]+)"')
                                        if item_id and media and item_id:lower():find("cover") and media:match("^image/") then
                                            result.has_cover = true
                                            break
                                        end
                                    end
                                end
                            end
                        end
                    end
                end
            end
        end
    end

    -- Step 3: For MOBI/AZW3 files without .sdr cache data, parse binary headers
    if not result.title and MOBI_EXTENSIONS[extension:lower()] and attr.mode == "file" then
        local mobi_meta = self:_parseMobiMetadata(full_path)
        if mobi_meta then
            if mobi_meta.title then result.title = mobi_meta.title end
            if mobi_meta.author then result.author = mobi_meta.author end
            if mobi_meta.has_cover then result.has_cover = true end
        end
    end

    -- Fallback: parse title/author from filename "Title - Author.ext" pattern
    if not result.title then
        local name_without_ext = filename:match("^(.+)%.[^%.]+$") or filename
        local title_part, author_part = name_without_ext:match("^(.+)%s+%-%s+(.+)$")
        if title_part then
            result.title = title_part
            if not result.author then
                result.author = author_part
            end
        else
            result.title = name_without_ext
        end
    end

    return result
end

--- Extract and stream cover image from an ebook file (EPUB, MOBI, AZW3)
function FileOps:getBookCover(client, rel_path, server)
    local full_path, err = self:_resolvePath(rel_path)
    if not full_path then
        return false, err
    end

    local attr = lfs.attributes(full_path)
    if not attr or attr.mode ~= "file" then
        return false, "Not a file"
    end

    local extension = full_path:match("%.([^%.]+)$")
    if not extension then
        return false, "No file extension"
    end
    extension = extension:lower()

    -- MOBI/AZW3 cover extraction
    if MOBI_EXTENSIONS[extension] then
        local img_data, content_type = self:_extractMobiCover(full_path)
        if not img_data then
            return false, content_type or "Cover not found in MOBI/AZW3"
        end

        server:sendResponseHeaders(client, 200, {
            ["Content-Type"] = content_type,
            ["Content-Length"] = tostring(#img_data),
            ["Cache-Control"] = "public, max-age=86400",
            ["Connection"] = "close",
        })

        local sent, send_err = client:send(img_data)
        if not sent then
            return false, "Send error: " .. tostring(send_err)
        end
        return true
    end

    -- EPUB cover extraction
    if extension ~= "epub" then
        return false, "Cover extraction not supported for this format"
    end

    local escaped_path = self:_shellEscape(full_path)

    -- Read container.xml to find OPF path
    local container_cmd = "unzip -p " .. escaped_path .. " META-INF/container.xml 2>/dev/null"
    local container_handle = io.popen(container_cmd)
    if not container_handle then
        return false, "Cannot read EPUB"
    end
    local container_xml = container_handle:read("*all")
    container_handle:close()

    if not container_xml or #container_xml == 0 then
        return false, "Invalid EPUB: no container.xml"
    end

    local opf_path = container_xml:match('full%-path="([^"]+)"')
    if not opf_path then
        return false, "Invalid EPUB: no OPF path"
    end

    -- Determine the OPF directory for resolving relative paths
    local opf_dir = opf_path:match("(.+)/[^/]+$") or ""

    -- Read OPF content
    local opf_cmd = "unzip -p " .. escaped_path .. " " .. self:_shellEscape(opf_path) .. " 2>/dev/null"
    local opf_handle = io.popen(opf_cmd)
    if not opf_handle then
        return false, "Cannot read OPF"
    end
    local opf_content = opf_handle:read("*all")
    opf_handle:close()

    if not opf_content or #opf_content == 0 then
        return false, "Invalid EPUB: empty OPF"
    end

    local cover_href = nil
    local cover_media_type = nil

    -- Method 1: Find cover meta element and look up the item by ID
    local cover_id = opf_content:match('<meta[^>]*name="cover"[^>]*content="([^"]+)"')
    if not cover_id then
        cover_id = opf_content:match('<meta[^>]*content="([^"]+)"[^>]*name="cover"')
    end

    if cover_id then
        local escaped_id = cover_id:gsub("([%(%)%.%%%+%-%*%?%[%]%^%$])", "%%%1")
        -- Search both self-closing and regular item tags
        for item in opf_content:gmatch('<item[^>]+/?>') do
            local item_id = item:match('id="([^"]+)"')
            if item_id == cover_id then
                cover_href = item:match('href="([^"]+)"')
                cover_media_type = item:match('media%-type="([^"]+)"')
                break
            end
        end
    end

    -- Method 2: Look for items with id containing "cover" and image media-type
    if not cover_href then
        for item in opf_content:gmatch('<item[^>]+/?>') do
            local item_id = item:match('id="([^"]+)"')
            local media = item:match('media%-type="([^"]+)"')
            local href = item:match('href="([^"]+)"')
            if item_id and media and href and item_id:lower():find("cover") and media:match("^image/") then
                cover_href = href
                cover_media_type = media
                break
            end
        end
    end

    if not cover_href then
        return false, "Cover not found"
    end

    -- Resolve href relative to OPF directory
    local cover_path_in_epub
    if opf_dir ~= "" then
        cover_path_in_epub = opf_dir .. "/" .. cover_href
    else
        cover_path_in_epub = cover_href
    end

    -- URL-decode the path (EPUB paths may contain %20 etc.)
    cover_path_in_epub = cover_path_in_epub:gsub("%%(%x%x)", function(h)
        return string.char(tonumber(h, 16))
    end)

    -- Determine MIME type from cover_media_type or extension
    if not cover_media_type or cover_media_type == "" then
        local cover_ext = cover_href:match("%.([^%.]+)$")
        if cover_ext then
            cover_ext = cover_ext:lower()
            local mime_map = {
                jpg = "image/jpeg", jpeg = "image/jpeg",
                png = "image/png", gif = "image/gif",
                svg = "image/svg+xml", webp = "image/webp",
            }
            cover_media_type = mime_map[cover_ext] or "image/jpeg"
        else
            cover_media_type = "image/jpeg"
        end
    end

    -- Extract the cover image
    local extract_cmd = "unzip -p " .. escaped_path .. " " .. self:_shellEscape(cover_path_in_epub) .. " 2>/dev/null"
    local img_handle = io.popen(extract_cmd)
    if not img_handle then
        return false, "Cannot extract cover image"
    end
    local img_data = img_handle:read("*all")
    img_handle:close()

    if not img_data or #img_data == 0 then
        return false, "Cover image is empty"
    end

    -- Stream the cover image to the client
    server:sendResponseHeaders(client, 200, {
        ["Content-Type"] = cover_media_type,
        ["Content-Length"] = tostring(#img_data),
        ["Cache-Control"] = "public, max-age=86400",
        ["Connection"] = "close",
    })

    local sent, send_err = client:send(img_data)
    if not sent then
        return false, "Send error: " .. tostring(send_err)
    end

    return true
end

return FileOps
