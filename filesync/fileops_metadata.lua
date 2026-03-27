return function(FileOps, dependencies)
    local lfs = dependencies.lfs
    local logger = dependencies.logger

    local MOBI_EXTENSIONS = {
        mobi = true,
        azw = true,
        azw3 = true,
        prc = true,
        pdb = true,
    }

    local function read_uint16_be(data, offset)
        return string.byte(data, offset) * 256 + string.byte(data, offset + 1)
    end

    local function read_uint32_be(data, offset)
        return string.byte(data, offset) * 16777216 + string.byte(data, offset + 1) * 65536
            + string.byte(data, offset + 2) * 256 + string.byte(data, offset + 3)
    end

    --- Escape a string for safe use in a shell command.
    function FileOps:_shellEscape(str)
        if not str then return "''" end
        local escaped = str:gsub("'", "'\\''")
        return "'" .. escaped .. "'"
    end

    --- Try to read metadata from KOReader's .sdr cache directory.
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

        if result.title or result.author then
            return result
        end
        return nil
    end

    --- Parse MOBI/AZW3 binary headers and extract metadata.
    function FileOps:_parseMobiMetadata(full_path)
        local ok, result = pcall(function()
            local f = io.open(full_path, "rb")
            if not f then return nil end

            local header_data = f:read(65536)
            if not header_data or #header_data < 78 then
                f:close()
                return nil
            end

            local pdb_name = header_data:sub(1, 32):match("^([^%z]+)") or ""

            local num_records = read_uint16_be(header_data, 77)
            if num_records < 1 then
                f:close()
                return nil
            end

            local record_table_start = 79
            if #header_data < record_table_start + num_records * 8 then
                f:close()
                return nil
            end

            local first_record_offset = read_uint32_be(header_data, record_table_start)

            local record_data
            if first_record_offset + 4096 <= #header_data then
                record_data = header_data:sub(first_record_offset + 1)
            else
                f:seek("set", first_record_offset)
                record_data = f:read(65536)
            end

            if not record_data or #record_data < 132 then
                f:close()
                return nil
            end

            local mobi_start = 17
            local mobi_id = record_data:sub(mobi_start, mobi_start + 3)
            if mobi_id ~= "MOBI" then
                f:close()
                return nil
            end

            local mobi_header_length = read_uint32_be(record_data, mobi_start + 4)
            local full_title_offset = read_uint32_be(record_data, mobi_start + 84)
            local full_title_length = read_uint32_be(record_data, mobi_start + 88)

            local has_exth = false
            local exth_check_pos = mobi_start + mobi_header_length
            if exth_check_pos + 4 <= #record_data then
                has_exth = record_data:sub(exth_check_pos, exth_check_pos + 3) == "EXTH"
            end

            local first_image_record = nil
            if #record_data >= mobi_start + 111 then
                first_image_record = read_uint32_be(record_data, mobi_start + 108)
            end

            if not first_image_record or first_image_record == 0 or first_image_record >= num_records then
                local img_records = {}
                for ri = num_records - 1, 1, -1 do
                    local ri_offset_pos = record_table_start + (ri * 8)
                    if ri_offset_pos + 4 <= #header_data then
                        local ri_offset = read_uint32_be(header_data, ri_offset_pos)
                        f:seek("set", ri_offset)
                        local magic = f:read(4)
                        if magic then
                            local b1, b2 = string.byte(magic, 1), string.byte(magic, 2)
                            if (b1 == 0xFF and b2 == 0xD8) or magic == "\137PNG" or magic:sub(1, 3) == "GIF" then
                                table.insert(img_records, 1, ri)
                            else
                                if #img_records > 0 then break end
                            end
                        end
                    end
                end
                if #img_records > 0 then
                    first_image_record = img_records[1]
                end
            end

            local full_title = nil
            local title_start = full_title_offset + 1
            if full_title_length > 0 and full_title_length < 1024
                and title_start + full_title_length - 1 <= #record_data then
                full_title = record_data:sub(title_start, title_start + full_title_length - 1)
            end

            local exth_title = nil
            local author = nil
            local cover_offset = nil
            local thumb_offset = nil

            if has_exth then
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
                            if rec_length < 8 then break end

                            local data_length = rec_length - 8
                            local rec_data = nil
                            if data_length > 0 and pos + 7 + data_length <= #record_data then
                                rec_data = record_data:sub(pos + 8, pos + 7 + data_length)
                            end

                            if rec_type == 100 and rec_data then
                                author = rec_data:gsub("^%s+", ""):gsub("%s+$", "")
                            elseif rec_type == 503 and rec_data then
                                exth_title = rec_data:gsub("^%s+", ""):gsub("%s+$", "")
                            elseif rec_type == 201 and rec_data and #rec_data >= 4 then
                                cover_offset = read_uint32_be(rec_data, 1)
                            elseif rec_type == 202 and rec_data and #rec_data >= 4 then
                                thumb_offset = read_uint32_be(rec_data, 1)
                            end

                            pos = pos + rec_length
                        end
                    end
                end
            end

            f:close()

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

            if cover_offset and first_image_record then
                meta.has_cover = true
                meta.cover_record_index = first_image_record + cover_offset
            elseif thumb_offset and first_image_record then
                meta.has_cover = true
                meta.cover_record_index = first_image_record + thumb_offset
            end

            meta.num_records = num_records
            return meta
        end)

        if ok and result then
            return result
        end
        return nil
    end

    --- Extract cover image data from a MOBI/AZW3 file.
    function FileOps:_extractMobiCover(full_path)
        local ok, img_data, content_type = pcall(function()
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

            f:seek("set", 76)
            local num_rec_bytes = f:read(2)
            if not num_rec_bytes or #num_rec_bytes < 2 then
                f:close()
                return nil, nil
            end

            local record_table_file_offset = 78
            local entry_offset = record_table_file_offset + cover_index * 8

            f:seek("set", entry_offset)
            local entry_data = f:read(12)
            if not entry_data or #entry_data < 4 then
                f:close()
                return nil, nil
            end

            local record_offset = read_uint32_be(entry_data, 1)

            local record_size
            if #entry_data >= 12 and cover_index + 1 < num_records then
                local next_offset = read_uint32_be(entry_data, 9)
                record_size = next_offset - record_offset
            else
                record_size = 2 * 1024 * 1024
            end

            if record_size <= 0 or record_size > 5 * 1024 * 1024 then
                f:close()
                return nil, nil
            end

            f:seek("set", record_offset)
            local data = f:read(record_size)
            f:close()

            if not data or #data < 4 then
                return nil, nil
            end

            local ctype = "image/jpeg"
            local b1, b2 = string.byte(data, 1), string.byte(data, 2)
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

    --- Quick check whether an EPUB file has a cover image.
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

            local cover_id = opf_content:match('<meta[^>]*name="cover"[^>]*content="([^"]+)"')
            if not cover_id then
                cover_id = opf_content:match('<meta[^>]*content="([^"]+)"[^>]*name="cover"')
            end
            if cover_id then return true end

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

    --- Get metadata for a file.
    function FileOps:getMetadata(rel_path, options)
        local full_path, err = self:_resolvePath(rel_path, options)
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

        if attr.mode == "file" then
            local sdr_meta = self:_readSdrMetadata(full_path)
            if sdr_meta then
                if sdr_meta.title then result.title = sdr_meta.title end
                if sdr_meta.author then result.author = sdr_meta.author end
                if sdr_meta.description then result.description = sdr_meta.description end
                if MOBI_EXTENSIONS[extension:lower()] then
                    local mobi_meta = self:_parseMobiMetadata(full_path)
                    if mobi_meta and mobi_meta.has_cover then
                        result.has_cover = true
                    end
                elseif extension:lower() == "epub" then
                    result.has_cover = self:_epubHasCover(full_path)
                end
            end
        end

        if not result.title and extension:lower() == "epub" and attr.mode == "file" then
            local escaped_path = self:_shellEscape(full_path)
            local container_cmd = "unzip -p " .. escaped_path .. " META-INF/container.xml 2>/dev/null"
            local container_handle = io.popen(container_cmd)
            if container_handle then
                local container_xml = container_handle:read("*all")
                container_handle:close()

                if container_xml and #container_xml > 0 then
                    local opf_path = container_xml:match('full%-path="([^"]+)"')
                    if opf_path then
                        local opf_cmd = "unzip -p " .. escaped_path .. " " .. self:_shellEscape(opf_path) .. " 2>/dev/null"
                        local opf_handle = io.popen(opf_cmd)
                        if opf_handle then
                            local opf_content = opf_handle:read("*all")
                            opf_handle:close()

                            if opf_content and #opf_content > 0 then
                                local title = opf_content:match("<dc:title[^>]*>([^<]+)</dc:title>")
                                if title then
                                    result.title = title:gsub("^%s+", ""):gsub("%s+$", "")
                                end

                                local author = opf_content:match("<dc:creator[^>]*>([^<]+)</dc:creator>")
                                if author then
                                    result.author = author:gsub("^%s+", ""):gsub("%s+$", "")
                                end

                                local cover_id = opf_content:match('<meta[^>]*name="cover"[^>]*content="([^"]+)"')
                                if not cover_id then
                                    cover_id = opf_content:match('<meta[^>]*content="([^"]+)"[^>]*name="cover"')
                                end
                                if cover_id then
                                    local item_pattern = '<item[^>]*id="' .. cover_id:gsub("([%(%)%.%%%+%-%*%?%[%]%^%$])", "%%%1") .. '"[^>]*/>'
                                    local cover_item = opf_content:match(item_pattern)
                                    if not cover_item then
                                        item_pattern = '<item[^>]*id="' .. cover_id:gsub("([%(%)%.%%%+%-%*%?%[%]%^%$])", "%%%1") .. '"[^>]*>'
                                        cover_item = opf_content:match(item_pattern)
                                    end
                                    if cover_item then
                                        result.has_cover = true
                                    end
                                end

                                if not result.has_cover then
                                    for item in opf_content:gmatch('<item[^>]+>') do
                                        local item_id = item:match('id="([^"]+)"')
                                        local media = item:match('media%-type="([^"]+)"')
                                        if item_id and media and item_id:lower():find("cover") and media:match("^image/") then
                                            result.has_cover = true
                                            break
                                        end
                                    end
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

        if not result.title and MOBI_EXTENSIONS[extension:lower()] and attr.mode == "file" then
            local mobi_meta = self:_parseMobiMetadata(full_path)
            if mobi_meta then
                if mobi_meta.title then result.title = mobi_meta.title end
                if mobi_meta.author then result.author = mobi_meta.author end
                if mobi_meta.has_cover then result.has_cover = true end
            end
        end

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

    --- Extract and stream cover image from an ebook file.
    function FileOps:getBookCover(client, rel_path, server, options)
        local full_path, err = self:_resolvePath(rel_path, options)
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

        if extension ~= "epub" then
            return false, "Cover extraction not supported for this format"
        end

        local escaped_path = self:_shellEscape(full_path)
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

        local opf_dir = opf_path:match("(.+)/[^/]+$") or ""

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

        local cover_id = opf_content:match('<meta[^>]*name="cover"[^>]*content="([^"]+)"')
        if not cover_id then
            cover_id = opf_content:match('<meta[^>]*content="([^"]+)"[^>]*name="cover"')
        end

        if cover_id then
            for item in opf_content:gmatch('<item[^>]+/?>') do
                local item_id = item:match('id="([^"]+)"')
                if item_id == cover_id then
                    cover_href = item:match('href="([^"]+)"')
                    cover_media_type = item:match('media%-type="([^"]+)"')
                    break
                end
            end
        end

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

        local cover_path_in_epub
        if opf_dir ~= "" then
            cover_path_in_epub = opf_dir .. "/" .. cover_href
        else
            cover_path_in_epub = cover_href
        end

        cover_path_in_epub = cover_path_in_epub:gsub("%%(%x%x)", function(h)
            return string.char(tonumber(h, 16))
        end)

        if not cover_media_type or cover_media_type == "" then
            local cover_ext = cover_href:match("%.([^%.]+)$")
            if cover_ext then
                cover_ext = cover_ext:lower()
                local mime_map = {
                    jpg = "image/jpeg",
                    jpeg = "image/jpeg",
                    png = "image/png",
                    gif = "image/gif",
                    svg = "image/svg+xml",
                    webp = "image/webp",
                }
                cover_media_type = mime_map[cover_ext] or "image/jpeg"
            else
                cover_media_type = "image/jpeg"
            end
        end

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

    --- Read editable metadata fields from an EPUB's OPF file.
    function FileOps:readEpubEditableMetadata(rel_path, options)
        local full_path, err = self:_resolvePath(rel_path, options)
        if not full_path then
            return nil, err
        end

        local attr = lfs.attributes(full_path)
        if not attr or attr.mode ~= "file" then
            return nil, "Not a file"
        end

        local extension = full_path:match("%.([^%.]+)$")
        if not extension or extension:lower() ~= "epub" then
            return { editable = false }
        end

        local escaped_path = self:_shellEscape(full_path)
        local container_cmd = "unzip -p " .. escaped_path .. " META-INF/container.xml 2>/dev/null"
        local container_handle = io.popen(container_cmd)
        if not container_handle then
            return nil, "Cannot read EPUB"
        end
        local container_xml = container_handle:read("*all")
        container_handle:close()

        if not container_xml or #container_xml == 0 then
            return nil, "Invalid EPUB: no container.xml"
        end

        local opf_path = container_xml:match('full%-path="([^"]+)"')
        if not opf_path then
            return nil, "Invalid EPUB: no OPF path"
        end

        local opf_cmd = "unzip -p " .. escaped_path .. " " .. self:_shellEscape(opf_path) .. " 2>/dev/null"
        local opf_handle = io.popen(opf_cmd)
        if not opf_handle then
            return nil, "Cannot read OPF"
        end
        local opf_content = opf_handle:read("*all")
        opf_handle:close()

        if not opf_content or #opf_content == 0 then
            return nil, "Invalid EPUB: empty OPF"
        end

        local title = opf_content:match("<dc:title[^>]*>([^<]+)</dc:title>")
        local author = opf_content:match("<dc:creator[^>]*>([^<]+)</dc:creator>")
        local publisher = opf_content:match("<dc:publisher[^>]*>([^<]+)</dc:publisher>")
        local description = opf_content:match("<dc:description[^>]*>(.-)</dc:description>")

        local function trim(s)
            if not s then return nil end
            return s:gsub("^%s+", ""):gsub("%s+$", "")
        end

        return {
            editable = true,
            format = "epub",
            opf_path = opf_path,
            title = trim(title) or "",
            author = trim(author) or "",
            publisher = trim(publisher) or "",
            description = trim(description) or "",
        }
    end

    --- Replace or insert a Dublin Core element in an OPF XML string.
    function FileOps:_setDcElement(opf_content, element_name, new_value)
        local pattern = "(<dc:" .. element_name .. "[^>]*>)(.-)(</dc:" .. element_name .. ">)"
        if opf_content:match(pattern) then
            return opf_content:gsub(pattern, "%1" .. new_value:gsub("%%", "%%%%") .. "%3", 1)
        else
            local insert_tag = "<dc:" .. element_name .. ">" .. new_value .. "</dc:" .. element_name .. ">"
            if opf_content:match("</metadata>") then
                return opf_content:gsub("</metadata>", insert_tag .. "\n</metadata>", 1)
            elseif opf_content:match("</opf:metadata>") then
                return opf_content:gsub("</opf:metadata>", insert_tag .. "\n</opf:metadata>", 1)
            end
            return opf_content
        end
    end

    --- Escape special XML characters in a string value.
    function FileOps:_escapeXml(s)
        if not s then return "" end
        return s:gsub("&", "&amp;"):gsub("<", "&lt;"):gsub(">", "&gt;"):gsub('"', "&quot;"):gsub("'", "&apos;")
    end

    --- Update metadata fields in an EPUB file.
    function FileOps:updateEpubMetadata(rel_path, fields, options)
        local full_path, err = self:_resolvePath(rel_path, options)
        if not full_path then
            return nil, err
        end

        local attr = lfs.attributes(full_path)
        if not attr or attr.mode ~= "file" then
            return nil, "Not a file"
        end

        local extension = full_path:match("%.([^%.]+)$")
        if not extension or extension:lower() ~= "epub" then
            return nil, "Metadata editing is only supported for EPUB files"
        end

        local meta, meta_err = self:readEpubEditableMetadata(rel_path, options)
        if not meta then
            return nil, meta_err
        end
        if not meta.editable then
            return nil, "File is not editable"
        end

        local opf_path = meta.opf_path
        local escaped_path = self:_shellEscape(full_path)

        local opf_cmd = "unzip -p " .. escaped_path .. " " .. self:_shellEscape(opf_path) .. " 2>/dev/null"
        local opf_handle = io.popen(opf_cmd)
        if not opf_handle then
            return nil, "Cannot read OPF from EPUB"
        end
        local opf_content = opf_handle:read("*all")
        opf_handle:close()

        if not opf_content or #opf_content == 0 then
            return nil, "Empty OPF content"
        end

        if fields.title ~= nil then
            opf_content = self:_setDcElement(opf_content, "title", self:_escapeXml(fields.title))
        end
        if fields.author ~= nil then
            opf_content = self:_setDcElement(opf_content, "creator", self:_escapeXml(fields.author))
        end
        if fields.publisher ~= nil then
            opf_content = self:_setDcElement(opf_content, "publisher", self:_escapeXml(fields.publisher))
        end
        if fields.description ~= nil then
            opf_content = self:_setDcElement(opf_content, "description", self:_escapeXml(fields.description))
        end

        local tmp_opf_path = "/tmp/filesync_opf_" .. os.time() .. "_" .. math.random(10000, 99999) .. ".opf"
        local opf_file = io.open(tmp_opf_path, "w")
        if not opf_file then
            return nil, "Cannot create temporary OPF file"
        end
        opf_file:write(opf_content)
        opf_file:close()

        local tmp_epub_path = full_path .. ".filesync.tmp"
        local copy_cmd = "cp " .. escaped_path .. " " .. self:_shellEscape(tmp_epub_path) .. " 2>/dev/null"
        local copy_ok = os.execute(copy_cmd)
        if copy_ok ~= 0 and copy_ok ~= true then
            os.remove(tmp_opf_path)
            return nil, "Cannot create temporary EPUB copy"
        end

        local opf_dir = opf_path:match("(.+)/[^/]+$")
        local opf_filename = opf_path:match("([^/]+)$")
        if opf_dir and opf_dir ~= "" then
            local tmp_dir = "/tmp/filesync_epub_" .. os.time() .. "_" .. math.random(10000, 99999)
            local mkdir_cmd = "mkdir -p " .. self:_shellEscape(tmp_dir .. "/" .. opf_dir) .. " 2>/dev/null"
            os.execute(mkdir_cmd)
            local mv_cmd = "mv " .. self:_shellEscape(tmp_opf_path) .. " " .. self:_shellEscape(tmp_dir .. "/" .. opf_path) .. " 2>/dev/null"
            os.execute(mv_cmd)
            local zip_cmd = "cd " .. self:_shellEscape(tmp_dir) .. " && zip -q " .. self:_shellEscape(tmp_epub_path) .. " " .. self:_shellEscape(opf_path) .. " 2>/dev/null"
            local zip_ok = os.execute(zip_cmd)
            os.execute("rm -rf " .. self:_shellEscape(tmp_dir) .. " 2>/dev/null")
            if zip_ok ~= 0 and zip_ok ~= true then
                os.remove(tmp_epub_path)
                return nil, "Failed to update OPF inside EPUB"
            end
        else
            local renamed_opf = "/tmp/" .. opf_filename
            os.rename(tmp_opf_path, renamed_opf)
            local zip_cmd = "cd /tmp && zip -q " .. self:_shellEscape(tmp_epub_path) .. " " .. self:_shellEscape(opf_filename) .. " 2>/dev/null"
            local zip_ok = os.execute(zip_cmd)
            os.remove(renamed_opf)
            if zip_ok ~= 0 and zip_ok ~= true then
                os.remove(tmp_epub_path)
                return nil, "Failed to update OPF inside EPUB"
            end
        end

        local rename_ok, rename_err = os.rename(tmp_epub_path, full_path)
        if not rename_ok then
            os.remove(tmp_epub_path)
            return nil, "Failed to replace original EPUB: " .. tostring(rename_err)
        end

        logger.info("FileSync: Updated EPUB metadata for", full_path)
        return true
    end
end
