--- File operations module for the FileSync plugin.
--- Handles directory listing, file upload/download, rename, delete, metadata extraction
--- (EPUB OPF parsing), and cover image extraction.
--- MOBI/AZW3 binary header parsing is delegated to filesync/mobi.
---
--- Key dependencies: lfs (LuaFileSystem), filesync/utils, filesync/mobi
--- Note: EPUB metadata extraction shells out to `unzip` via io.popen.

-- Try standard require first, then KOReader's internal path
local ok, lfs = pcall(require, "lfs")
if not ok then
    ok, lfs = pcall(require, "libs/libkoreader-lfs")
end
if not ok then
    error("FileSync: cannot load LFS filesystem module")
end
local Utils = require("filesync/utils")
local Mobi = require("filesync/mobi")
local logger = require("logger")

local SAFE_MODE_EXTENSIONS = {
    epub = true, pdf = true, mobi = true, azw = true, azw3 = true,
    fb2 = true, ["fb2.zip"] = true, djvu = true, cbz = true, cbr = true, kfx = true,
    txt = true, doc = true, docx = true, rtf = true,
    html = true, htm = true, md = true, chm = true, pdb = true, prc = true, lit = true,
    jpg = true, jpeg = true, png = true, gif = true, webp = true,
}

--- MOBI/AZW3 extensions lookup (re-exported from Mobi module for local use)
local MOBI_EXTENSIONS = Mobi.EXTENSIONS

local FileOps = {
    _root_dir = "/mnt/us",
}

function FileOps:new(o)
    o = o or {}
    setmetatable(o, self)
    self.__index = self
    return o
end

function FileOps:setRootDir(dir)
    self._root_dir = dir
end

--- Register a function returning the extra storage locations of this device
--- (an SD card, say). It is called once per request, so a card inserted or
--- removed while the server runs is picked up. Each item looks like
--- {id = "sd", name = "SD card", path = "/mnt/sd"} and is reached by clients
--- under "/@<id>"; `path` is nil while the location is absent (card removed).
--- The internal root is always available and is not part of this list.
--- @param provider function|nil
function FileOps:setExtraRootsProvider(provider)
    self._extra_roots_provider = provider
end

-- Drop trailing slashes, keeping a lone "/".
local function trimSlashes(path)
    path = path:gsub("/+$", "")
    if path == "" then return "/" end
    return path
end

--- Storage locations of this device, as they are right now.
--- `prefix` is the root as clients see it: "/" for the internal root (paths
--- are unprefixed, as they always were) and "/@<id>" for the others.
--- @return table: available locations, the internal one first: list of
---   {id = string, path = string, prefix = string, name = string|nil}
--- @return table: locations this device has but that are absent right now,
---   as {[id] = name or false}
function FileOps:getRoots()
    local internal_path = self._root_dir and trimSlashes(self._root_dir)
    local roots = {{id = "internal", path = internal_path, prefix = "/"}}
    local absent = {}
    if self._extra_roots_provider then
        local ok, extra = pcall(self._extra_roots_provider)
        if ok and type(extra) == "table" then
            for _, r in ipairs(extra) do
                if type(r) == "table" and type(r.id) == "string" and r.id ~= ""
                    and r.id ~= "internal" and not r.id:find("/", 1, true) then
                    local name = type(r.name) == "string" and r.name or nil
                    if type(r.path) == "string" and r.path ~= "" then
                        table.insert(roots, {id = r.id, path = trimSlashes(r.path),
                            prefix = "/@" .. r.id, name = name})
                    else
                        absent[r.id] = name or false
                    end
                end
            end
        end
    end
    return roots, absent
end

--- Public description of the roots, or nil when there is only one. Only a
--- device with an extra storage location present sees this, so everything
--- else keeps the exact responses it always had.
--- @param roots table|nil: result of getRoots(), to reuse within a request
--- @return table|nil: list of {id = string, path = string}
function FileOps:describeRoots(roots)
    roots = roots or self:getRoots()
    if #roots < 2 then return nil end
    local out = {}
    for _, r in ipairs(roots) do
        table.insert(out, {id = r.id, path = r.prefix})
    end
    return out
