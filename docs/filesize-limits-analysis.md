# Filesize Limits Analysis -- filesync.koplugin

## Summary

Quick reference table of all limits identified across all code paths.

| Path | Limit | Type | Value | Source |
|------|-------|------|-------|--------|
| Upload | MAX_BODY_SIZE | Hard | 50 MB | httpserver.lua:16 |
| Upload | Body held in memory | Hard | 50 MB (RAM) | httpserver.lua:209, fileops.lua:392 |
| Upload | Multipart body parsed via string ops | Hard | ~50 MB (RAM x2-3) | fileops.lua:410-424 |
| Upload | No disk-full error handling | Hard | Undefined | fileops.lua:452-454 |
| Upload | CONNECTION_TIMEOUT | Hard | 2 seconds | httpserver.lua:21 |
| Download | File read in 64 KB chunks (streamed) | None | Unlimited | httpserver.lua:376-387 |
| Download | Content-Length as Lua number | Theoretical | 2^53 (~9 PB) | httpserver.lua:372 |
| Download | CONNECTION_TIMEOUT per send | Soft | 2 seconds | httpserver.lua:21 |
| Download | lfs.attributes size field | Theoretical | Platform-dependent (2 GB or 4 GB on 32-bit) | fileops.lua:364 |
| File Listing | Entire listing in memory | Soft | RAM-bound | fileops.lua:219-276 |
| File Listing | JSON response in memory | Soft | RAM-bound | httpserver.lua:511-529 |
| Metadata (EPUB) | OPF read via unzip -p (into memory) | Soft | RAM-bound | fileops.lua:729-743 |
| Metadata (MOBI) | 64 KB header read | Hard (safe) | 64 KB | mobi.lua:37, 71 |
| Cover (MOBI) | Cover record size cap | Hard | 5 MB | mobi.lua:288 |
| Cover (EPUB) | Cover image read into memory | Soft | RAM-bound | fileops.lua:1000-1005 |
| Cover (EPUB/MOBI) | Cover data sent as single blob | Soft | RAM-bound | httpserver.lua:331 |
| Platform | LuaJIT max string length | Theoretical | ~2 GB (2^31 - 1) | LuaJIT internals |
| Platform | Lua double-precision integer accuracy | Theoretical | 2^53 (~9 PB) | IEEE 754 |
| Platform | 32-bit off_t (LFS/io) | Hard | 2 GB or 4 GB | Platform-dependent |
| Platform | Device RAM | Hard | 256-512 MB | Hardware constraint |

## Detailed Analysis

### 1. Upload Path (Web UI to Device)

#### 1.1 Client-Side (Browser)

**File input element** (`filesync/static/index.html:2109`):
```html
<input type="file" id="fileInput" multiple style="display:none" onchange="handleFileSelect(this.files)">
```
- No `accept` attribute -- any file type can be selected.
- No client-side file size check -- there is no JavaScript validation of `file.size` before upload begins.
- Files are uploaded individually via `XMLHttpRequest` (index.html:3323), one `FormData` per file. This means the browser does not combine multiple files into a single request body.
- No XHR timeout is set (`xhr.timeout` is never assigned), so the browser will wait indefinitely for the server.
- **Limit**: None enforced client-side. A user can select a 4 GB file and the browser will attempt to send it.

**Drag-and-drop** (`index.html:3393-3399`):
- Same path as file input; no additional limits.

#### 1.2 HTTP Layer (Server-Side)

**Content-Length parsing** (`httpserver.lua:166`):
```lua
local content_length = tonumber(headers["content-length"])
```
- `tonumber()` returns a Lua `double`. Exact integer representation up to 2^53 (9,007,199,254,740,992 bytes = ~9 PB). This is not a practical concern.

**MAX_BODY_SIZE check** (`httpserver.lua:16, 168-170`):
```lua
local MAX_BODY_SIZE = 50 * 1024 * 1024  -- 52,428,800 bytes
if content_length > MAX_BODY_SIZE then
    self:_sendError(client, 413, "Payload Too Large")
    return
end
```
- **Hard limit: 50 MB**. Any upload with `Content-Length > 50 MB` is rejected with HTTP 413.
- This is the **primary upload bottleneck**. A multipart upload of a single 45 MB file will exceed 50 MB once the multipart headers and boundary delimiters are included, so the effective per-file limit is slightly below 50 MB.

