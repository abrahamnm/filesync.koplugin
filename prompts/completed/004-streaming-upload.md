<objective>
Implement streaming multipart upload parsing so that file data is written to disk incrementally as it arrives over the socket, instead of accumulating the entire HTTP body in memory. This removes memory as the bottleneck for uploads — the new limit should be 200 MB, bounded by a Content-Length check rather than by available RAM.

Currently, a 50 MB upload causes 100-150 MB peak RAM usage on devices with only 256-512 MB total. After this change, memory usage during upload should stay roughly constant (~64-128 KB for the read buffer) regardless of file size.
</objective>

<context>
This is a KOReader plugin (filesync.koplugin) written in Lua, running on e-reader devices with severely limited RAM (256-512 MB). The plugin runs an HTTP server using LuaSocket.

Read these files fully before making changes:
- `filesync/httpserver.lua` — HTTP server with request parsing, body reading, routing
- `filesync/fileops.lua` — File operations including `handleUpload` which currently receives the full body as a string
- `docs/filesize-limits-analysis.md` — Detailed analysis of current limits (reference for understanding the problem)

Also read for context (do not modify):
- `filesync/json.lua`, `filesync/utils.lua`

### Current Upload Flow (what needs to change)
1. `httpserver.lua:_handleClient` reads headers, extracts `Content-Length`
2. `_readBody(client, content_length)` reads the ENTIRE body into memory as one Lua string
3. Body is checked against `MAX_BODY_SIZE` (50 MB) — but it's already in memory by this point
4. For POST `/api/upload`, the full body string is passed to `FileOps:handleUpload(body, content_type, rel_dir)`
5. `handleUpload` parses the multipart boundary, splits the body by boundary markers, extracts filenames, and writes file data via `f:write(file_data)`

### Target Upload Flow (what to implement)
1. `_handleClient` reads headers, extracts `Content-Length`
2. Check `Content-Length` against `MAX_UPLOAD_SIZE` (200 MB) BEFORE reading any body data — return 413 immediately if exceeded
3. For upload routes, pass the `client` socket and `content_length` to a new streaming parser
4. The streaming parser reads from the socket in chunks (64 KB), parses multipart boundaries on the fly, and writes file data directly to disk as it arrives
5. Non-upload routes (JSON API posts) continue to use the existing `_readBody` approach since their bodies are small

### Key technical challenge
Multipart boundary detection across chunk boundaries: the boundary marker (e.g., `------WebKitFormBoundary...`) could be split across two consecutive chunks. The parser must handle this correctly by keeping a small overlap buffer from the previous chunk.
</context>

<requirements>
1. **Raise the upload limit to 200 MB** — Change `MAX_BODY_SIZE` to `MAX_UPLOAD_SIZE = 200 * 1024 * 1024`. Check Content-Length before reading any data. Return 413 if exceeded.

2. **Keep existing `_readBody` for non-upload routes** — Only the upload path (POST to `/api/upload`) needs streaming. Other POST routes (like `/api/rename`, `/api/delete`, `/api/create-folder`) have small JSON bodies and should continue using the existing `_readBody` with a reasonable limit (e.g., 1 MB).

3. **Implement a streaming multipart parser** — Create a new function (e.g., `_handleStreamingUpload(client, content_length, content_type, rel_dir)`) in `httpserver.lua` or `fileops.lua` (whichever is more appropriate) that:
   - Extracts the multipart boundary from the Content-Type header
   - Reads the socket in fixed-size chunks (64 KB)
   - Parses multipart headers (Content-Disposition with filename) from the stream
   - Writes file data directly to disk as chunks arrive
   - Handles boundary markers that span chunk boundaries (overlap buffer)
   - Supports multiple files in a single upload (the web UI can send multiple files)
   - Returns `{uploaded_files = {...}, errors = {...}}` matching the current response format

