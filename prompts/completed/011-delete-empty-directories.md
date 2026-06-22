<objective>
Add a delete button for empty directories in the FileSync web interface. Currently, only files have delete functionality (via the detail view). Directories should show a delete option when they contain no files or subdirectories, so users can clean up empty folders from their e-reader.
</objective>

<context>
This is a KOReader plugin with a Lua HTTP backend and a single-file HTML/JS frontend. The relevant files are:

- `./filesync/httpserver.lua` — HTTP server that routes API requests
- `./filesync/fileops.lua` — file operations (CRUD) with security validation
- `./filesync/static/index.html` — self-contained web UI (HTML + CSS + JS)

The plugin has a "safe mode" setting that filters non-book files. Delete operations already exist for files and require a confirmation dialog. The backend already has a delete endpoint (`/api/delete`) used for files.

Read these three files to understand the existing patterns before making changes.
</context>

<requirements>
1. **Backend — emptiness check**: Add a way for the frontend to know whether a directory is empty. Either:
   - Include an `is_empty` or `child_count` field in the `/api/files` directory listing response for directory entries, OR
   - Add a dedicated endpoint to check if a directory is empty before deletion.
   Prefer the first approach (adding a field to existing response) for simplicity.

2. **Backend — directory deletion**: Ensure the `/api/delete` endpoint (or a new one) can delete empty directories. It must:
   - Verify the directory is empty before deleting (refuse to delete non-empty directories)
   - Respect safe mode restrictions
   - Apply the same path validation/security as file deletion

3. **Frontend — delete button on directories**: In the file list, show a delete icon/button on directory entries only when the directory is empty. Follow the existing UI patterns:
   - Use the same trash icon and confirmation dialog used for file deletion
   - The button should be visible directly in the file list row for empty directories (no need to enter a detail view for directories)
   - Non-empty directories should not show a delete button

4. **Localization**: Add any new user-facing strings to the i18n system (both `./filesync/i18n/en.po` and `./filesync/i18n/es.po`)
</requirements>

<constraints>
- Do not allow deletion of non-empty directories — this is a safety requirement to prevent accidental data loss
- Do not add recursive directory deletion
- Follow existing code patterns and style in all three files
- Keep the UI consistent with the current design (refer to existing button styles, icon usage, confirmation dialogs)
</constraints>

<verification>
Before declaring complete:
1. Verify the backend returns emptiness info for directories in the file listing
2. Verify the backend refuses to delete non-empty directories with an appropriate error message
3. Verify the frontend only shows the delete button on empty directories
4. Verify the confirmation dialog appears before deletion
5. Verify new strings are added to both .po files
6. Search for any hardcoded strings that should be localized
</verification>

<success_criteria>
- Empty directories show a delete button in the file list
- Non-empty directories do not show a delete button
- Tapping delete shows a confirmation dialog
- After confirming, the directory is deleted and the file list refreshes
- Attempting to delete a non-empty directory via API returns an error
- All new strings are localized in en.po and es.po
</success_criteria>
