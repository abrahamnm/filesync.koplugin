local logger = require("logger")
local ok_i18n, plugin_gettext = pcall(require, "filesync/filesync_i18n")
local _ = ok_i18n and plugin_gettext or require("gettext")
local T = require("ffi/util").template

local Updater = {
    _github_api_url = "https://api.github.com/repos/abrahamnm/filesync.koplugin/releases/latest",
    _cache_interval = 86400, -- 24 hours in seconds
}

--- Get the plugin directory path dynamically.
function Updater:_getPluginDir()
    local info = debug.getinfo(1, "S")
    local script_path = info.source:match("@(.+)")
    if script_path then
        -- This file is filesync/updater.lua, go up one level
        local filesync_dir = script_path:match("(.+)/[^/]+$") or "."
        local plugin_dir = filesync_dir:match("(.+)/[^/]+$") or "."
        return plugin_dir
    end
    return "."
end

--- Get current plugin version from _meta.lua.
function Updater:_getCurrentVersion()
    local plugin_dir = self:_getPluginDir()
    local meta = dofile(plugin_dir .. "/_meta.lua")
    return meta.version or "0.0.0"
end

--- Parse a semantic version string into a comparable table.
-- Handles versions like "1.2.3" or "v1.2.3" (strips leading "v").
function Updater:_parseVersion(version_str)
    if not version_str then return nil end
    version_str = version_str:gsub("^v", "")
    local major, minor, patch = version_str:match("^(%d+)%.(%d+)%.(%d+)")
    if not major then return nil end
    return {
        major = tonumber(major),
        minor = tonumber(minor),
        patch = tonumber(patch),
    }
end

--- Compare two version tables. Returns true if remote is newer than local.
function Updater:_isNewer(remote_ver, local_ver)
    if not remote_ver or not local_ver then return false end
    if remote_ver.major > local_ver.major then return true end
    if remote_ver.major < local_ver.major then return false end
    if remote_ver.minor > local_ver.minor then return true end
    if remote_ver.minor < local_ver.minor then return false end
    return remote_ver.patch > local_ver.patch
end

--- Minimal JSON parser (recursive descent). Reuses the same approach as httpserver.lua.
function Updater:_parseJSON(str)
    if not str or str == "" then return nil end
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

--- Fetch latest release info from GitHub API via HTTPS.
-- Returns release table on success, or nil + error message on failure.
function Updater:_fetchLatestRelease()
    local https = require("ssl.https")
    local ltn12 = require("ltn12")

    local response_body = {}
    local result, status_code, headers = https.request{
        url = self._github_api_url,
        method = "GET",
        headers = {
            ["Accept"] = "application/vnd.github.v3+json",
            ["User-Agent"] = "filesync.koplugin",
        },
        sink = ltn12.sink.table(response_body),
    }

    if not result then
        return nil, _("Network error: could not reach GitHub.")
    end

    if status_code ~= 200 then
        return nil, T(_("GitHub API returned status %1."), tostring(status_code))
    end

    local body = table.concat(response_body)
    local release = self:_parseJSON(body)
    if not release then
        return nil, _("Failed to parse update information from GitHub.")
    end

    return release
end

--- Find the ZIP download URL from a release's assets.
-- Falls back to the source code zipball if no .zip asset is found.
function Updater:_getDownloadUrl(release)
    -- First, look for a .zip asset in the release assets
    if release.assets and #release.assets > 0 then
        for _, asset in ipairs(release.assets) do
            if asset.name and asset.name:match("%.zip$") then
                return asset.browser_download_url
            end
        end
    end
    -- Fallback to the source code zipball
    if release.zipball_url then
        return release.zipball_url
    end
    return nil
end

