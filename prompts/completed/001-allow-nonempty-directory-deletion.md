<objective>
Modify the filesync KOReader plugin so users can delete non-empty directories. Currently, deletion of non-empty directories is blocked with the error "Cannot delete non-empty directory". Instead, when a user attempts to delete a non-empty directory, show a warning dialog displaying the total number of files (recursively counted) that will be deleted, with Cancel and Delete confirmation buttons.
</objective>

<context>
This is a KOReader plugin that provides a web-based file sync interface. The plugin has:
- A Lua backend handling file operations (`filesync/fileops.lua`)
- An HTTP server routing requests (`filesync/httpserver.lua`)
- A web UI with existing confirmation dialogs (`filesync/static/index.html`)
- A translation/i18n system for user-facing strings

Key existing patterns:
- `FileOps:_deleteRecursive(path)` already exists in fileops.lua (used only for `.sdr` cleanup) — reuse this pattern
- The web UI already has `showConfirm()` for delete confirmations
- The `/api/delete` endpoint handles deletion requests
- The `/api/files` endpoint returns directory metadata including `is_empty` flag
- Translation strings exist in both Lua (`filesync_i18n.lua`) and the web UI's embedded translations

Read `CLAUDE.md` for project conventions before starting.
</context>

<research>
Before making changes, read and understand these files thoroughly:
1. `filesync/fileops.lua` — Focus on the delete method (~lines 535-636), `_deleteRecursive()`, and the `is_empty` check in `listFiles()`
2. `filesync/httpserver.lua` — Focus on the `/api/delete` route handler and how errors propagate to the web UI
3. `filesync/static/index.html` — Focus on `deleteItem()`, `showConfirm()`, and the confirm dialog markup (~lines 1023-1033, 1932-1948)
4. `filesync/static/index.html` — Focus on the translation system and existing delete-related translation keys (~lines 1090-1241)
</research>

<requirements>

1. **Backend — Add recursive file counting** (`filesync/fileops.lua`):
   - Create a `_countFilesRecursive(path)` method that recursively counts all files (not directories) inside a directory tree
   - Return the total file count as an integer

2. **Backend — Add file count API endpoint or extend existing endpoint**:
   - Option A (preferred): Add a new API endpoint `GET /api/dirinfo?path=<path>` in `httpserver.lua` that returns `{ file_count: N }` for a given directory path
   - Option B: Extend the existing `/api/files` response to include recursive file count for directories (only when explicitly requested, to avoid performance issues on large directories)
   - Ensure proper path validation using the existing `_resolvePath()` method

3. **Backend — Modify delete to allow non-empty directories** (`filesync/fileops.lua`):
   - Remove the "Cannot delete non-empty directory" early return
   - Instead, use the existing `_deleteRecursive()` pattern to delete the directory and all its contents
   - Preserve all existing safety checks (root directory protection, path traversal prevention)
   - Preserve the `.sdr` metadata cleanup behavior

4. **Frontend — Update delete confirmation for directories** (`filesync/static/index.html`):
   - When deleting a non-empty directory, fetch the file count from the backend BEFORE showing the confirmation dialog
   - Show a warning message like: "This directory contains N files. All files will be permanently deleted."
   - Display Cancel and Delete buttons (matching existing dialog styling)
   - For empty directories, keep the current simple confirmation behavior
   - The `is_empty` flag from `/api/files` can be used to determine whether to fetch the count

5. **Translations**:
   - Add new translation keys for the warning message in all languages currently supported
   - Follow the existing i18n patterns in both Lua and the web UI
   - Key strings to translate: the directory deletion warning message with file count placeholder

</requirements>

<implementation>
- Follow existing code patterns exactly — match indentation, naming conventions, and error handling style
- The recursive file count should only count files, not subdirectories, so the user sees how many actual documents they're about to lose
- Use `lfs.dir()` and `lfs.attributes()` consistent with existing code patterns
- The confirmation dialog should be visually distinct/serious (use warning styling if available) since this is a destructive bulk operation
- Handle edge cases: permission errors during counting (return what you can count), very large directories (the count operation should not hang the UI — consider if a loading state is needed)
- Do NOT add a "select all" or partial deletion feature — this is strictly about allowing full directory deletion with informed consent
</implementation>

<verification>
Before declaring complete, verify:
1. Read through all modified files to ensure consistency with existing code style
2. Confirm the recursive count function handles nested directories correctly
3. Confirm the delete flow works for: empty directories, directories with files, directories with nested subdirectories
4. Confirm the `.sdr` metadata cleanup still works correctly after changes
5. Confirm all new user-facing strings have translations in every language the app supports
6. Confirm path traversal protection is maintained (no way to delete outside the root)
7. Confirm the web UI dialog renders correctly with the warning message and buttons
</verification>

<success_criteria>
- Non-empty directories can be deleted through the web UI
- Before deletion, users see a warning showing the exact number of files that will be removed
- Users can cancel or confirm the deletion
- Empty directory deletion behavior is unchanged
- All existing safety measures (path validation, root protection) remain intact
- No regressions in `.sdr` metadata cleanup
- All new strings are translated
</success_criteria>
