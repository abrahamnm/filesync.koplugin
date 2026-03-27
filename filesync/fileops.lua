-- Try standard require first, then KOReader's internal path.
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
    jpg = true, jpeg = true, png = true, gif = true, webp = true,
}

local FILE_TYPE_BY_COMPOUND_EXTENSION = {
    ["fb2.zip"] = "ebook",
    ["epub.zip"] = "ebook",
    ["cbz.zip"] = "comic",
}

local FILE_TYPE_BY_FILENAME = {
    ["dockerfile"] = "code",
    ["makefile"] = "code",
    ["justfile"] = "code",
    ["cmakelists.txt"] = "code",
    [".bashrc"] = "code",
    [".zshrc"] = "code",
    [".profile"] = "code",
    [".gitignore"] = "code",
    [".gitattributes"] = "code",
    [".gitmodules"] = "code",
    [".editorconfig"] = "code",
    [".env"] = "code",
}

local FILE_TYPE_BY_EXTENSION = {
    epub = "ebook",
    fb2 = "ebook",
    lit = "ebook",
    pdb = "ebook",
    prc = "ebook",
    mobi = "reader",
    azw = "reader",
    azw3 = "reader",
    kfx = "reader",
    pdf = "pdf",
    djvu = "pdf",
    cbz = "comic",
    cbr = "comic",
    txt = "text",
    md = "markdown",
    markdown = "markdown",
    mkd = "markdown",
    mdown = "markdown",
    rtf = "text",
    doc = "document",
    docx = "document",
    html = "code",
    htm = "code",
    chm = "document",
    png = "image",
    jpg = "image",
    jpeg = "image",
    gif = "image",
    svg = "image",
    bmp = "image",
    webp = "image",
    zip = "archive",
    gz = "archive",
    tar = "archive",
    bz2 = "archive",
    xz = "archive",
    rar = "archive",
    ["7z"] = "archive",
    mp3 = "audio",
    m4a = "audio",
    aac = "audio",
    wav = "audio",
    ogg = "audio",
    flac = "audio",
    mp4 = "video",
    mkv = "video",
    avi = "video",
    mov = "video",
    webm = "video",
    lua = "code",
    js = "code",
    ts = "code",
    jsx = "code",
    tsx = "code",
    mjs = "code",
    cjs = "code",
    json = "code",
    xml = "code",
    yml = "code",
    yaml = "code",
    toml = "code",
    ini = "code",
    cfg = "code",
    conf = "code",
    log = "code",
    sh = "code",
    bash = "code",
    zsh = "code",
    py = "code",
    rb = "code",
    php = "code",
    go = "code",
    rs = "code",
    c = "code",
    cpp = "code",
    h = "code",
    hpp = "code",
    java = "code",
    css = "code",
    scss = "code",
    sass = "code",
    less = "code",
    sql = "code",
}

local function normalize_root_path(path)
    local normalized = tostring(path or "/")
    normalized = normalized:gsub("//+", "/"):gsub("^%s+", ""):gsub("%s+$", "")
    if normalized == "" then
        normalized = "/"
    end
    if normalized ~= "/" and normalized:sub(-1) == "/" then
        normalized = normalized:sub(1, -2)
    end
    if normalized:sub(1, 1) ~= "/" then
        normalized = "/" .. normalized
    end
    return normalized
end

