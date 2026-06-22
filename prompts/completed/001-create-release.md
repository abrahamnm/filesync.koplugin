<objective>
Create a new release for the filesync.koplugin KOReader plugin. Determine the appropriate next semver version based on the changes since the last release (v1.2.1), compose a polished release description, and trigger the GitHub Actions release workflow.
</objective>

<context>
- Repository: abrahamnm/filesync.koplugin
- Current version: 1.2.1 (in `_meta.lua`)
- The GitHub workflow at `.github/workflows/release.yml` is a `workflow_dispatch` that accepts `version` (semver string) and `release_description` (markdown string). The workflow automatically updates `_meta.lua`, commits, tags, builds the zip, and creates the GitHub release — you do NOT need to edit `_meta.lua` locally.
- Previous release descriptions follow this format (see v1.1.0 for reference):
  ```
  ## What's New
  - Feature/fix bullet points with PR references

  **Full Changelog**: https://github.com/abrahamnm/filesync.koplugin/compare/vOLD...vNEW

  ### Contributions
  - @username: Brief description of their contribution
  ```
</context>

<requirements>
1. **Determine the next version**: Run `git log --oneline v1.2.1..HEAD` to see all changes since the last release. Based on the nature of the changes (features = minor bump, fixes only = patch bump), determine the next version number.

2. **Identify contributors**: For each PR/commit since v1.2.1, identify the authors. Use `git log --format="%an" v1.2.1..HEAD | sort -u` and cross-reference PR numbers with `gh pr view <number> --json author --jq '.author.login'` to get GitHub usernames. Exclude bot accounts (github-actions[bot]).

3. **Compose the release description** in markdown with these sections:
   - **## What's New** — Bullet list of user-facing changes. Reference PR numbers as (#N). Write clear, user-friendly descriptions (not raw commit messages).
   - **Full Changelog** link — Format: `**Full Changelog**: https://github.com/abrahamnm/filesync.koplugin/compare/v1.2.1...vNEW`
   - **### Contributions** — List each contributor as `- @username: Brief description of what they contributed`. Include all non-bot contributors.

4. **Trigger the release workflow**: Use the GitHub CLI to dispatch the workflow:
   ```
   gh workflow run release.yml -f version="X.Y.Z" -f release_description="<the markdown description>"
   ```
   Use a heredoc or proper escaping to preserve the markdown formatting in the description.

5. **Verify the workflow started**: After dispatching, run `gh run list --workflow=release.yml --limit 1` to confirm the workflow was triggered successfully. Share the run URL with the user.
</requirements>

<constraints>
- Do NOT edit `_meta.lua` locally — the workflow handles that automatically.
- Do NOT create a git tag locally — the workflow handles that too.
- Make sure the `release_description` markdown renders correctly (test by echoing it first).
- Pull the latest changes from the remote before analyzing commits: `git pull origin master`.
- The version string must be pure semver (e.g., `1.3.0`), no `v` prefix — the workflow adds the `v` prefix itself.
</constraints>

<verification>
Before triggering the workflow:
1. Echo the full release description to the terminal so the user can review it.
2. Confirm the version number makes sense given the changes.
3. After dispatching, verify the workflow run appears in `gh run list`.
</verification>

<success_criteria>
- Correct next version determined based on change types
- Release description includes What's New, Full Changelog link, and Contributors
- GitHub Actions release workflow successfully triggered
- Workflow run confirmed as started
</success_criteria>