4. **Handle errors gracefully**:
   - Disk full: Check `f:write()` return value, clean up partial file on failure
   - Connection dropped: Clean up partial file
   - Invalid multipart format: Return 400 with descriptive error
   - Timeout during read: Clean up partial file

5. **Preserve the existing API response format** — The JSON response to the web UI must remain identical so the frontend doesn't need changes.

6. **Add client-side file size validation** — In `filesync/static/index.html`, add a JavaScript check before uploading: if any selected file exceeds 200 MB, show an error message immediately instead of attempting the upload. This provides instant feedback rather than waiting for the server to reject it.
</requirements>

<implementation>
**Streaming multipart parsing approach:**

The multipart format looks like:
```
--boundary\r\n
Content-Disposition: form-data; name="files"; filename="book.epub"\r\n
Content-Type: application/epub+zip\r\n
\r\n
[file data bytes...]
\r\n--boundary\r\n
Content-Disposition: form-data; name="files"; filename="book2.pdf"\r\n
...
\r\n--boundary--\r\n
```

Strategy:
1. Read chunks from socket using `client:receive(chunk_size)`
2. Maintain a state machine: `HEADERS`, `FILE_DATA`, `DONE`
3. In `HEADERS` state: accumulate bytes until you see `\r\n\r\n`, then parse Content-Disposition for filename
4. In `FILE_DATA` state: scan for `\r\n--boundary` in the buffer. Write everything before a potential boundary match to disk. Keep the last `boundary_length + 4` bytes as overlap to handle split boundaries.
5. When boundary is found: close current file, transition back to `HEADERS` state (or `DONE` if it's the closing boundary `--boundary--`)

**Important edge cases:**
- The `\r\n` before the boundary is part of the multipart protocol, NOT part of the file data. Don't write those 2 bytes to the file.
- Handle `receive` returning partial data (less than requested chunk_size)
- Handle `receive` returning nil with "timeout" error — retry or abort
- Filenames come from Content-Disposition and must be validated with `FileOps:_validateFilename`

**What NOT to do:**
- Don't use `string.find` on the entire accumulated buffer — that defeats streaming. Only search in the overlap region + current chunk.
- Don't create temporary files and then rename — write directly to the final path (but clean up on error).
- Don't change the multipart format or require chunked Transfer-Encoding from the client — browsers send standard multipart/form-data.

**Memory budget:** At any point during a streaming upload, memory usage from the upload should not exceed ~256 KB (one read buffer + overlap buffer + header accumulator).
</implementation>

<output>
Modify these files:
- `filesync/httpserver.lua` — Add streaming upload handler, update routing, adjust limits
- `filesync/fileops.lua` — May need to adjust `handleUpload` or add a streaming variant; ensure `_validateFilename` and `_resolvePath` are accessible
- `filesync/static/index.html` — Add client-side 200 MB file size check before upload
</output>

<verification>
Before declaring complete:

1. **Verify syntax**: Run `luajit -bl filesync/httpserver.lua > /dev/null` and `luajit -bl filesync/fileops.lua > /dev/null` to check for syntax errors
2. **Run existing tests**: Execute `busted` from the project root — all 177+ tests must still pass
3. **Verify the upload response format** matches what the web UI expects (check the JavaScript that handles the upload response)
4. **Verify cleanup logic**: Trace through the error paths and confirm partial files are deleted on failure
5. **Verify boundary edge case handling**: Walk through a scenario where `\r\n--boundary` is split across two chunks
6. **Check memory discipline**: Confirm no code path accumulates the entire file body as a single Lua string
</verification>

<success_criteria>
- Upload limit raised to 200 MB with pre-read Content-Length check
- Streaming multipart parser reads from socket in 64 KB chunks
- File data written to disk incrementally (constant memory usage)
- Boundary detection works across chunk boundaries
- Multiple files in a single upload are supported
- Partial files cleaned up on error (disk full, connection drop, timeout)
- Existing tests pass
- Client-side 200 MB check added to web UI
- Non-upload POST routes still use simple body reading
- API response format unchanged
</success_criteria>
