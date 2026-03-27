return function(FileOps, dependencies)
    local lfs = dependencies.lfs
    local logger = dependencies.logger

    --- Create a directory.
    function FileOps:createDirectory(rel_path, options)
        local full_path, err = self:_resolvePath(rel_path, options)
        if not full_path then
            return false, err
        end

        local parent = full_path:match("(.+)/[^/]+$")
        if parent then
            local parent_attr = lfs.attributes(parent)
            if not parent_attr or parent_attr.mode ~= "directory" then
                return false, "Parent directory does not exist"
            end
        end

        local attr = lfs.attributes(full_path)
        if attr then
            return false, "Path already exists"
        end

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

    --- Rename a file or directory.
    function FileOps:rename(old_rel_path, new_rel_path, options)
        local old_path, err1 = self:_resolvePath(old_rel_path, options)
        if not old_path then
            return false, err1
        end

        local new_path, err2 = self:_resolvePath(new_rel_path, options)
        if not new_path then
            return false, err2
        end

        local attr = lfs.attributes(old_path)
        if not attr then
            return false, "Source does not exist"
        end

        local dest_attr = lfs.attributes(new_path)
        if dest_attr then
            return false, "Destination already exists"
        end

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

    function FileOps:_validateDestinationPath(full_path)
        local parent = full_path:match("(.+)/[^/]+$")
        if parent then
            local parent_attr = lfs.attributes(parent)
            if not parent_attr or parent_attr.mode ~= "directory" then
                return false, "Parent directory does not exist"
            end
        end

        local name = full_path:match("([^/]+)$")
        local valid, valid_err = self:_validateFilename(name)
        if not valid then
            return false, valid_err
        end

        return true
    end

    function FileOps:_isPathInside(parent_path, child_path)
        return child_path:sub(1, #parent_path + 1) == parent_path .. "/"
    end

    function FileOps:_normalizeConflictStrategy(strategy)
        if strategy == "replace" or strategy == "merge_replace" then
            return strategy
        end
        return "error"
    end

    function FileOps:_describeEntryType(attr)
        if not attr then
            return nil
        end
        return attr.mode == "directory" and "directory" or "file"
    end

    function FileOps:_buildDestinationConflict(src_attr, dest_attr, dest_path, scope_id, extra)
        local details = extra or {}
        details.code = "destination_exists"
        details.source_type = details.source_type or self:_describeEntryType(src_attr)
        details.destination_type = details.destination_type or self:_describeEntryType(dest_attr)
        details.can_merge = details.can_merge == true
            or (details.source_type == "directory" and details.destination_type == "directory")
        if dest_path and scope_id and not details.destination_path then
            details.destination_path = self:_getRelativePath(dest_path, scope_id)
        end
        return details
    end

    function FileOps:_removeResolvedPath(full_path)
        local attr = lfs.attributes(full_path)
        if not attr then
            return true
        end

        if attr.mode == "directory" then
            local ok, err = self:_deleteRecursive(full_path)
            if not ok then
                return false, "Cannot delete existing destination: " .. tostring(err)
            end
            return true
        end

        local ok, err = os.remove(full_path)
        if not ok then
            return false, "Cannot delete existing destination: " .. tostring(err)
        end
        return true
    end

    function FileOps:_copyFileContents(src_path, dst_path)
        local src_file, src_err = io.open(src_path, "rb")
        if not src_file then
            return false, "Cannot open source file: " .. tostring(src_err)
        end

        local dst_file, dst_err = io.open(dst_path, "wb")
        if not dst_file then
            src_file:close()
            return false, "Cannot create destination file: " .. tostring(dst_err)
        end

        local chunk_size = 65536
        while true do
            local chunk, read_err = src_file:read(chunk_size)
            if read_err then
                src_file:close()
                dst_file:close()
                os.remove(dst_path)
                return false, "Cannot read source file: " .. tostring(read_err)
            end
            if not chunk then break end
            local write_ok, write_err = dst_file:write(chunk)
            if not write_ok then
                src_file:close()
                dst_file:close()
                os.remove(dst_path)
                return false, "Cannot write destination file: " .. tostring(write_err)
            end
        end

        local close_ok, close_err = dst_file:close()
        src_file:close()
        if close_ok == false then
            os.remove(dst_path)
            return false, "Cannot finalize destination file: " .. tostring(close_err)
        end

        return true
    end

    function FileOps:_copyResolvedEntry(src_path, dst_path, src_attr, dst_scope_id, conflict_strategy)
        conflict_strategy = self:_normalizeConflictStrategy(conflict_strategy)
        src_attr = src_attr or lfs.attributes(src_path)
        if not src_attr then
            return false, "Source does not exist"
        end

        local dest_attr = lfs.attributes(dst_path)

        if src_attr.mode == "directory" then
            if dest_attr then
                if dest_attr.mode == "directory" then
                    if conflict_strategy == "error" then
                        return false, "Destination already exists",
                            self:_buildDestinationConflict(src_attr, dest_attr, dst_path, dst_scope_id)
                    end

                    if conflict_strategy == "replace" then
                        local ok, err = self:_removeResolvedPath(dst_path)
                        if not ok then
                            return false, err
                        end
                        dest_attr = nil
                    end
                else
                    if conflict_strategy == "error" then
                        return false, "Destination already exists",
                            self:_buildDestinationConflict(src_attr, dest_attr, dst_path, dst_scope_id)
                    end

                    local ok, err = self:_removeResolvedPath(dst_path)
                    if not ok then
                        return false, err
                    end
                    dest_attr = nil
                end
            end

            if not dest_attr then
                local ok, mkdir_err = lfs.mkdir(dst_path)
                if not ok then
                    return false, "Cannot create destination directory: " .. tostring(mkdir_err)
                end
            end

            for name in lfs.dir(src_path) do
                if name ~= "." and name ~= ".." then
                    local child_src_path = src_path .. "/" .. name
                    local child_dst_path = dst_path .. "/" .. name
                    local child_attr = lfs.attributes(child_src_path)
                    local ok, err, details = self:_copyResolvedEntry(
                        child_src_path,
                        child_dst_path,
                        child_attr,
                        dst_scope_id,
                        conflict_strategy
                    )
                    if not ok then
                        return false, err, details
                    end
                end
            end

            logger.info("FileSync: Copied directory", src_path, "to", dst_path)
            return true
        end

        if dest_attr then
            if conflict_strategy == "error" then
                return false, "Destination already exists",
                    self:_buildDestinationConflict(src_attr, dest_attr, dst_path, dst_scope_id)
            end

            local ok, err = self:_removeResolvedPath(dst_path)
            if not ok then
                return false, err
            end
        end

        local ok, err = self:_copyFileContents(src_path, dst_path)
        if not ok then
            return false, err
        end

        logger.info("FileSync: Copied", src_path, "to", dst_path)
        return true
    end

    function FileOps:_moveResolvedEntry(src_path, dst_path, src_attr, src_scope_id, dst_scope_id, conflict_strategy)
        conflict_strategy = self:_normalizeConflictStrategy(conflict_strategy)
        src_attr = src_attr or lfs.attributes(src_path)
        if not src_attr then
            return false, "Source does not exist"
        end

        local dest_attr = lfs.attributes(dst_path)
        if dest_attr then
            if src_attr.mode == "directory" and dest_attr.mode == "directory" and conflict_strategy == "merge_replace" then
                local merge_ok, merge_err, merge_details = self:_copyResolvedEntry(
                    src_path,
                    dst_path,
                    src_attr,
                    dst_scope_id,
                    "merge_replace"
                )
                if not merge_ok then
                    return false, merge_err, merge_details
                end

                local cleanup_ok, cleanup_err = self:_removeResolvedPath(src_path)
                if not cleanup_ok then
                    return false, "Cannot finalize move: " .. tostring(cleanup_err)
                end

                logger.info("FileSync: Merged and moved", src_path, "to", dst_path)
                return true
            end

            if conflict_strategy == "error" then
                return false, "Destination already exists",
                    self:_buildDestinationConflict(src_attr, dest_attr, dst_path, dst_scope_id)
            end

            local remove_ok, remove_err = self:_removeResolvedPath(dst_path)
            if not remove_ok then
                return false, remove_err
            end
        end

        local ok, move_err = os.rename(src_path, dst_path)
        if ok then
            logger.info("FileSync: Moved", src_path, "to", dst_path)
            return true
        end

        local copy_ok, copy_err, copy_details = self:_copyResolvedEntry(
            src_path,
            dst_path,
            src_attr,
            dst_scope_id,
            src_attr.mode == "directory" and "merge_replace" or "replace"
        )
        if not copy_ok then
            return false, copy_err, copy_details
        end

        local cleanup_ok, cleanup_err = self:_removeResolvedPath(src_path)
        if not cleanup_ok then
            return false, "Cannot finalize move: " .. tostring(cleanup_err)
        end

        logger.info("FileSync: Moved", src_path, "to", dst_path)
        return true
    end

    --- Move a file or directory.
    function FileOps:move(old_rel_path, new_rel_path, options)
        options = options or {}
        local old_path, err1, old_scope = self:_resolvePath(old_rel_path, {
            scope = options.old_scope or options.scope,
            allow_root_scopes = options.allow_root_scopes,
        })
        if not old_path then
            return false, err1
        end

        local new_path, err2, new_scope = self:_resolvePath(new_rel_path, {
            scope = options.new_scope or options.scope,
            allow_root_scopes = options.allow_root_scopes,
        })
        if not new_path then
            return false, err2
        end

        if old_path == old_scope.root_path then
            return false, "Cannot move root directory"
        end

        local src_attr = lfs.attributes(old_path)
        if not src_attr then
            return false, "Source does not exist"
        end

        if old_path == new_path then
            return false, "Source and destination are the same"
        end

        local valid, valid_err = self:_validateDestinationPath(new_path)
        if not valid then
            return false, valid_err
        end

        if src_attr.mode == "directory" and old_scope.id == new_scope.id and self:_isPathInside(old_path, new_path) then
            return false, "Cannot move directory inside itself"
        end

        return self:_moveResolvedEntry(
            old_path,
            new_path,
            src_attr,
            old_scope.id,
            new_scope.id,
            options.conflict_strategy
        )
    end

    --- Copy a file or directory.
    function FileOps:copyFile(src_rel_path, dst_rel_path, options)
        options = options or {}
        local src_path, err1, src_scope = self:_resolvePath(src_rel_path, {
            scope = options.old_scope or options.scope,
            allow_root_scopes = options.allow_root_scopes,
        })
        if not src_path then
            return false, err1
        end

        local dst_path, err2, dst_scope = self:_resolvePath(dst_rel_path, {
            scope = options.new_scope or options.scope,
            allow_root_scopes = options.allow_root_scopes,
        })
        if not dst_path then
            return false, err2
        end

        local src_attr = lfs.attributes(src_path)
        if not src_attr then
            return false, "Source does not exist"
        end
        if src_path == dst_path then
            return false, "Source and destination are the same"
        end

        local valid, valid_err = self:_validateDestinationPath(dst_path)
        if not valid then
            return false, valid_err
        end

        if src_attr.mode == "directory" and src_scope.id == dst_scope.id and self:_isPathInside(src_path, dst_path) then
            return false, "Cannot copy directory inside itself"
        end

        return self:_copyResolvedEntry(
            src_path,
            dst_path,
            src_attr,
            dst_scope.id,
            options.conflict_strategy
        )
    end

    --- Delete a file or directory (directory must be empty unless recursive=true).
    function FileOps:delete(rel_path, options)
        options = options or {}
        local full_path, err, scope = self:_resolvePath(rel_path, options)
        if not full_path then
            return false, err
        end

        if full_path == scope.root_path then
            return false, "Cannot delete root directory"
        end

        local attr = lfs.attributes(full_path)
        if not attr then
            return false, "Path does not exist"
        end

        local is_file = attr.mode ~= "directory"

        if attr.mode == "directory" then
            local child_count = 0
            for child_name in lfs.dir(full_path) do
                if child_name ~= "." and child_name ~= ".." then
                    child_count = child_count + 1
                    break
                end
            end

            if child_count == 0 then
                local ok, del_err = lfs.rmdir(full_path)
                if not ok then
                    return false, "Cannot delete directory: " .. tostring(del_err)
                end
            elseif options.recursive == true then
                local ok, del_err = self:_deleteRecursive(full_path)
                if not ok then
                    return false, "Cannot delete directory: " .. tostring(del_err)
                end
            else
                return false, "Cannot delete non-empty directory without recursive flag"
            end
        else
            local ok, del_err = os.remove(full_path)
            if not ok then
                return false, "Cannot delete file: " .. tostring(del_err)
            end
        end

        logger.info("FileSync: Deleted", full_path)

        if is_file and options then
            local should_delete_sdr = false
            if options.safe_mode then
                should_delete_sdr = true
            elseif options.delete_sdr then
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

    --- Recursively delete a directory and its contents.
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
end
