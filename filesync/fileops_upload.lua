return function(FileOps, dependencies)
    local lfs = dependencies.lfs
    local logger = dependencies.logger
    local normalize_root_path = dependencies.normalize_root_path
    local is_path_within_root = dependencies.is_path_within_root

    function FileOps:_normalizeUploadRelativePath(relative_path, fallback_filename)
        local normalized = tostring(relative_path or fallback_filename or "")
        normalized = normalized:gsub("\\", "/")
        normalized = normalized:gsub("//+", "/")
        normalized = normalized:gsub("^%s+", ""):gsub("%s+$", "")
        normalized = normalized:gsub("^/+", ""):gsub("/+$", "")

        if normalized == "" then
            return nil, "Empty upload path"
        end

        if normalized:match("%.%.") then
            return nil, "Path traversal not allowed"
        end

        local segments = {}
        for segment in normalized:gmatch("[^/]+") do
            local valid, valid_err = self:_validateFilename(segment)
            if not valid then
                return nil, valid_err
            end
            table.insert(segments, segment)
        end

        if #segments == 0 then
            return nil, "Empty upload path"
        end

        if fallback_filename then
            segments[#segments] = fallback_filename
        end

        return table.concat(segments, "/")
    end

    function FileOps:_collectUploadDirectories(full_dir_path, pending_dirs, scope_root)
        scope_root = normalize_root_path(scope_root or self._root_dir)

        if not full_dir_path or full_dir_path == "" or full_dir_path == scope_root then
            return true
        end

        if not is_path_within_root(full_dir_path, scope_root) then
            return false, "Access denied: path outside root directory"
        end

        local rel = full_dir_path:sub(#scope_root + 1):gsub("^/+", "")
        if rel == "" then
            return true
        end

        local current = scope_root
        for segment in rel:gmatch("[^/]+") do
            local valid, valid_err = self:_validateFilename(segment)
            if not valid then
                return false, valid_err
            end

            current = current .. "/" .. segment
            local attr = lfs.attributes(current)
            if attr then
                if attr.mode ~= "directory" then
                    return false, "Cannot create directory: path component is not a directory"
                end
            else
                pending_dirs[current] = true
            end
        end

        return true
    end

    function FileOps:_createPendingDirectories(pending_dirs)
        local paths = {}
        for path in pairs(pending_dirs) do
            table.insert(paths, path)
        end

        table.sort(paths, function(a, b)
            return #a < #b
        end)

        for _, path in ipairs(paths) do
            local attr = lfs.attributes(path)
            if attr then
                if attr.mode ~= "directory" then
                    return false, "Cannot create directory: path component is not a directory"
                end
            else
                local ok, mkdir_err = lfs.mkdir(path)
                if not ok then
                    return false, "Cannot create directory: " .. tostring(mkdir_err)
                end
            end
        end

        return true
    end

    --- Handle multipart file upload.
    function FileOps:handleUpload(rel_dir, body, boundary, options)
        options = options or {}
        local dir_path, err, scope = self:_resolvePath(rel_dir, options)
        if not dir_path then
            return false, err
        end

        local attr = lfs.attributes(dir_path)
        if not attr or attr.mode ~= "directory" then
            return false, "Upload directory does not exist"
        end

        local delimiter = "--" .. boundary
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

            local part_data = body:sub(part_start, next_boundary - 3)
            table.insert(parts, part_data)
            search_start = next_boundary
        end

        local form_fields = {}
        local upload_entries = {}
        for _, part in ipairs(parts) do
            local header_end = part:find("\r\n\r\n", 1, true)
            if header_end then
                local headers_str = part:sub(1, header_end - 1)
                local file_data = part:sub(header_end + 4)
                local field_name = headers_str:match('name="([^"]+)"')

                local filename = headers_str:match('filename="([^"]+)"')
                if filename and filename ~= "" then
                    filename = filename:match("([^/\\]+)$") or filename

                    if filename:match("%.epub%.zip$") then
                        filename = filename:gsub("%.zip$", "")
                    elseif filename:match("%.cbz%.zip$") then
                        filename = filename:gsub("%.zip$", "")
                    end

                    local valid, valid_err = self:_validateFilename(filename)
                    if valid then
                        if options.safe_mode and not self:isExtensionSafe(filename) then
                            return false, "Root mode required for this file type"
                        end
                        table.insert(upload_entries, {
                            filename = filename,
                            data = file_data,
                        })
                    else
                        logger.warn("FileSync: Invalid filename:", filename, valid_err)
                    end
                elseif field_name and field_name ~= "" then
                    form_fields[field_name] = file_data:gsub("\r\n$", "")
                end
            end
        end

        if #upload_entries == 0 then
            return false, "No files were uploaded"
        end

        local conflict_strategy = self:_normalizeConflictStrategy(form_fields.conflict_strategy or options.conflict_strategy)
        local pending_dirs = {}
        local planned_targets = {}
        local prepared_entries = {}

        for _, entry in ipairs(upload_entries) do
            local upload_rel_path, path_err = self:_normalizeUploadRelativePath(form_fields.relative_path, entry.filename)
            if not upload_rel_path then
                return false, path_err
            end

            local target_rel_path = self:_joinRelativePaths(rel_dir, upload_rel_path)
            local target_full_path, target_err = self:_resolvePath(target_rel_path, options)
            if not target_full_path then
                return false, target_err
            end

            local target_attr = lfs.attributes(target_full_path)
            if target_attr then
                if conflict_strategy == "error" then
                    return false, "Destination already exists", self:_buildDestinationConflict(
                        { mode = "file" },
                        target_attr,
                        target_full_path,
                        scope.id,
                        {
                            destination_path = target_rel_path,
                            source_type = "file",
                        }
                    )
                end
            end

            if planned_targets[target_full_path] then
                return false, "Destination already exists", self:_buildDestinationConflict(
                    { mode = "file" },
                    { mode = "file" },
                    target_full_path,
                    scope.id,
                    {
                        destination_path = target_rel_path,
                        source_type = "file",
                        destination_type = "file",
                    }
                )
            end

            local parent_dir = target_full_path:match("(.+)/[^/]+$")
            local ok_dirs, dir_err = self:_collectUploadDirectories(parent_dir, pending_dirs, scope.root_path)
            if not ok_dirs then
                return false, dir_err
            end

            planned_targets[target_full_path] = true
            table.insert(prepared_entries, {
                full_path = target_full_path,
                relative_path = upload_rel_path,
                data = entry.data,
            })
        end

        local ok_dirs, dir_err = self:_createPendingDirectories(pending_dirs)
        if not ok_dirs then
            return false, dir_err
        end

        local uploaded_count = 0
        for index, entry in ipairs(prepared_entries) do
            local temp_path = string.format("%s.filesync-upload-%d-%d.tmp", entry.full_path, os.time(), index)
            local f = io.open(temp_path, "wb")
            if f then
                local write_ok, write_err = f:write(entry.data)
                local close_ok, close_err = f:close()
                if write_ok and close_ok ~= false then
                    local can_finalize = true
                    local target_attr = lfs.attributes(entry.full_path)
                    if target_attr then
                        local remove_ok, remove_err = self:_removeResolvedPath(entry.full_path)
                        if not remove_ok then
                            os.remove(temp_path)
                            logger.warn("FileSync: Cannot replace existing destination", entry.full_path, remove_err)
                            can_finalize = false
                        end
                    end

                    if can_finalize then
                        local rename_ok, rename_err = os.rename(temp_path, entry.full_path)
                        if rename_ok then
                            uploaded_count = uploaded_count + 1
                            logger.info("FileSync: Uploaded", entry.relative_path, "to", dir_path)
                        else
                            os.remove(temp_path)
                            logger.warn("FileSync: Cannot finalize upload", entry.full_path, rename_err)
                        end
                    end
                else
                    os.remove(temp_path)
                    logger.warn("FileSync: Cannot write upload temp file", temp_path, write_err or close_err)
                end
            else
                logger.warn("FileSync: Cannot write file", temp_path)
            end
        end

        if uploaded_count == #prepared_entries then
            return true
        end

        if uploaded_count > 0 then
            return false, "Some files could not be uploaded"
        end

        return false, "No files were uploaded"
    end
end