**Body reading** (`httpserver.lua:191-209`):
```lua
function HttpServer:_readBody(client, length)
    local MAX_CHUNK = 65536
    local parts = {}
    local remaining = length
    while remaining > 0 do
        local chunk_size = math.min(remaining, MAX_CHUNK)
        local data, err, partial = client:receive(chunk_size)
        ...
        table.insert(parts, data)
        ...
    end
    return table.concat(parts)
end
```
- The body is read in 64 KB chunks into a `parts` table, then **concatenated into a single string** via `table.concat(parts)`.
- **Memory impact**: At peak, the body exists both as individual chunks in the `parts` table AND as the final concatenated string. For a 50 MB upload, this means ~100 MB of transient memory usage before the parts table is garbage collected.
- The `table.concat` call itself needs enough contiguous memory for the full result string.

**CONNECTION_TIMEOUT** (`httpserver.lua:21, 113`):
```lua
local CONNECTION_TIMEOUT = 2
client:settimeout(CONNECTION_TIMEOUT)
```
- Each `client:receive(chunk_size)` call has a 2-second timeout.
- For a slow WiFi connection, receiving 64 KB within 2 seconds requires at least ~32 KB/s throughput per chunk. Over typical home WiFi (even to an e-reader), this is usually fine.
- However, if there's a momentary network stall lasting >2 seconds during the upload, the receive will return a partial read. The code does handle partial reads (`httpserver.lua:202-204`), so a single stall won't lose data -- but if the partial is 0 bytes, `remaining` will never reach 0 and the loop will `break`, resulting in a truncated body.
- **For large files near 50 MB**: at 1 MB/s (slow WiFi), the full body takes ~50 seconds. Each 64 KB chunk takes ~64 ms, well within the 2-second timeout. This is generally fine.

#### 1.3 Multipart Parsing

**Upload handler** (`fileops.lua:392-471`):
```lua
function FileOps:handleUpload(dir, body, boundary)
```
- The `body` parameter is the **entire HTTP body as a single Lua string** (up to 50 MB).
- Multipart parsing uses `string:find()` and `string:sub()` for boundary splitting (`fileops.lua:410-424`).
- **Memory**: The body string (up to 50 MB) is sliced into `parts` via `string:sub()`, which creates new string copies. The file data is extracted via another `string:sub()` call (`fileops.lua:432`). At peak, memory may hold: the original body (~50 MB) + extracted parts table + individual file data strings. This could reach **2-3x the body size** (~100-150 MB) before GC.

#### 1.4 Disk Write

**File writing** (`fileops.lua:451-454`):
```lua
local f = io.open(file_path, "wb")
if f then
    f:write(file_data)
    f:close()
```
- The entire file content is written in a single `f:write()` call.
- **Disk-full handling**: The return value of `f:write()` is not checked. If the disk is full, `f:write()` may write a partial file or fail silently, and the function reports success. The file could be left in a corrupted/truncated state.
- **No cleanup on failure**: If the write partially succeeds, the incomplete file remains on disk.

#### 1.5 Upload Path Summary

The critical bottleneck is `MAX_BODY_SIZE = 50 MB`. This is a hard server-side limit that cannot be bypassed. The client sends no size check, so users will see a `413 Payload Too Large` error for files over ~48 MB (accounting for multipart overhead). Memory usage during a max-size upload peaks at approximately 100-150 MB, which is problematic on devices with 256 MB RAM.

---

### 2. Download Path (Device to Web UI)

#### 2.1 File Size Detection