--- Perform an HTTPS/HTTP request, following redirects manually.
-- LuaSec's ssl.https does not support the "redirect" option that socket.http has,
-- so we must handle 3xx redirects ourselves.
function Updater:_httpsRequest(url, sink)
    local https = require("ssl.https")
    local http = require("socket.http")
    local ltn12 = require("ltn12")

    local max_redirects = 10
    for _ = 1, max_redirects do
        local request_func = url:match("^https") and https.request or http.request
        local result, status_code, headers = request_func{
            url = url,
            method = "GET",
            headers = {
                ["User-Agent"] = "filesync.koplugin",
            },
            sink = sink,
            redirect = false,
        }

        if not result then
            return nil, nil, nil
        end

        -- Follow 3xx redirects
        if status_code >= 300 and status_code < 400 and headers then
            local location = headers["location"] or headers["Location"]
            if location then
                -- Reset sink for the redirect — we need a fresh table sink
                -- (file sinks can't be reused, caller handles this for file downloads)
                url = location
            else
                return result, status_code, headers
            end
        else
            return result, status_code, headers
        end
    end

    return nil, nil, nil
end

--- Download a file from a URL (follows redirects) to a local path.
-- Returns true on success, or nil + error message on failure.
function Updater:_downloadFile(url, dest_path)
    local https = require("ssl.https")
    local http = require("socket.http")
    local ltn12 = require("ltn12")

    -- First, resolve all redirects to get the final URL (using a throwaway sink)
    local final_url = url
    local max_redirects = 10
    for _ = 1, max_redirects do
        local request_func = final_url:match("^https") and https.request or http.request
        local result, status_code, headers = request_func{
            url = final_url,
            method = "HEAD",
            headers = {
                ["User-Agent"] = "filesync.koplugin",
            },
            redirect = false,
        }

        if not result then
            return nil, _("Download failed: network error.")
        end

        if status_code >= 300 and status_code < 400 and headers then
            local location = headers["location"] or headers["Location"]
            if location then
                final_url = location
            else
                break
            end
        else
            break
        end
    end

    -- Now download from the final URL
    local f, err = io.open(dest_path, "wb")
    if not f then
        return nil, T(_("Cannot create temporary file: %1"), tostring(err))
    end

    local request_func = final_url:match("^https") and https.request or http.request
    local result, status_code = request_func{
        url = final_url,
        method = "GET",
        headers = {
            ["User-Agent"] = "filesync.koplugin",
        },
        sink = ltn12.sink.file(f),
    }

    -- Note: ltn12.sink.file closes the file handle

    if not result then
        os.remove(dest_path)
        return nil, _("Download failed: network error.")
    end

    if status_code ~= 200 then
        os.remove(dest_path)
        return nil, T(_("Download failed with status %1."), tostring(status_code))
    end

    return true
end

--- Install the update by extracting the ZIP and replacing the plugin directory.
-- Returns true on success, or nil + error message on failure.
function Updater:_installUpdate(zip_path)
    local plugin_dir = self:_getPluginDir()
    local parent_dir = plugin_dir:match("(.+)/[^/]+$")
    if not parent_dir then
        return nil, _("Cannot determine plugin parent directory.")
    end

    local plugin_dirname = plugin_dir:match("([^/]+)$")
    local tmp_dir = parent_dir .. "/" .. plugin_dirname .. "_update_tmp"
    local backup_dir = parent_dir .. "/" .. plugin_dirname .. "_backup"

    -- Clean up any leftover temp/backup directories from a previous attempt
    os.execute("rm -rf " .. self:_shellEscape(tmp_dir))
    os.execute("rm -rf " .. self:_shellEscape(backup_dir))

    -- Create temporary directory for extraction
    os.execute("mkdir -p " .. self:_shellEscape(tmp_dir))

    -- Extract the ZIP to the temp directory
    local unzip_cmd = string.format(
        "unzip -o %s -d %s 2>&1",
        self:_shellEscape(zip_path),
        self:_shellEscape(tmp_dir)
    )
    local handle = io.popen(unzip_cmd)
    local unzip_output = ""
    if handle then
        unzip_output = handle:read("*all") or ""
        handle:close()
    end

    -- Check if extraction produced files.
    -- GitHub source ZIPs contain a top-level directory (e.g., "filesync.koplugin-1.2.0/").
    -- Release asset ZIPs may extract directly. We need to find where the files are.
    local extracted_dir = tmp_dir
    local lfs = require("libs/libkoreader-lfs")
    local entries = {}
    local iter, dir_obj = lfs.dir(tmp_dir)
    if iter then
        for entry in iter, dir_obj do
            if entry ~= "." and entry ~= ".." then
                table.insert(entries, entry)
            end
        end
    end

    -- If there's exactly one subdirectory, that's the actual plugin content
    if #entries == 1 then
        local single_entry = tmp_dir .. "/" .. entries[1]
        local attr = lfs.attributes(single_entry)
        if attr and attr.mode == "directory" then
            extracted_dir = single_entry
        end
    end

    -- Verify the extracted content looks like our plugin (has _meta.lua)
    local verify_f = io.open(extracted_dir .. "/_meta.lua", "r")
    if not verify_f then
        os.execute("rm -rf " .. self:_shellEscape(tmp_dir))
        os.remove(zip_path)
        return nil, _("Update verification failed: extracted files do not look like a valid plugin.")
    end
    verify_f:close()

    -- Move current plugin to backup
    local mv_backup = os.execute(string.format(
        "mv %s %s",
        self:_shellEscape(plugin_dir),
        self:_shellEscape(backup_dir)
    ))

    -- Move extracted content to the plugin directory
    local mv_install = os.execute(string.format(
        "mv %s %s",
        self:_shellEscape(extracted_dir),
        self:_shellEscape(plugin_dir)
    ))

    if not mv_install or (mv_install ~= 0 and mv_install ~= true) then
        -- Restore from backup on failure
        logger.err("FileSync Updater: mv install failed, restoring backup")
        os.execute(string.format(
            "rm -rf %s && mv %s %s",
            self:_shellEscape(plugin_dir),
            self:_shellEscape(backup_dir),
            self:_shellEscape(plugin_dir)
        ))
        os.execute("rm -rf " .. self:_shellEscape(tmp_dir))
        os.remove(zip_path)
        return nil, _("Failed to install update. Previous version has been restored.")
    end

    -- Clean up backup and temp files
    os.execute("rm -rf " .. self:_shellEscape(backup_dir))
    os.execute("rm -rf " .. self:_shellEscape(tmp_dir))
    os.remove(zip_path)

    logger.info("FileSync Updater: Update installed successfully")
    return true
end

--- Escape a string for safe use in shell commands.
function Updater:_shellEscape(s)
    return "'" .. s:gsub("'", "'\\''") .. "'"
end

--- Get last update check timestamp from settings.
function Updater:_getLastCheckTime()
    return G_reader_settings:readSetting("filesync_last_update_check", 0)
end

--- Save the current time as the last update check timestamp.
function Updater:_setLastCheckTime()
    G_reader_settings:saveSetting("filesync_last_update_check", os.time())
    G_reader_settings:flush()
end

--- Extract a brief changelog summary from the release body.
function Updater:_getChangelog(release)
    local body = release.body
    if not body or body == "" then
        return ""
    end
    -- Truncate to a reasonable length for display on e-readers
    local max_len = 500
    if #body > max_len then
        body = body:sub(1, max_len) .. "..."
    end
    return body
end

--- Main entry point: check for updates and show appropriate UI.
-- If manual is false/nil, respects the cache interval.
function Updater:checkForUpdates(manual)
    local UIManager = require("ui/uimanager")
    local InfoMessage = require("ui/widget/infomessage")
    local NetworkMgr = require("ui/network/manager")

    -- For manual checks, always proceed. For automatic, respect cache.
    if not manual then
        local last_check = self:_getLastCheckTime()
        local now = os.time()
        if (now - last_check) < self._cache_interval then
            logger.dbg("FileSync Updater: Skipping check, last check was recent")
            return
        end
    end

    -- Check network availability
    if not NetworkMgr:isWifiOn() then
        if manual then
            UIManager:show(InfoMessage:new{
                text = _("WiFi is not enabled. Please turn on WiFi and try again."),
                timeout = 3,
            })
        end
        return
    end

    -- Show a brief "checking" message for manual checks
    local checking_msg
    if manual then
        checking_msg = InfoMessage:new{
            text = _("Checking for updates..."),
            timeout = 30,
        }
        UIManager:show(checking_msg)
        UIManager:forceRePaint()
    end

    -- Perform the check in a scheduled callback to allow the UI to render
    UIManager:scheduleIn(0.1, function()
        local release, err = self:_fetchLatestRelease()

        -- Close the "checking" message
        if checking_msg then
            UIManager:close(checking_msg)
        end

        if not release then
            logger.warn("FileSync Updater:", err)
            if manual then
                UIManager:show(InfoMessage:new{
                    text = T(_("Could not check for updates.\n\n%1"), err),
                    timeout = 5,
                })
            end
            return
        end

        -- Record successful check
        self:_setLastCheckTime()

        local remote_version_str = release.tag_name
        if not remote_version_str then
            if manual then
                UIManager:show(InfoMessage:new{
                    text = _("Could not determine the latest version."),
                    timeout = 3,
                })
            end
            return
        end

        local current_version_str = self:_getCurrentVersion()
        local remote_ver = self:_parseVersion(remote_version_str)
        local local_ver = self:_parseVersion(current_version_str)

        if not self:_isNewer(remote_ver, local_ver) then
            if manual then
                UIManager:show(InfoMessage:new{
                    text = T(_("FileSync is up to date (v%1)."), current_version_str),
                    timeout = 3,
                })
            end
            return
        end

        -- A new version is available — prompt the user
        local display_version = remote_version_str:gsub("^v", "")
        local changelog = self:_getChangelog(release)
        local message = T(_("A new version of FileSync is available!\n\nCurrent: v%1\nNew: v%2"), current_version_str, display_version)
        if changelog ~= "" then
            message = message .. "\n\n" .. changelog
        end

        local ConfirmBox = require("ui/widget/confirmbox")
        UIManager:show(ConfirmBox:new{
            text = message,
            ok_text = _("Update now"),
            cancel_text = _("Later"),
            ok_callback = function()
                self:_performUpdate(release)
            end,
        })
    end)
end

--- Download and install an update from the given release.
function Updater:_performUpdate(release)
    local UIManager = require("ui/uimanager")
    local InfoMessage = require("ui/widget/infomessage")

    local download_url = self:_getDownloadUrl(release)
    if not download_url then
        UIManager:show(InfoMessage:new{
            text = _("Could not find a download URL for this release."),
            timeout = 5,
        })
        return
    end

    -- Show downloading message
    local downloading_msg = InfoMessage:new{
        text = _("Downloading update..."),
        timeout = 120,
    }
    UIManager:show(downloading_msg)
    UIManager:forceRePaint()

    UIManager:scheduleIn(0.1, function()
        -- Download to a temporary file
        local plugin_dir = self:_getPluginDir()
        local parent_dir = plugin_dir:match("(.+)/[^/]+$") or "/tmp"
        local tmp_zip = parent_dir .. "/filesync_update.zip"

        local ok, err = self:_downloadFile(download_url, tmp_zip)

        UIManager:close(downloading_msg)

        if not ok then
            logger.err("FileSync Updater: Download failed:", err)
            UIManager:show(InfoMessage:new{
                text = T(_("Download failed.\n\n%1"), err),
                timeout = 5,
            })
            return
        end

        -- Show installing message
        local installing_msg = InfoMessage:new{
            text = _("Installing update..."),
            timeout = 120,
        }
        UIManager:show(installing_msg)
        UIManager:forceRePaint()

        UIManager:scheduleIn(0.1, function()
            local install_ok, install_err = self:_installUpdate(tmp_zip)

            UIManager:close(installing_msg)

            if not install_ok then
                logger.err("FileSync Updater: Install failed:", install_err)
                UIManager:show(InfoMessage:new{
                    text = T(_("Update installation failed.\n\n%1"), install_err),
                    timeout = 5,
                })
                return
            end

            -- Success — prompt to restart
            local ConfirmBox = require("ui/widget/confirmbox")
            UIManager:show(ConfirmBox:new{
                text = _("FileSync has been updated successfully!\n\nPlease restart KOReader for the changes to take effect."),
                ok_text = _("Restart now"),
                cancel_text = _("Later"),
                ok_callback = function()
                    UIManager:restartKOReader()
                end,
            })
        end)
    end)
end

return Updater
