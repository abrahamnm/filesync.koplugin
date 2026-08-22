<objective>
Thoroughly analyze the theoretical filesize limits of the filesync.koplugin when handling files across all code paths: uploading from the web interface, downloading from the web interface, and any internal file operations (listing, metadata extraction, cover extraction). This analysis will help the maintainer understand where the plugin may fail with large files and whether any limits need to be raised or documented.
</objective>

<context>
This is a KOReader plugin written in Lua that runs an HTTP server on e-reader devices (Kindle, Kobo). These devices have limited RAM (typically 256MB-512MB), slow CPUs, and storage ranging from 4GB to 32GB. Understanding filesize limits is critical because users may try to transfer large files (100MB+ PDFs, comics, audiobooks) and the plugin must either handle them gracefully or fail with a clear error.

Key files to analyze:
- `filesync/httpserver.lua` — HTTP server, request parsing, body reading, response streaming
- `filesync/fileops.lua` — File operations, upload handling, download streaming, metadata extraction
- `filesync/mobi.lua` — MOBI/AZW3 binary parser for metadata and cover extraction
- `filesync/json.lua` — JSON encoder/decoder (for API responses containing file listings)
- `filesync/filesyncmanager.lua` — Server configuration, port settings
- `filesync/static/index.html` — Web UI (check for any client-side limits in JavaScript)

Read ALL of these files before beginning your analysis.
</context>

<analysis_requirements>
For each code path below, trace the data flow end-to-end and identify every point where filesize could be limited, either explicitly (constants, checks) or implicitly (memory allocation, string operations, integer overflow, timeout).

### 1. Upload Path (Web UI → Device)
Trace from the browser's HTTP POST through to the file being written to disk:
- Client-side: Any JavaScript limits on file selection or chunking?
- HTTP layer: Content-Length parsing (what data type? max value?), body size limit, multipart parsing
- Memory: Is the entire upload body read into memory at once, or streamed/chunked?
- Disk write: How is the file written? Buffered? What happens if disk is full?
- Timeout: Could a large upload exceed the connection timeout?

### 2. Download Path (Device → Web UI)
Trace from the HTTP GET request through to the browser receiving the file:
- File size detection: How is file size determined? What data types are used?
- Streaming: Is the file streamed in chunks or read entirely into memory?
- Chunk size: What is the chunk size? Is it configurable?
- Content-Length header: What happens with files larger than Lua's number precision?
- Timeout: Could a large download exceed the connection timeout?

### 3. File Listing / Directory Operations
- What happens when a directory contains thousands of files?
- Is the entire listing built in memory as a Lua table before JSON serialization?
- What are the limits of the JSON encoder for large responses?

### 4. Metadata Extraction
- EPUB: How much data is read from the EPUB file? Is the entire file extracted?
- MOBI: How much of the MOBI file is read into memory for header parsing?
- Cover extraction: Are cover images loaded entirely into memory?

### 5. Lua/Platform Constraints
- Lua number type: What is the maximum integer that can be represented exactly? (Lua 5.1/LuaJIT uses double-precision floats — max exact integer is 2^53)
- LuaSocket: Any known limits on send/receive buffer sizes?
- LFS (LuaFileSystem): What does `lfs.attributes` return for file sizes > 2GB or > 4GB?
- `io.open` / `file:read` / `file:write`: Any limits on read/write sizes?
- `string` type: Maximum string length in LuaJIT?

### 6. Explicit Limits
- List all hardcoded constants that affect filesize (MAX_BODY_SIZE, chunk sizes, buffer sizes, timeouts)
- For each, state the current value, what it limits, and whether it's appropriate

For each limit identified, classify it as:
- **Hard limit**: Will cause an error or crash
- **Soft limit**: Will cause degraded performance (slowness, high memory usage)
- **Theoretical limit**: Unlikely to be hit in practice but exists mathematically
</analysis_requirements>

<output_format>
Save the analysis to `./docs/filesize-limits-analysis.md` with this structure:

```markdown
# Filesize Limits Analysis — filesync.koplugin

## Summary
[Quick reference table of all limits found]

| Path | Limit | Type | Value | Source |
|------|-------|------|-------|--------|
| Upload | ... | Hard | ... | httpserver.lua:XX |
| ... | ... | ... | ... | ... |

## Detailed Analysis

### 1. Upload Path
[End-to-end trace with specific line references]

### 2. Download Path
[End-to-end trace with specific line references]

### 3. File Listing
[Analysis with line references]

### 4. Metadata Extraction
[Analysis with line references]

### 5. Platform Constraints
[Lua/LuaJIT/LuaSocket/LFS limits]

### 6. Explicit Constants
[Table of all hardcoded limits]

## Recommendations
[Ordered by priority: what should be changed, documented, or left as-is]

## Worst-Case Scenarios
[What happens if someone tries to upload/download a 1GB file? 4GB? 10GB?]
```
</output_format>

<constraints>
- This is an ANALYSIS ONLY — do NOT modify any source code
- Reference specific files and line numbers for every claim
- Distinguish between confirmed limits (verified in code) and inferred limits (based on Lua/platform documentation)
- Consider the target platform: e-readers with 256MB-512MB RAM, ARM processors
- Account for LuaJIT specifics (KOReader uses LuaJIT, not standard Lua 5.1)
</constraints>

<verification>
Before completing:
- Confirm all 6 analysis areas are covered
- Verify every file:line reference is accurate
- Ensure the summary table captures all identified limits
- Check that recommendations are actionable and prioritized
</verification>

<success_criteria>
- All source files have been read and analyzed
- Every filesize-relevant code path has been traced end-to-end
- All explicit and implicit limits are identified with file:line references
- Summary table provides a quick reference of all limits
- Recommendations section prioritizes what matters most for real-world usage
- Output saved to ./docs/filesize-limits-analysis.md
</success_criteria>