**lfs.attributes** (`fileops.lua:364`):
```lua
local attr = lfs.attributes(full_path)
...
size = attr.size,
```
- `lfs.attributes` returns `size` as a Lua number. On 32-bit systems with standard `off_t`, this may be limited to 2 GB (signed 32-bit) or 4 GB (unsigned 32-bit). KOReader devices are typically 32-bit ARM.
- KOReader's bundled LFS implementation may or may not use 64-bit `off_t`. If it uses standard 32-bit `off_t`, files larger than 2 GB will report incorrect sizes (wrapping negative or truncated).
- **Inferred limit**: 2 GB on 32-bit platforms without large file support; 4 GB with unsigned 32-bit. Confirmed only by platform specifics, not visible in this code.

#### 2.2 Content-Length Header

**Header construction** (`httpserver.lua:372`):
```lua
["Content-Length"] = tostring(result.size),
```
- `tostring()` on a Lua double will produce exact integer output up to 2^53. However, if `lfs.attributes` already returned a truncated/wrong value, the Content-Length will also be wrong.

#### 2.3 Streaming

**Chunked file streaming** (`httpserver.lua:376-387`):
```lua
local CHUNK_SIZE = 65536
local stream_ok = true
while stream_ok do
    local chunk = result.file_handle:read(CHUNK_SIZE)
    if not chunk then break end
    local sent, send_err = self:_sendAll(client, chunk)
    if not sent then
        logger.warn("FileSync HTTP: send error during download:", send_err)
        stream_ok = false
    end
end
result.file_handle:close()
```
- **Streaming is properly implemented**. The file is read 64 KB at a time and sent immediately. Only one 64 KB chunk is in memory at a time.
- `CHUNK_SIZE = 65536` (64 KB) is hardcoded, not configurable.
- `file:read(CHUNK_SIZE)` reads up to 64 KB per call. This is efficient and does not load the entire file.
- **Memory usage during download**: approximately 64 KB per active download, regardless of file size. This is well-designed.

#### 2.4 Timeout Considerations

- `client:settimeout(CONNECTION_TIMEOUT)` = 2 seconds applies to each `client:send()` call within `_sendAll`.
- `_sendAll` (`httpserver.lua:494-508`) handles partial sends correctly, looping until all data is sent.
- For each 64 KB chunk, the 2-second timeout applies to each `send()` attempt. If a single `send()` cannot deliver any bytes within 2 seconds, it will fail, and the download will abort.
- **For large files**: A 1 GB file at 64 KB chunks = ~16,384 iterations. Each iteration is independent with its own timeout budget. As long as each chunk can be sent within 2 seconds (requiring ~32 KB/s sustained throughput), the download will complete. Total time for 1 GB at 5 MB/s = ~200 seconds. This is fine.

#### 2.5 UI Blocking During Download

- `MAX_POLL_TIME = 3` seconds (`httpserver.lua:24`) limits how long the poll loop runs before yielding to UIManager.
- However, once a download starts within `_handleClient`, the entire streaming loop runs synchronously. A large download **blocks the UI** for its full duration.
- For a 1 GB file at 5 MB/s, this is approximately 200 seconds of unresponsive UI. At 1 MB/s, it is ~1000 seconds (~17 minutes).
- **Soft limit**: Large downloads make the e-reader UI unresponsive.

#### 2.6 Client-Side Download

**Browser download** (`index.html:2945-2951`):
```javascript
window.downloadFile = function(path) {
    var a = document.createElement('a');
    a.href = '/api/download?path=' + encodeURIComponent(path);
    a.download = '';
    document.body.appendChild(a);
    a.click();
```
- Standard browser download via anchor click. The browser handles the download natively.
- No client-side limits on download size. Modern browsers can handle multi-GB downloads.

#### 2.7 Download Path Summary

Downloads are well-implemented with proper streaming. The primary concern is UI blocking during large downloads and potential 32-bit `off_t` limitations for files > 2 GB. Memory usage is minimal (~64 KB).

---

### 3. File Listing / Directory Operations

#### 3.1 Directory Iteration

