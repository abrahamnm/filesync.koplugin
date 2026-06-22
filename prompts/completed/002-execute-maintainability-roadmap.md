<objective>
Act as a senior software engineer with deep expertise in Lua programming and maintaining open-source KOReader plugins. Your task is to execute the maintainability improvements from the approved roadmap, making conservative, non-breaking changes to improve code quality.
</objective>

<context>
Read the project's CLAUDE.md first if it exists.

Then read the maintainability roadmap at `./docs/maintainability-roadmap.md` — this was produced by a prior audit and approved by the maintainer. It contains a prioritized list of improvements organized into phases.

This is a KOReader plugin (filesync.koplugin) written in Lua. The plugin must continue to work exactly as before after your changes.
</context>

<requirements>
1. Read the full roadmap document carefully
2. Execute improvements **phase by phase**, starting with Phase 1 (Quick Wins)
3. For each item in the roadmap:
   - Read the affected file(s) to understand current state
   - Make the recommended change
   - Verify the change doesn't alter external behavior
4. After completing each phase, provide a brief summary of what was changed
5. Continue through all phases unless a change seems risky — flag those for review instead of implementing

If any roadmap item is no longer applicable (code has changed since the audit), skip it and note why.
</requirements>

<implementation>
Follow these principles for all changes:

**Conservative changes only:**
- Rename internal variables/functions for clarity — but never rename anything exported or part of the public API
- Add `local` declarations where globals are accidentally leaked
- Wrap risky calls with `pcall`/`xpcall` where the roadmap identifies unprotected calls
- Extract duplicated code into local helper functions within the same file
- Add inline comments explaining non-obvious logic
- Add module-level documentation headers
- Fix inconsistent naming within files (but keep exported names stable)

**Do NOT:**
- Change the plugin's external interface or behavior
- Restructure the file/directory layout
- Add new dependencies
- Remove any functionality
- Change function signatures of exported functions

**Lua-specific best practices:**
- Use `local` for all new variables and functions
- Prefer `string.format` over concatenation for complex strings
- Use early returns to reduce nesting
- Follow existing code style in each file (indent style, spacing)
</implementation>

<execution_strategy>
For maximum efficiency, whenever you need to perform multiple independent operations (like reading several files that don't depend on each other), invoke all relevant tools simultaneously rather than sequentially.

After making changes to each file, carefully reflect on whether the change preserves the original behavior before moving to the next item.
</execution_strategy>

<output>
After completing all phases, create a summary at `./docs/maintainability-changes.md` with:

```markdown
# Maintainability Changes Applied

## Summary
[Brief overview of what was done]

## Changes by Phase

### Phase 1: Quick Wins
- [x] Item — [what was changed and why]
- [x] Item — ...
- [ ] Item (skipped) — [reason]

### Phase 2: Structural Improvements
- [x] Item — [what was changed and why]
...

### Phase 3: Deeper Refactors
...

## Items Flagged for Review
[Any items that seemed too risky to implement without discussion]

## Verification Notes
[Any observations about the codebase that differ from the roadmap]
```
</output>

<verification>
Before declaring complete:
- Review each modified file to ensure no syntax errors were introduced
- Verify no exported function signatures were changed
- Confirm the module structure is intact (all requires still resolve)
- Check that no accidental globals were introduced (all new variables use `local`)
</verification>

<success_criteria>
- All applicable roadmap items have been implemented or explicitly flagged
- No breaking changes to the plugin's external interface
- All modified files are syntactically valid Lua
- Changes summary saved to ./docs/maintainability-changes.md
- Code follows existing style conventions in each file
</success_criteria>
