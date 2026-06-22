<objective>
Act as a senior software engineer with deep expertise in Lua programming and maintaining open-source KOReader plugins. Your task is to perform a comprehensive maintainability audit of this codebase and produce a detailed, prioritized roadmap of improvements.

This is a KOReader plugin (filesync.koplugin) written in Lua. The roadmap you produce will be reviewed by the maintainer before any changes are made, so focus on thoroughness and clarity.
</objective>

<context>
Read the project's CLAUDE.md first if it exists, then systematically explore every source file in the codebase.

Key files to examine:
- `main.lua` - Plugin entry point
- `_meta.lua` - Plugin metadata
- `filesync/*.lua` - All module files (httpserver, filesyncmanager, fileops, updater, filesync_i18n, qrcode)

Also review:
- Any configuration files, CI/CD workflows, or build scripts
- README and documentation
- Git history for recurring pain points (use `git log --oneline -30`)
</context>

<analysis_requirements>
Thoroughly analyze each file and the codebase as a whole across these dimensions:

1. **Code Structure and Modularity**
   - Are modules well-separated with clear responsibilities?
   - Are there circular dependencies or tight coupling?
   - Is there duplicated logic that could be consolidated?

2. **Naming Conventions and Readability**
   - Are variable, function, and module names consistent and descriptive?
   - Is the naming style consistent across files (snake_case, camelCase, etc.)?
   - Are there misleading or ambiguous names?

3. **Error Handling and Robustness**
   - Are errors caught and handled gracefully?
   - Are there unprotected calls that could crash the plugin?
   - Are edge cases handled (nil values, empty strings, missing files)?

4. **Lua Best Practices**
   - Proper use of `local` declarations (no accidental globals)
   - Efficient table usage and string operations
   - Proper use of metatables and OOP patterns (if applicable)
   - Memory management considerations

5. **Documentation**
   - Are public functions documented with purpose, parameters, and return values?
   - Are complex algorithms or non-obvious logic explained?
   - Is there a clear module-level description in each file?

6. **Testability**
   - Can modules be tested in isolation?
   - Are there hard-coded dependencies that prevent unit testing?
   - Do any test files or test infrastructure exist?

7. **API Surface and Contracts**
   - Are module interfaces clean and minimal?
   - Are internal implementation details properly encapsulated?

8. **Security Considerations**
   - Input validation on external data (HTTP requests, file paths)
   - Path traversal protection
   - Injection risks in string concatenation
</analysis_requirements>

<output_format>
Produce a single markdown document saved to `./docs/maintainability-roadmap.md` with this structure:

```markdown
# Maintainability Roadmap — filesync.koplugin

## Executive Summary
[2-3 paragraph overview of current codebase health and key findings]

## Codebase Overview
[Brief description of each module and its role]

## Findings by Category

### 1. Code Structure and Modularity
- **Current State**: [assessment]
- **Issues Found**: [list with file:line references]
- **Recommended Changes**: [specific, actionable items]

### 2. Naming Conventions and Readability
[same structure]

### 3. Error Handling and Robustness
[same structure]

### 4. Lua Best Practices
[same structure]

### 5. Documentation
[same structure]

### 6. Testability
[same structure]

### 7. API Surface and Contracts
[same structure]

### 8. Security Considerations
[same structure]

## Prioritized Roadmap

### Phase 1: Quick Wins (Low risk, high impact)
- [ ] Item 1 — [file(s) affected] — [description]
- [ ] Item 2 — ...

### Phase 2: Structural Improvements (Medium effort)
- [ ] Item 1 — [file(s) affected] — [description]
- [ ] Item 2 — ...

### Phase 3: Deeper Refactors (Higher effort, still conservative)
- [ ] Item 1 — [file(s) affected] — [description]
- [ ] Item 2 — ...

## Out of Scope
[Changes that would improve the codebase but require breaking changes or major restructuring — noted for future consideration]
```
</output_format>

<constraints>
- This is an AUDIT ONLY — do NOT modify any source code
- All recommendations must be conservative: non-breaking, no changes to the plugin's external interface or behavior
- Reference specific files and line numbers when identifying issues
- Each recommendation must be concrete and actionable, not vague ("improve error handling" is too vague; "wrap the HTTP listener in filesync/httpserver.lua:45 with pcall to handle connection failures" is good)
- Consider KOReader's plugin conventions and Lua patterns when making recommendations
- Prioritize by impact-to-effort ratio: quick wins first
</constraints>

<verification>
Before completing the roadmap:
- Confirm every Lua file in the project has been read and analyzed
- Verify all file:line references are accurate
- Ensure each phase of the roadmap contains at least 3 actionable items
- Check that no recommendation would break the plugin's external behavior
</verification>

<success_criteria>
- Every source file has been examined
- All 8 analysis dimensions are covered with specific findings
- Roadmap has 3 prioritized phases with concrete, actionable items
- File and line references are accurate
- Output saved to ./docs/maintainability-roadmap.md
</success_criteria>