local function is_path_within_root(full_path, root_path)
    if root_path == "/" then
        return full_path:sub(1, 1) == "/"
    end
    return full_path == root_path or full_path:sub(1, #root_path + 1) == root_path .. "/"
end

local FileOps = {
    _root_dir = "/mnt/us",
    _default_scope_id = "storage",
    _scope_configs = nil,
}

function FileOps:setRootDir(dir)
    self._root_dir = normalize_root_path(dir)
    self:_rebuildScopeConfigs()
end

function FileOps:getRootDir()
    return self._root_dir
end

function FileOps:_rebuildScopeConfigs()
    local storage_root = normalize_root_path(self._root_dir)
    self._scope_configs = {
        storage = {
            id = "storage",
            label = storage_root,
            root_path = storage_root,
            root_only = false,
        },
    }

    if storage_root ~= "/" then
        self._scope_configs.system = {
            id = "system",
            label = "/",
            root_path = "/",
            root_only = true,
        }
    end
end

function FileOps:_ensureScopeConfigs()
    if not self._scope_configs then
        self:_rebuildScopeConfigs()
    end
end

function FileOps:getDefaultScopeId()
    return self._default_scope_id
end

function FileOps:getNavigationScopes(allow_root_scopes)
    self:_ensureScopeConfigs()
    local scopes = {}

    for _, scope_id in ipairs({ self._default_scope_id, "system" }) do
        local scope = self._scope_configs[scope_id]
        if scope and (not scope.root_only or allow_root_scopes) then
            table.insert(scopes, {
                id = scope.id,
                label = scope.label,
                root_path = scope.root_path,
            })
        end
    end

    return scopes
end

function FileOps:getScopeInfo(scope_id, allow_root_scopes)
    local scope, err = self:_getScopeConfig(scope_id, {
        allow_root_scopes = allow_root_scopes == true,
    })
    if not scope then
        return nil, err
    end

    return {
        id = scope.id,
        label = scope.label,
        root_path = scope.root_path,
    }
end

function FileOps:_getScopeConfig(scope_id, options)
    self:_ensureScopeConfigs()
    options = options or {}

    local resolved_scope_id = scope_id or self._default_scope_id
    local scope = self._scope_configs[resolved_scope_id]
    if not scope then
        return nil, "Unknown filesystem scope"
    end

    if scope.root_only and not options.allow_root_scopes then
        return nil, "Scope not available in current mode"
    end

    return scope
end

--- Resolve and validate a path, preventing path traversal.
function FileOps:_resolvePath(rel_path, options)
    options = options or {}
    if not rel_path or rel_path == "" then
        rel_path = "/"
    end

    local scope, scope_err = self:_getScopeConfig(options.scope, options)
    if not scope then
        return nil, scope_err
    end

    rel_path = rel_path:gsub("//+", "/"):gsub("^%s+", ""):gsub("%s+$", "")

    if rel_path:match("%.%.") then
        return nil, "Path traversal not allowed"
    end

    if rel_path:sub(1, 1) ~= "/" then
        rel_path = "/" .. rel_path
    end

    local full_path = scope.root_path .. rel_path
    full_path = full_path:gsub("//+", "/")

    if #full_path > 1 and full_path:sub(-1) == "/" then
        full_path = full_path:sub(1, -2)
    end

    if not is_path_within_root(full_path, scope.root_path) then
        return nil, "Access denied: path outside root directory"
    end

    return full_path, nil, scope
end

--- Validate a filename (no slashes, no dots-only, no null bytes).
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

--- Get the relative path from a scope root.
function FileOps:_getRelativePath(full_path, scope_id)
    local scope = self._scope_configs and self._scope_configs[scope_id or self._default_scope_id]
    local root_path = scope and scope.root_path or self._root_dir
    if is_path_within_root(full_path, root_path) then
        local rel = full_path:sub(#root_path + 1)
        if rel == "" then rel = "/" end
        return rel
    end
    return full_path
end

--- Format file size for display.
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

--- Detect MIME type from extension.
function FileOps:_getMimeType(filename)
    local ext = filename:match("%.([^%.]+)$")
    if not ext then return "application/octet-stream" end
    ext = ext:lower()

    local mime_types = {
        epub = "application/epub+zip",
        pdf = "application/pdf",
        mobi = "application/x-mobipocket-ebook",
        azw = "application/vnd.amazon.ebook",
        azw3 = "application/vnd.amazon.ebook",
        fb2 = "application/x-fictionbook+xml",
        djvu = "image/vnd.djvu",
        cbz = "application/x-cbz",
        cbr = "application/x-cbr",
        txt = "text/plain",
        html = "text/html",
        htm = "text/html",
        css = "text/css",
        js = "application/javascript",
        json = "application/json",
        xml = "application/xml",
        doc = "application/msword",
        docx = "application/vnd.openxmlformats-officedocument.wordprocessingml.document",
        rtf = "application/rtf",
        png = "image/png",
        jpg = "image/jpeg",
        jpeg = "image/jpeg",
        gif = "image/gif",
        webp = "image/webp",
        svg = "image/svg+xml",
        zip = "application/zip",
        gz = "application/gzip",
        tar = "application/x-tar",
    }

    return mime_types[ext] or "application/octet-stream"
end

--- Get file type category.
function FileOps:_getFileType(filename)
    if not filename then return "file" end
    local lower_name = filename:lower()
    if FILE_TYPE_BY_FILENAME[lower_name] then
        return FILE_TYPE_BY_FILENAME[lower_name]
    end
    local compound_ext = lower_name:match("%.([^/]+%.[^%.]+)$")
    if compound_ext and FILE_TYPE_BY_COMPOUND_EXTENSION[compound_ext] then
        return FILE_TYPE_BY_COMPOUND_EXTENSION[compound_ext]
    end

    local ext = lower_name:match("%.([^%.]+)$")
    if not ext then return "file" end

    return FILE_TYPE_BY_EXTENSION[ext] or "file"
end

--- Check if a filename has a safe mode whitelisted extension.
function FileOps:isExtensionSafe(filename)
    if not filename then return false end
    local compound_ext = filename:match("%.([^/]+%.[^%.]+)$")
    if compound_ext and SAFE_MODE_EXTENSIONS[compound_ext:lower()] then
        return true
    end
    local ext = filename:match("%.([^%.]+)$")
    if not ext then return false end
    return SAFE_MODE_EXTENSIONS[ext:lower()] == true
end

function FileOps:getSafeExtensions()
    local extensions = {}
    for ext, allowed in pairs(SAFE_MODE_EXTENSIONS) do
        if allowed then
            table.insert(extensions, ext)
        end
    end
    table.sort(extensions)
    return extensions
end

function FileOps:_joinRelativePaths(base_rel_path, child_rel_path)
    local base = base_rel_path or "/"
    local child = child_rel_path or ""

    child = child:gsub("^/+", "")
    if base == "/" or base == "" then
        return "/" .. child
    end

    return base:gsub("/+$", "") .. "/" .. child
end

local function get_module_dir()
    local source = ""
    if debug and debug.getinfo then
        source = debug.getinfo(1, "S").source or ""
    end
    if source:sub(1, 1) == "@" then
        source = source:sub(2)
    end
    local dir = source:match("^(.*)/[^/]+$")
    if not dir then
        error("FileSync: cannot determine fileops module directory")
    end
    return dir
end

local function load_extension(module_dir, filename, dependencies)
    local loader = dofile(module_dir .. "/" .. filename)
    if type(loader) ~= "function" then
        error("FileSync: invalid fileops extension " .. filename)
    end
    loader(FileOps, dependencies)
end

local module_dir = get_module_dir()
local extension_dependencies = {
    lfs = lfs,
    logger = logger,
    normalize_root_path = normalize_root_path,
    is_path_within_root = is_path_within_root,
}

load_extension(module_dir, "fileops_browse.lua", extension_dependencies)
load_extension(module_dir, "fileops_upload.lua", extension_dependencies)
load_extension(module_dir, "fileops_manage.lua", extension_dependencies)
load_extension(module_dir, "fileops_metadata.lua", extension_dependencies)

return FileOps
