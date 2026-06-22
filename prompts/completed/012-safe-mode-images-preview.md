<objective>
Allow image files to appear in safe mode file listings and show image previews in the file detail view. Users upload screensaver/cover images (JPG, PNG, GIF, WebP) to their e-reader via FileSync and need to see them alongside books in safe mode, as well as preview them before deciding to keep or delete.
</objective>

<context>
This is a KOReader plugin (Lua backend + single-file HTML/JS frontend). The relevant files are:

- `./filesync/fileops.lua` — file operations, contains `SAFE_MODE_EXTENSIONS` whitelist and `_getFileType` classification
- `./filesync/httpserver.lua` — HTTP server, routes API requests including file downloads and the file listing API
- `./filesync/static/index.html` — web UI with file list and detail view

Safe mode currently only shows ebook and document formats. Image files (used for KOReader screensaver/cover art) are hidden in safe mode. The detail view currently shows file metadata (name, size, date, type) and action buttons (download, rename, delete) but has no image preview.

Read all three files to understand existing patterns before making changes.
</context>

<requirements>
1. **Add image extensions to safe mode whitelist** in `fileops.lua`:
   Add `jpg`, `jpeg`, `png`, `gif`, and `webp` to the `SAFE_MODE_EXTENSIONS` table. These are the common formats used for KOReader screensaver/sleep cover images.

2. **Serve image files with correct Content-Type** in `httpserver.lua`:
   Ensure the download/serving endpoint returns the correct MIME type for images so browsers can display them inline. Check if this already works — if the download endpoint forces a download via `Content-Disposition: attachment`, add a separate route or query parameter (e.g., `?preview=1`) that serves the image inline with the correct Content-Type (image/jpeg, image/png, image/gif, image/webp) instead of forcing a download.

3. **Show image preview in the detail view** in `index.html`:
   When a user taps on an image file (jpg, jpeg, png, gif, webp) in the file list, the detail view should display a preview/thumbnail of the image above the file metadata. The preview should:
   - Use an `<img>` tag pointing to the download endpoint (with inline serving)
   - Be responsive — fit within the detail view width while maintaining aspect ratio
   - Have a reasonable max-height so it doesn't push the action buttons off screen
   - Only show for image file types, not for ebooks or other files

4. **Localization**: Add any new user-facing strings to both `./filesync/i18n/en.po` and `./filesync/i18n/es.po`
</requirements>

<constraints>
- Do not modify how non-image files behave in the detail view
- Do not add any server-side image processing or thumbnail generation — serve the original file and let the browser handle display
- Follow existing code patterns and style in all files
- The image preview must work on mobile browsers (the primary use case is viewing from a phone)
</constraints>

<verification>
Before declaring complete:
1. Verify jpg, jpeg, png, gif, webp are in `SAFE_MODE_EXTENSIONS`
2. Verify the backend can serve images with correct Content-Type for inline display
3. Verify the detail view shows an image preview for image files
4. Verify non-image files still show the normal detail view without a preview
5. Verify new strings (if any) are in both .po files
</verification>

<success_criteria>
- Image files appear in file listings when safe mode is enabled
- Tapping an image file opens the detail view with a visual preview of the image
- The preview is responsive and doesn't break the detail view layout
- Non-image files are unaffected
- Images are served with correct MIME types
</success_criteria>