**listDirectory** (`fileops.lua:208-334`):
- Iterates all entries via `lfs.dir()` (`fileops.lua:221`).
- For each entry, calls `lfs.attributes()` (`fileops.lua:233`) and for directories, also iterates children to check emptiness (`fileops.lua:254-260`).
- All entries are accumulated into a Lua table (`entries`) in memory (`fileops.lua:269`).
- **Memory**: Each entry is a Lua table with ~10 fields (name, path, is_dir, size, size_formatted, modified, type, is_empty, has_sdr). For 1,000 files, this is moderate. For 10,000+ files, the table itself could consume several MB.

#### 3.2 Sorting

- `table.sort()` (`fileops.lua:286`) operates in-place, so no additional memory.

#### 3.3 JSON Serialization

**JSON.encode** (`filesync/json.lua:43-84`):
- Recursive encoder. Each table is visited, and the entire JSON output is built as a concatenation of encoded fragments via `table.concat`.
- For a directory with 1,000 files, each producing ~200 bytes of JSON, the output is ~200 KB. For 10,000 files, ~2 MB. This is manageable.
- The JSON encoder uses recursion. For deeply nested structures, stack depth could be a concern, but directory listings are flat (array of objects), so this is not an issue.

**Response construction** (`httpserver.lua:510-529`):
```lua
function HttpServer:_sendJSON(client, status, data)
    local json_body = JSON.encode(data)
    ...
    local response = table.concat({...json_body...})
    self:_sendAll(client, response)
end
```
- The entire JSON response is built in memory as a single string, then sent. No streaming of the JSON response.
- **Soft limit**: For very large directory listings (e.g., 50,000 files), the JSON response could be 10+ MB, consuming significant memory. However, the entire response is sent before the connection closes, and memory is freed after.

#### 3.4 Recursive File Count

**getDirInfo / _countFilesRecursive** (`fileops.lua:337-639`):
- Recursive directory traversal counting all files.
- Uses actual recursion (function calls itself at `fileops.lua:627`).
- **Stack depth**: For extremely deep directory hierarchies (hundreds of levels), this could overflow the Lua call stack. LuaJIT default stack size is 64 KB; each frame uses ~100-200 bytes, so the limit is roughly 300-500 levels deep. Practical directory depths rarely exceed 20 levels.

#### 3.5 File Listing Summary

File listing is memory-bound. Directories with thousands of files will consume several MB of RAM for the Lua tables and JSON string. This is a soft limit. Extremely large directories (50,000+ files) could strain a 256 MB device.

---

### 4. Metadata Extraction

#### 4.1 EPUB Metadata

**OPF extraction** (`fileops.lua:724-821`):
- Uses external `unzip -p` command via `io.popen` to extract specific files from the EPUB ZIP archive.
- **container.xml** (`fileops.lua:728-733`): Read entirely into memory via `read("*all")`. Container.xml files are typically < 1 KB.
- **OPF file** (`fileops.lua:739-743`): Read entirely into memory via `read("*all")`. OPF files are typically 1-50 KB, but can reach several hundred KB for books with extensive metadata or large spine/manifest sections.
- **No explicit size limit** on the OPF content read. A maliciously crafted EPUB with a huge OPF could consume significant memory, but this is unlikely in practice.

#### 4.2 EPUB Cover Extraction

**Cover image extraction** (`fileops.lua:997-1009`):
```lua
local img_handle = io.popen(extract_cmd)
...
local img_data = img_handle:read("*all")
```
- The entire cover image is read into a Lua string via `read("*all")`.
- Cover images are typically 50-500 KB (JPEG) or up to 2-3 MB (high-res PNG).
- **Memory**: The image data string is then sent in the HTTP response (`httpserver.lua:331`):
  ```lua
  self:_sendAll(client, cover.data)
  ```
  The cover data is held in memory from extraction through sending. No streaming.
- **Soft limit**: A very large cover image (e.g., 10 MB PNG) would consume 10 MB of memory during the request.

#### 4.3 MOBI/AZW3 Metadata