end

--- Resolve and validate a path, preventing path traversal.
--- A path starting with "/@<id>" (for example "/@sd") lives on that extra
--- storage location, and is refused while the location is absent;
--- "/@internal" names the internal storage explicitly, and any other path is
--- on the internal storage.
--- @return string|nil: the full absolute path, or nil on error
--- @return table|string: the root it belongs to (see getRoots), or the error message
--- @return table|nil: every available root, so the caller does not detect them again
function FileOps:_resolve(rel_path)
    if not rel_path or rel_path == "" then
        rel_path = "/"
    end

    -- Normalize: collapse double slashes. Whitespace is deliberately kept:
    -- on case-sensitive filesystems (ext4 on 2024+ Kindles) a folder named
    -- "Books " is distinct from "Books", and trimming here would make a
    -- folder that appears in a listing impossible to open (#46).
    rel_path = rel_path:gsub("//+", "/")

    -- Block path traversal
    if rel_path:match("%.%.") then
        return nil, "Path traversal not allowed"
    end

    -- Ensure it starts with /
    if rel_path:sub(1, 1) ~= "/" then
        rel_path = "/" .. rel_path
    end

    -- Pick the root: a reserved "@<id>" first segment selects that storage
    -- location; anything else is internal storage.
    local roots, absent = self:getRoots()
    local root = roots[1]
    local inner = rel_path
    local id = rel_path:match("^/@([^/]+)")
    if id then
        if absent[id] ~= nil then
            -- Never fall back to the internal storage here: a request meant
            -- for a removed card would otherwise write there (mkdir -p).
            return nil, (absent[id] or ("@" .. id)) .. " not available"
        end
        for _, candidate in ipairs(roots) do
            if candidate.id == id then
                root = candidate
                inner = rel_path:sub(#id + 3)
                if inner == "" then inner = "/" end
                break
            end
        end
    end

    local full_path = root.path .. inner

    -- Normalize again after combining
    full_path = full_path:gsub("//+", "/")

    -- Remove trailing slash (except for root)
    if #full_path > 1 and full_path:sub(-1) == "/" then
        full_path = full_path:sub(1, -2)
    end

    -- Verify the resolved path is under the root
    if full_path:sub(1, #root.path) ~= root.path then
        return nil, "Access denied: path outside root directory"
    end

    return full_path, root, roots
end

--- Same as _resolve, for callers that only need the absolute path.
--- Returns the full absolute path, or nil and an error message.
function FileOps:_resolvePath(rel_path)
    local full_path, root_or_err = self:_resolve(rel_path)
    if not full_path then
        return nil, root_or_err
    end
    return full_path
end

--- Check that a resolved path exists and is a directory.
--- Reports the underlying reason on failure (missing path, stat error, or a
--- file where a directory was expected) instead of a generic message.
--- @param full_path string: absolute path from _resolvePath
--- @param rel_path string: path as the caller supplied it, used in messages
--- @return boolean: true when full_path is a directory
--- @return string|nil: error message on failure
function FileOps:_checkDirectory(full_path, rel_path)
    local attr, attr_err = lfs.attributes(full_path)
    if not attr then
        -- lfs phrases errors as "cannot obtain information from file `<abs>': <reason>";
        -- keep only the reason so the absolute root path is not echoed to clients.
        local reason = attr_err and tostring(attr_err):match(":%s*([^:]+)$") or attr_err
        if reason and reason ~= "" then
            return false, "Cannot open " .. rel_path .. ": " .. reason
        end
        return false, "Cannot open " .. rel_path .. ": path does not exist"
    end
    if attr.mode ~= "directory" then
        return false, "Not a directory: " .. rel_path
    end
    return true
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

--- Path clients use for an absolute path: relative to the storage location
--- holding it (the most specific one wins), with its "/@<id>" prefix when
--- that is not the internal storage.
--- @param full_path string: absolute path
--- @param roots table|nil: result of getRoots() (or a subset), to reuse within a request
--- @return string|nil: nil when full_path is outside every location
function FileOps:clientPath(full_path, roots)
    if type(full_path) ~= "string" or full_path == "" then return nil end
    local best = nil
    for _, r in ipairs(roots or self:getRoots()) do
        local p = r.path
        if p and (p == "/" or full_path == p or full_path:sub(1, #p + 1) == p .. "/") then
            if not best or #p > #best.path then best = r end
        end
    end
    if not best then return nil end
    local rel = best.path == "/" and full_path or full_path:sub(#best.path + 1)
    if rel == "" then rel = "/" end
    if best.id == "internal" then
        return rel
    end
    return best.prefix .. (rel == "/" and "" or rel)
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
        webp = "image/webp",
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
    local image_exts = {png=true, jpg=true, jpeg=true, gif=true, svg=true, bmp=true, webp=true}

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

-- ============================================================================
-- In-browser text editor support (read/write text-like files)
-- ============================================================================

-- Maximum size (bytes) of a file the editor will open/save.
-- Kept under the 1 MB JSON body limit in httpserver.lua so saves always fit.
local MAX_EDIT_SIZE = 256 * 1024 -- 256 KB

--- Guess whether file content is text (UTF-8/ASCII) rather than binary.
--- A file is considered binary if a NUL byte appears within the first
--- 'sample_bytes' bytes. This is a cheap heuristic that is safe for the
--- encodings KOReader devices typically hold (UTF-8/ASCII/Latin-1).
--- @param content string: file content (at least a sample)
--- @param sample_bytes number|nil: how many leading bytes to inspect
--- @return boolean: true when the content looks like text
function FileOps:_looksLikeText(content, sample_bytes)
    if not content then return true end
    local limit = sample_bytes or 8000
    if #content < limit then limit = #content end
    for i = 1, limit do
        if string.byte(content, i) == 0 then
            return false
        end
    end
    return true
end

--- Read a text file's content for the in-browser editor.
--- Enforces a size cap (files above MAX_EDIT_SIZE stay download-only) and
--- rejects binary content so the editor never loads garbage.
--- @param rel_path string: relative path from root_dir
--- @return table|nil: {content = string, name = string, editable = boolean} on success
--- @return string|nil: error message on failure
function FileOps:readTextFile(rel_path)
    local full_path, err = self:_resolvePath(rel_path)
    if not full_path then
        return nil, err
    end

    local attr = lfs.attributes(full_path)
    if not attr or attr.mode ~= "file" then
        return nil, "Not a file"
    end

    if attr.size > MAX_EDIT_SIZE then
        return nil, "File is too large to edit"
    end

    local f = io.open(full_path, "rb")
    if not f then
        return nil, "Cannot open file"
    end

    local content = f:read("*a")
    f:close()

    if not content then
        return nil, "Cannot read file"
    end

    -- Reject binary content (NUL byte in the head sample). Binary files keep
    -- today's download-only behaviour and never reach the text editor.
    if not self:_looksLikeText(content) then
        return nil, "Binary file cannot be opened in the editor"
    end

    local filename = full_path:match("([^/]+)$") or "file"

    return {
        content = content,
        name = filename,
        -- Any file that passed the binary/size checks above is text, so it is
        -- editable — regardless of whether the extension is a "known" code
        -- type. This lets unknown-extension text files (e.g. ".key" that is
        -- actually plain text, ".lua.old", "metadata.calibre", or files with
        -- no extension) be opened and saved. Whether the user may actually
        -- *save* is decided at the route layer (safe mode).
        editable = true,
    }
end

--- Write text content back to a file (in-place save from the editor).
--- Writes directly into the existing file (no temp file + rename) so the
--- original permissions are kept and symlinks write through to their target.
--- @param rel_path string: relative path from root_dir
--- @param content string: full new file content
--- @return boolean: true on success
--- @return string|nil: error message on failure
function FileOps:writeTextFile(rel_path, content)
    if type(content) ~= "string" then
        return false, "Invalid content"
    end

    local full_path, err = self:_resolvePath(rel_path)
    if not full_path then
        return false, err
    end

    -- Only overwrite existing regular files.
    local attr = lfs.attributes(full_path)
    if not attr or attr.mode ~= "file" then
        return false, "Not a file"
    end

    -- Never overwrite the plugin's served web UI (defense in depth).
    local plugin_dir = Utils.getPluginDir()
    local protected_index = plugin_dir ~= "." and (plugin_dir .. "/filesync/static/index.html") or nil
    if protected_index and full_path == protected_index then
        return false, "Protected file"
    end

    -- Write in place (not atomic, but preserves mode and follows symlinks).
    local f, open_err = io.open(full_path, "wb")
    if not f then
        return false, "Cannot write file: " .. tostring(open_err)
    end

    local ok, write_err = f:write(content)
    f:close()

    if not ok then
        return false, "Cannot write file: " .. tostring(write_err)
    end

    logger.info("FileSync: Saved text file", full_path)
    return true
end

--- List directory contents with sorting, filtering, and safe mode enforcement.
--- @param rel_path string: relative path from root_dir
--- @param sort_by string: sort field ("name", "size", "date", "type")
--- @param sort_order string: "asc" or "desc"
--- @param filter string: case-insensitive substring filter for filenames
--- @param safe_mode boolean: when true, only show whitelisted file types and
---   hide dotfiles; when false, list every entry including hidden ones
--- @return table|nil: {path, entries, breadcrumbs, count} on success
--- @return string|nil: error message on failure
function FileOps:listDirectory(rel_path, sort_by, sort_order, filter, safe_mode)
    local full_path, root, roots = self:_resolve(rel_path)
    if not full_path then
        return nil, root
    end

    local is_dir, dir_err = self:_checkDirectory(full_path, rel_path)
    if not is_dir then
        return nil, dir_err
    end

    local entries = {}
    local ok, iter_err = pcall(function()
        for name in lfs.dir(full_path) do
            if name ~= "." and name ~= ".." then
                -- Hidden entries are listed only when safe mode is off
                if not (safe_mode and name:sub(1, 1) == ".") then
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
                                    path = self:clientPath(entry_path, {root}),
                                    is_dir = is_dir,
                                    size = entry_attr.size or 0,
                                    size_formatted = self:_formatSize(entry_attr.size or 0),
                                    modified = entry_attr.modification or 0,
                                    type = is_dir and "directory" or self:_getFileType(name),
                                }
                                -- For directories, check if they are empty
                                if is_dir then
                                    local child_count = 0
                                    for child_name in lfs.dir(entry_path) do
                                        if child_name ~= "." and child_name ~= ".." then
                                            child_count = child_count + 1
                                            break -- only need to know if > 0
                                        end
                                    end
                                    entry.is_empty = (child_count == 0)
                                end
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

    -- Build breadcrumbs: the first item is the root itself, then one item
    -- per folder below it. Paths carry the root's "/@<id>" prefix when it has one.
    local roots_info = self:describeRoots(roots)
    local base = root.id == "internal" and "" or root.prefix
    local breadcrumbs = {{name = root.name or "Home", path = root.prefix}}
    if roots_info then
        breadcrumbs[1].root = root.id
    end
    local inner = full_path:sub(#root.path + 1)
    local cumulative = base
    for part in inner:gmatch("[^/]+") do
        cumulative = cumulative .. "/" .. part
        table.insert(breadcrumbs, {name = part, path = cumulative})
    end

    -- "/@internal" is accepted as input only: answer with the plain path.
    local path = rel_path or "/"
    if root.id == "internal" then
        path = path:gsub("^/*@internal/", "/"):gsub("^/*@internal$", "/")
    end

    local result = {
        path = path,
        entries = entries,
        breadcrumbs = breadcrumbs,
        count = #entries,
    }
    if roots_info then
        result.roots = roots_info
        result.root = root.id
    end
    return result
end

--- Get recursive file count for a directory
function FileOps:getDirInfo(rel_path)
    local full_path, err = self:_resolvePath(rel_path)
    if not full_path then
        return nil, err
    end

    local is_dir, dir_err = self:_checkDirectory(full_path, rel_path)
    if not is_dir then
        return nil, dir_err
    end

    local file_count = self:_countFilesRecursive(full_path)
    return file_count
end

--- Prepare a file for download: validate path, open a file handle, and return metadata.
--- The caller is responsible for streaming from the file handle and closing it.
--- @param rel_path string: relative path from root_dir
--- @param inline boolean|nil: when true, Content-Disposition should be "inline"
--- @return table|nil: {file_handle, size, mime_type, filename, inline} on success
--- @return string|nil: error message on failure
function FileOps:downloadFile(rel_path, inline)
    local full_path, err = self:_resolvePath(rel_path)
    if not full_path then
        return nil, err
    end

    local attr = lfs.attributes(full_path)
    if not attr or attr.mode ~= "file" then
        return nil, "Not a file"
    end

    local f = io.open(full_path, "rb")
    if not f then
        return nil, "Cannot open file"
    end

    local filename = full_path:match("([^/]+)$") or "download"
    local mime_type = self:_getMimeType(filename)

    return {
        file_handle = f,
        size = attr.size,
        mime_type = mime_type,
        filename = filename,
        inline = inline and true or false,
    }
end

--- Handle multipart file upload: parse multipart form data and write files to disk.
--- @param rel_dir string: relative directory path for uploaded files
--- @param body string: raw HTTP request body containing multipart data
--- @param boundary string: multipart boundary string from Content-Type header
--- @return boolean: true on success (at least one file uploaded)
--- @return string|nil: error message on failure
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

                -- Fix iOS Safari appending .zip to EPUB/CBZ files (they are ZIP-based)
                if filename:match("%.epub%.zip$") then
                    filename = filename:gsub("%.zip$", "")
                elseif filename:match("%.cbz%.zip$") then
                    filename = filename:gsub("%.zip$", "")
                end

                -- Validate filename
                local valid, valid_err = self:_validateFilename(filename)
                if valid then
                    local file_path = dir_path .. "/" .. filename
                    local f = io.open(file_path, "wb")
                    if f then
                        local write_ok, write_err = f:write(file_data)
                        f:close()
                        if write_ok then
                            uploaded_count = uploaded_count + 1
                            logger.info("FileSync: Uploaded", filename, "to", dir_path)
                        else
                            logger.warn("FileSync: Write failed for", file_path, write_err)
                            pcall(os.remove, file_path)
                        end
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

--- Create a directory.
--- @param rel_path string: relative path from root_dir
--- @param options table|nil: {recursive = boolean} — when recursive, missing
---   parent directories are created too and an existing directory is not an
---   error (mkdir -p semantics), which is what folder uploads need.
--- @return boolean: true on success
--- @return string|nil: error message on failure
function FileOps:createDirectory(rel_path, options)
    local full_path, root = self:_resolve(rel_path)
    if not full_path then
        return false, root
    end

    local recursive = options and options.recursive

    -- Refuse to create the root itself: there is nothing to make and the
    -- segment walk below would have no name to validate.
    if full_path == root.path then
        return false, "Path already exists"
    end

    -- Check if already exists
    local attr = lfs.attributes(full_path)
    if attr then
        if recursive and attr.mode == "directory" then
            return true
        end
        return false, "Path already exists"
    end

    if recursive then
        return self:_createDirectoryRecursive(full_path, root.path)
    end

    -- Check parent directory exists
    local parent = full_path:match("(.+)/[^/]+$")
    if parent then
        local parent_attr = lfs.attributes(parent)
        if not parent_attr or parent_attr.mode ~= "directory" then
            return false, "Parent directory does not exist"
        end
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

--- Create every missing directory between the root and full_path (mkdir -p).
--- full_path must already be resolved and known not to exist.
--- @param full_path string: absolute path under the root
--- @param root_path string|nil: absolute path of that root (defaults to the internal root)
--- @return boolean: true on success
--- @return string|nil: error message on failure
function FileOps:_createDirectoryRecursive(full_path, root_path)
    root_path = root_path or self._root_dir
    local rel = full_path:sub(#root_path + 1)
    local current = root_path

    for segment in rel:gmatch("[^/]+") do
        local valid, valid_err = self:_validateFilename(segment)
        if not valid then
            return false, valid_err
        end
        current = current .. "/" .. segment
        local attr = lfs.attributes(current)
        if attr then
            if attr.mode ~= "directory" then
                return false, "Path already exists"
            end
        else
            local ok, mkdir_err = lfs.mkdir(current)
            if not ok then
                return false, "Cannot create directory: " .. tostring(mkdir_err)
            end
            logger.info("FileSync: Created directory", current)
        end
    end

    return true
end

--- Rename a file or directory
function FileOps:rename(old_rel_path, new_rel_path)
    local old_path, old_root = self:_resolve(old_rel_path)
    if not old_path then
        return false, old_root
    end

    local new_path, new_root = self:_resolve(new_rel_path)
    if not new_path then
        return false, new_root
    end

    -- Storage locations are separate filesystems: a rename cannot cross them.
    if old_root.id ~= new_root.id then
        return false, "Cannot rename across storage locations"
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

--- Delete a file or directory (directories are deleted recursively)
--- @param rel_path string: relative path to delete
--- @param options table|nil: optional settings
---   - safe_mode (bool): when true, auto-delete associated .sdr directory for book files
---   - delete_sdr (bool): when true (and not safe_mode), delete associated .sdr directory
function FileOps:delete(rel_path, options)
    local full_path, root = self:_resolve(rel_path)
    if not full_path then
        return false, root
    end

    -- Prevent deleting the root directory
    if full_path == root.path then
        return false, "Cannot delete root directory"
    end

    local attr = lfs.attributes(full_path)
    if not attr then
        return false, "Path does not exist"
    end

    local is_file = attr.mode ~= "directory"

    if attr.mode == "directory" then
        local ok, del_err = self:_deleteRecursive(full_path)
        if not ok then
            return false, "Cannot delete directory: " .. tostring(del_err)
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

--- Recursively count all files (not directories) inside a directory tree
function FileOps:_countFilesRecursive(path)
    local count = 0
    local ok, iter_err = pcall(function()
        for name in lfs.dir(path) do
            if name ~= "." and name ~= ".." then
                local entry_path = path .. "/" .. name
                local entry_attr = lfs.attributes(entry_path)
                if entry_attr then
                    if entry_attr.mode == "directory" then
                        count = count + self:_countFilesRecursive(entry_path)
                    else
                        count = count + 1
                    end
                end
            end
        end
    end)
    if not ok then
        logger.warn("FileSync: Error counting files in", path, iter_err)
    end
    return count
end

--- Recursively delete a directory and its contents
function FileOps:_deleteRecursive(path)
    local iter_ok, iter_err = pcall(function()
        for name in lfs.dir(path) do
            if name ~= "." and name ~= ".." then
                local entry_path = path .. "/" .. name
                local entry_attr = lfs.attributes(entry_path)
                if entry_attr then
                    if entry_attr.mode == "directory" then
                        local del_ok, del_err = self:_deleteRecursive(entry_path)
                        if not del_ok then error(del_err) end
                    else
                        local rm_ok, rm_err = os.remove(entry_path)
                        if not rm_ok then
                            error("Cannot delete: " .. tostring(rm_err))
                        end
                    end
                end
            end
        end
    end)

    if not iter_ok then
        return false, tostring(iter_err)
    end

    local ok, err = lfs.rmdir(path)
    if not ok then
        return false, "Cannot remove directory: " .. tostring(err)
    end
    return true
end

--- Escape a string for safe use in a shell command (wrap in single quotes)
function FileOps:_shellEscape(str)
    return Utils.shellEscape(str)
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


--- Read an EPUB's OPF content and extract cover metadata.
--- This is the shared helper for _epubHasCover, getMetadata (EPUB branch), and getBookCover.
--- @param full_path string: absolute filesystem path to the EPUB file
--- @return table|nil: on success, a table with fields:
---   opf_content (string), opf_dir (string), cover_id (string|nil),
---   cover_href (string|nil), cover_media_type (string|nil),
---   title (string|nil), author (string|nil), has_cover (bool)
---   Returns nil if the EPUB cannot be read or has no valid OPF.
function FileOps:_readEpubOpf(full_path)
    local escaped_path = self:_shellEscape(full_path)

    -- Step 1: Read container.xml to locate the OPF file
    local container_cmd = "unzip -p " .. escaped_path .. " META-INF/container.xml 2>/dev/null"
    local container_handle = io.popen(container_cmd)
    if not container_handle then return nil end
    local container_xml = container_handle:read("*all")
    container_handle:close()
    if not container_xml or #container_xml == 0 then return nil end

    local opf_path = container_xml:match('full%-path="([^"]+)"')
    if not opf_path then return nil end

    -- Step 2: Read the OPF content
    local opf_cmd = "unzip -p " .. escaped_path .. " " .. self:_shellEscape(opf_path) .. " 2>/dev/null"
    local opf_handle = io.popen(opf_cmd)
    if not opf_handle then return nil end
    local opf_content = opf_handle:read("*all")
    opf_handle:close()
    if not opf_content or #opf_content == 0 then return nil end

    -- Step 3: Extract metadata from the OPF
    local opf_dir = opf_path:match("(.+)/[^/]+$") or ""

    local title_raw = opf_content:match("<dc:title[^>]*>([^<]+)</dc:title>")
    local title = title_raw and title_raw:gsub("^%s+", ""):gsub("%s+$", "") or nil

    local author_raw = opf_content:match("<dc:creator[^>]*>([^<]+)</dc:creator>")
    local author = author_raw and author_raw:gsub("^%s+", ""):gsub("%s+$", "") or nil

    -- Step 4: Find cover metadata
    local cover_id = opf_content:match('<meta[^>]*name="cover"[^>]*content="([^"]+)"')
    if not cover_id then
        cover_id = opf_content:match('<meta[^>]*content="([^"]+)"[^>]*name="cover"')
    end

    local cover_href = nil
    local cover_media_type = nil
    local has_cover = false

    -- Method 1: Look up item by cover_id
    if cover_id then
        for item in opf_content:gmatch('<item[^>]+/?>') do
            local item_id = item:match('id="([^"]+)"')
            if item_id == cover_id then
                cover_href = item:match('href="([^"]+)"')
                cover_media_type = item:match('media%-type="([^"]+)"')
                has_cover = true
                break
            end
        end
        -- If cover_id was found but no matching item, still flag has_cover
        -- (the cover meta element alone indicates a cover exists)
        if not has_cover then
            -- Check if any item with this id exists (self-closing or not)
            local esc_id = cover_id:gsub("([%(%)%.%%%+%-%*%?%[%]%^%$])", "%%%1")
            local item_pattern = '<item[^>]*id="' .. esc_id .. '"[^>]*/>'
            local cover_item = opf_content:match(item_pattern)
            if not cover_item then
                item_pattern = '<item[^>]*id="' .. esc_id .. '"[^>]*>'
                cover_item = opf_content:match(item_pattern)
            end
            if cover_item then
                has_cover = true
                cover_href = cover_item:match('href="([^"]+)"')
                cover_media_type = cover_item:match('media%-type="([^"]+)"')
            end
        end
    end

    -- Method 2: Look for items with id containing "cover" and image media-type
    if not has_cover then
        for item in opf_content:gmatch('<item[^>]+/?>') do
            local item_id = item:match('id="([^"]+)"')
            local media = item:match('media%-type="([^"]+)"')
            local href = item:match('href="([^"]+)"')
            if item_id and media and item_id:lower():find("cover") and media:match("^image/") then
                cover_href = href
                cover_media_type = media
                has_cover = true
                break
            end
        end
    end

    return {
        opf_content = opf_content,
        opf_dir = opf_dir,
        opf_path = opf_path,
        title = title,
        author = author,
        cover_id = cover_id,
        cover_href = cover_href,
        cover_media_type = cover_media_type,
        has_cover = has_cover,
    }
end

--- Quick check whether an EPUB file has a cover image (for .sdr cache path).
--- Returns true/false.
function FileOps:_epubHasCover(full_path)
    local ok, has = pcall(function()
        local opf_data = self:_readEpubOpf(full_path)
        return opf_data and opf_data.has_cover or false
    end)
    return ok and has
end

--- Get metadata for a file: title, author, cover status, size, type, etc.
--- Tries .sdr cache first, then EPUB OPF / MOBI binary headers, then filename parsing.
--- @param rel_path string: relative path from root_dir
--- @return table|nil: metadata table with name, size, modified, type, title, author, has_cover, etc.
--- @return string|nil: error message on failure
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
                local mobi_meta = Mobi.parseMobiMetadata(full_path)
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
        local opf_data = self:_readEpubOpf(full_path)
        if opf_data then
            if opf_data.title then result.title = opf_data.title end
            if opf_data.author then result.author = opf_data.author end
            if opf_data.has_cover then result.has_cover = true end
        end
    end

    -- Step 3: For MOBI/AZW3 files without .sdr cache data, parse binary headers
    if not result.title and MOBI_EXTENSIONS[extension:lower()] and attr.mode == "file" then
        local mobi_meta = Mobi.parseMobiMetadata(full_path)
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

--- Extract cover image data from an ebook file (EPUB, MOBI, AZW3).
--- Returns the raw image data and its content type for the caller to serve.
--- @param rel_path string: relative path to the ebook file
--- @return table|nil: {data, content_type} on success
--- @return string|nil: error message on failure
function FileOps:getBookCover(rel_path)
    local full_path, err = self:_resolvePath(rel_path)
    if not full_path then
        return nil, err
    end

    local attr = lfs.attributes(full_path)
    if not attr or attr.mode ~= "file" then
        return nil, "Not a file"
    end

    local extension = full_path:match("%.([^%.]+)$")
    if not extension then
        return nil, "No file extension"
    end
    extension = extension:lower()

    -- MOBI/AZW3 cover extraction
    if MOBI_EXTENSIONS[extension] then
        local img_data, content_type = Mobi.extractMobiCover(full_path)
        if not img_data then
            return nil, content_type or "Cover not found in MOBI/AZW3"
        end
        return { data = img_data, content_type = content_type }
    end

    -- EPUB cover extraction
    if extension ~= "epub" then
        return nil, "Cover extraction not supported for this format"
    end

    -- Use shared OPF parser to locate cover metadata
    local opf_data = self:_readEpubOpf(full_path)
    if not opf_data then
        return nil, "Cannot read EPUB OPF"
    end

    local cover_href = opf_data.cover_href
    local cover_media_type = opf_data.cover_media_type
    local opf_dir = opf_data.opf_dir

    if not cover_href then
        return nil, "Cover not found"
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

    -- Extract the cover image from the EPUB archive
    local escaped_path = self:_shellEscape(full_path)
    local extract_cmd = "unzip -p " .. escaped_path .. " " .. self:_shellEscape(cover_path_in_epub) .. " 2>/dev/null"
    local img_handle = io.popen(extract_cmd)
    if not img_handle then
        return nil, "Cannot extract cover image"
    end
    local img_data = img_handle:read("*all")
    img_handle:close()

    if not img_data or #img_data == 0 then
        return nil, "Cover image is empty"
    end

    return { data = img_data, content_type = cover_media_type }
end

return FileOps
