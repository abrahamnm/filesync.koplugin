return function(FileOps, dependencies)
    local lfs = dependencies.lfs

    --- List directory contents
    function FileOps:listDirectory(rel_path, sort_by, sort_order, filter, options)
        options = options or {}
        local full_path, err, scope = self:_resolvePath(rel_path, options)
        if not full_path then
            return nil, err
        end

        local attr = lfs.attributes(full_path)
        if not attr or attr.mode ~= "directory" then
            return nil, "Not a directory"
        end

        local include_hidden = options.include_hidden == true and not options.safe_mode
        local entries = {}
        local ok, iter_err = pcall(function()
            for name in lfs.dir(full_path) do
                if name ~= "." and name ~= ".." then
                    if include_hidden or name:sub(1, 1) ~= "." then
                        local include = true
                        if filter and filter ~= "" then
                            include = name:lower():find(filter:lower(), 1, true) ~= nil
                        end

                        if include then
                            local entry_path = full_path .. "/" .. name
                            local entry_attr = lfs.attributes(entry_path)
                            if entry_attr then
                                local is_dir = entry_attr.mode == "directory"
                                if options.safe_mode and not is_dir and not self:isExtensionSafe(name) then
                                    -- Skip non-whitelisted files in safe mode.
                                elseif options.safe_mode and is_dir and name:match("%.sdr$") then
                                    -- Skip KOReader metadata directories in safe mode.
                                else
                                    local entry = {
                                        name = name,
                                        path = self:_getRelativePath(entry_path, scope.id),
                                        is_dir = is_dir,
                                        size = entry_attr.size or 0,
                                        size_formatted = self:_formatSize(entry_attr.size or 0),
                                        modified = entry_attr.modification or 0,
                                        type = is_dir and "directory" or self:_getFileType(name),
                                    }
                                    if is_dir then
                                        local child_count = 0
                                        for child_name in lfs.dir(entry_path) do
                                            if child_name ~= "." and child_name ~= ".." then
                                                child_count = child_count + 1
                                                break
                                            end
                                        end
                                        entry.is_empty = child_count == 0
                                    end
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

        sort_by = sort_by or "name"
        sort_order = sort_order or "asc"

        table.sort(entries, function(a, b)
            if a.is_dir and not b.is_dir then return true end
            if not a.is_dir and b.is_dir then return false end

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

        local breadcrumbs = {{ name = "Home", path = "/" }}
        if rel_path and rel_path ~= "/" then
            local parts = {}
            for part in rel_path:gmatch("[^/]+") do
                table.insert(parts, part)
            end
            local cumulative = ""
            for _, part in ipairs(parts) do
                cumulative = cumulative .. "/" .. part
                table.insert(breadcrumbs, { name = part, path = cumulative })
            end
        end

        return {
            scope = scope.id,
            scope_root = scope.root_path,
            scope_label = scope.label,
            path = rel_path or "/",
            entries = entries,
            breadcrumbs = breadcrumbs,
            count = #entries,
        }
    end

    --- Download a file, sending it directly to the client socket.
    --- When inline is true, serve with Content-Disposition: inline.
    function FileOps:downloadFile(client, rel_path, server, inline, options)
        local full_path, err = self:_resolvePath(rel_path, options)
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

        local disposition = inline
            and ('inline; filename="' .. filename .. '"')
            or ('attachment; filename="' .. filename .. '"')
        server:sendResponseHeaders(client, 200, {
            ["Content-Type"] = mime_type,
            ["Content-Length"] = tostring(file_size),
            ["Content-Disposition"] = disposition,
            ["Connection"] = "close",
        })

        local chunk_size = 65536
        while true do
            local chunk = f:read(chunk_size)
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
end