**Header parsing** (`mobi.lua:31-228`):
```lua
local header_data = f:read(65536)  -- 64 KB
```
- Only the first 64 KB of the file is read for initial header parsing (`mobi.lua:37`).
- If the first PDB record extends beyond this buffer, an additional 64 KB is read from the record offset (`mobi.lua:71`).
- **Total maximum read for metadata**: 128 KB (two 64 KB reads). This is very efficient.
- For MOBI files with many PDB records where the first_image_record is invalid, a backwards scan reads 4-byte magic headers from the end of the record table (`mobi.lua:117-131`). Each read is 4 bytes. For a book with 1,000 records, this is at most ~4,000 bytes of I/O (many small seeks).

#### 4.4 MOBI/AZW3 Cover Extraction

**Cover extraction** (`mobi.lua:235-322`):
- Re-parses metadata to find cover record index.
- Reads the PDB record containing the cover image.
- **Record size cap** (`mobi.lua:288`):
  ```lua
  if record_size <= 0 or record_size > 5 * 1024 * 1024 then
      f:close()
      return nil, nil
  end
  ```
  - **Hard limit: 5 MB** per cover record. If the computed record size exceeds 5 MB, extraction is silently aborted.
  - If the record size cannot be determined (last record), falls back to 2 MB max read (`mobi.lua:284`):
    ```lua
    record_size = 2 * 1024 * 1024
    ```
- The entire cover record is read into memory in one `f:read(record_size)` call (`mobi.lua:295`).
- **Memory**: Up to 5 MB for the cover image data.

#### 4.5 Metadata Summary

Metadata extraction is well-bounded for MOBI/AZW3 (128 KB for headers, 5 MB max for covers). EPUB extraction relies on external `unzip` and `read("*all")`, which is unbounded but practically limited to the size of individual files within the EPUB archive (typically small).

---

### 5. Platform Constraints

#### 5.1 Lua Number Type

- KOReader uses LuaJIT, which uses double-precision IEEE 754 floats for all numbers (no separate integer type in Lua 5.1).
- **Maximum exact integer**: 2^53 = 9,007,199,254,740,992 (~9 PB). File sizes will be exactly representable up to this value.
- **Confirmed**: `tonumber()` on Content-Length (`httpserver.lua:166`) and `lfs.attributes().size` both produce Lua doubles. This is not a practical concern for file sizes.

#### 5.2 LuaJIT String Length

- LuaJIT strings have a maximum length of approximately 2^31 - 1 bytes (~2 GB) on 32-bit platforms.
- **Confirmed**: This is a theoretical upper bound. Allocating a 2 GB string on a device with 256-512 MB RAM would fail with an out-of-memory error long before hitting the string length limit.
- **Practical limit**: Device RAM is the binding constraint, not string length.

#### 5.3 LuaFileSystem (lfs.attributes)

- `lfs.attributes` returns file size via the C `stat()` call.
- On 32-bit Linux (KOReader's target platforms -- Kindle, Kobo):
  - With `_FILE_OFFSET_BITS=64` or `stat64`: sizes up to 2^63 are supported.
  - Without large file support: `off_t` is 32-bit signed, limiting to 2^31 - 1 = 2,147,483,647 bytes (~2 GB).
- **Inferred**: KOReader's build system likely enables large file support (`-D_FILE_OFFSET_BITS=64`), but this should be verified. If not enabled, files > 2 GB will report incorrect sizes.

#### 5.4 io.open / file:read / file:write

- `file:read(n)` reads up to `n` bytes. No inherent limit on `n` beyond available memory.
- `file:read("*all")` reads the entire file into a Lua string. Bounded by available memory and LuaJIT string length.
- `file:write(data)` writes the entire string. No chunking. For very large strings, this is a single `fwrite()` call, which the C library handles internally.
- `file:seek("set", offset)` uses `fseek()` which is limited by `off_t` size (same as lfs.attributes concern above).

#### 5.5 LuaSocket Limits

- LuaSocket's `socket:receive(n)` has no inherent buffer size limit; it reads up to `n` bytes per call.
- `socket:send(data, offset)` sends data starting from the given offset. The data string must fit in memory, but partial sends are handled correctly in `_sendAll`.
- LuaSocket does not impose artificial limits on transfer sizes.

---

### 6. Explicit Constants

All hardcoded constants that affect filesize handling:

| Constant | Value | File:Line | Purpose | Assessment |
|----------|-------|-----------|---------|------------|
| `MAX_BODY_SIZE` | 50 MB (52,428,800 bytes) | httpserver.lua:16 | Maximum HTTP request body size | **Primary upload limit.** Reasonable for e-readers but restrictive for large ebooks. Many PDFs, comics (CBZ/CBR), and audiobooks exceed 50 MB. |
| `MAX_CHUNK` (body read) | 64 KB (65,536 bytes) | httpserver.lua:192 | Chunk size for reading request body | Appropriate. Balances memory vs. syscall overhead. |
| `CHUNK_SIZE` (download) | 64 KB (65,536 bytes) | httpserver.lua:376 | Chunk size for streaming file downloads | Appropriate. Could be increased to 256 KB for better throughput but 64 KB is fine. |
| `CONNECTION_TIMEOUT` | 2 seconds | httpserver.lua:21 | Per-socket operation timeout | Tight but intentional -- prevents UI stalls. May cause issues on very slow connections. |
| `MAX_POLL_TIME` | 3 seconds | httpserver.lua:24 | Maximum wall-clock time per poll cycle | Does not directly affect file transfers (those run inside a single connection handler). |
| `MAX_HEADER_COUNT` | 100 | httpserver.lua:18 | Maximum HTTP headers per request | Standard; not filesize-related. |
| Header read (MOBI) | 64 KB (65,536 bytes) | mobi.lua:37, 71 | MOBI/PDB header buffer size | Appropriate. Covers all known MOBI header formats. |
| Cover record max (MOBI) | 5 MB | mobi.lua:288 | Maximum MOBI cover record size | Appropriate. Cover images exceeding 5 MB are extremely rare. |
| Cover record fallback (MOBI) | 2 MB | mobi.lua:284 | Fallback max read when record size unknown | Appropriate. |
| Filename max length | 255 bytes | fileops.lua:96 | Maximum filename length | Standard filesystem limit. |

---

## Recommendations

Ordered by priority (highest first):

### P0 -- Critical

1. **Raise or make `MAX_BODY_SIZE` configurable** (`httpserver.lua:16`)
   - 50 MB is too low for common use cases: large PDFs (textbooks, technical manuals), comic archives (CBZ/CBR), and audiobooks regularly exceed 100 MB.
   - However, simply raising the limit without streaming the upload to disk is dangerous on 256 MB devices, because the entire body is held in memory.
   - **Recommended approach**: Implement streaming upload -- parse the multipart body incrementally and write file data to disk as it arrives, instead of accumulating the full body in memory. This would effectively remove the filesize limit (bounded only by disk space).
   - **Short-term alternative**: Raise to 200 MB with a clear warning that large uploads will temporarily use significant memory. Add a client-side file size check in the JavaScript to warn users before uploading.

2. **Add client-side file size validation** (`index.html`, `uploadFile` function around line 3302)
   - Before uploading, check `file.size` against the server's known limit and display an error message instead of letting the upload proceed only to receive a 413 error after the full transfer completes.

### P1 -- High

3. **Check `f:write()` return value on upload** (`fileops.lua:453`)
   - `f:write(file_data)` can fail silently if the disk is full. Check the return value, and if the write fails, delete the partial file and return an error.

4. **Address UI blocking during large downloads** (`httpserver.lua:376-387`)
   - A 500 MB download blocks the KOReader UI for minutes. Consider yielding to UIManager periodically during the streaming loop (e.g., every N chunks), or document that users should expect the UI to be unresponsive during downloads.

### P2 -- Medium

5. **Stream multipart parsing to disk** (`fileops.lua:392-471`)
   - Currently, the entire multipart body (up to MAX_BODY_SIZE) is parsed from a single in-memory string. Even with MAX_BODY_SIZE = 50 MB, peak memory usage during parsing can reach 100-150 MB. Stream the multipart data directly to disk files during the body read phase.

6. **Document the 50 MB upload limit in the web UI**
   - Add a note in the upload dropzone area indicating the maximum file size. This prevents user confusion when large uploads fail.

### P3 -- Low

7. **Verify 32-bit large file support**
   - Confirm that KOReader's LFS and io libraries are built with `_FILE_OFFSET_BITS=64` to support files > 2 GB on 32-bit ARM platforms. If not, downloads of files > 2 GB will have incorrect Content-Length headers.

8. **Consider increasing download CHUNK_SIZE** (`httpserver.lua:376`)
   - 64 KB is conservative. Increasing to 128 KB or 256 KB would reduce the number of iterations and syscalls for large downloads with minimal memory impact.

9. **Add configurable XHR timeout on client** (`index.html`)
   - Currently no XHR timeout is set for uploads. While this is fine for normal use (the browser waits indefinitely), adding a generous timeout (e.g., 10 minutes) would prevent zombie upload connections.

---

## Worst-Case Scenarios

### Uploading a 1 GB file

1. User selects a 1 GB file in the browser.
2. Browser begins sending the file via XMLHttpRequest.
3. Server reads the `Content-Length: 1073741824` header.
4. Server compares against `MAX_BODY_SIZE` (50 MB): **1 GB > 50 MB**.
5. Server returns HTTP 413 "Payload Too Large".
6. **Result**: Upload rejected immediately after headers are read. The browser may have already sent some data, which is discarded. The user sees a "Failed" status in the upload progress UI.
7. **Memory impact**: Minimal -- the body is never read.

### Uploading a 45 MB file (just under limit)

1. User uploads a 45 MB PDF. With multipart overhead (~200 bytes), total body is ~45.0002 MB.
2. Server accepts the body (under 50 MB limit).
3. Body is read in 64 KB chunks into a `parts` table (~690 chunks).
4. `table.concat(parts)` creates a ~45 MB string. **Peak memory: ~90 MB** (parts table + concatenated string).
5. Multipart parsing creates additional string copies. **Peak memory: ~135 MB**.
6. File is written to disk in a single `f:write()` call.
7. Lua garbage collector eventually frees the strings.
8. **Result**: Upload succeeds, but on a 256 MB device, 135 MB of memory usage may trigger memory pressure (KOReader itself uses 50-100 MB), potentially causing OOM or severe swapping.

### Downloading a 1 GB file

1. User clicks download on a 1 GB file.
2. `lfs.attributes` reports size (assuming large file support works).
3. Server sends `Content-Length: 1073741824` header.
4. Server streams file in 64 KB chunks: ~16,384 iterations.
5. At 5 MB/s WiFi throughput, download takes ~200 seconds.
6. **UI is blocked for ~200 seconds** (the e-reader screen is unresponsive).
7. Memory usage: ~64 KB (one chunk at a time).
8. **Result**: Download completes successfully. User cannot interact with the e-reader during the transfer.

### Downloading a 4 GB file (on 32-bit platform without large file support)

1. User clicks download on a 4 GB file.
2. `lfs.attributes` returns a size that may be incorrect (wrapped to a negative number or truncated).
3. `Content-Length` header may be wrong (e.g., negative or truncated value).
4. File streaming begins and reads the full file in 64 KB chunks (file:read is unaffected by the stat issue).
5. **Result**: The browser may show incorrect download progress or file size, but the actual data transfer should complete. However, the browser may abort if Content-Length does not match the actual data received.

### Directory with 50,000 files

1. User navigates to a directory containing 50,000 files.
2. `listDirectory` iterates all 50,000 entries, calling `lfs.attributes` for each.
3. 50,000 entry tables are created in memory (each ~10 fields = ~500 bytes = ~25 MB total).
4. `table.sort` sorts in-place.
5. JSON encoding produces ~10 MB of JSON text.
6. Total response (headers + JSON) is ~10 MB, built as a single string.
7. **Peak memory**: ~35 MB (Lua tables + JSON string).
8. Server sends the response.
9. **Result**: Succeeds but is slow. The `lfs.attributes` calls alone (50,000 stat syscalls) may take 10-30 seconds on a slow e-reader filesystem.

---

*Analysis performed on commit `dd3d207` (branch `chore/code_refactor_improvement`). All line numbers reference the current state of the working tree.*
