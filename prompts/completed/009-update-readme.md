<objective>
Update the existing README.md to reflect the latest features and functionality added to the FileSync
KOReader plugin. Add a language selector at the top linking to translated README files.
</objective>

<context>
This is a KOReader e-reader plugin with a web-based wireless file manager. The README.md needs updating
to document features added since it was last written. The plugin now supports 10 languages and RTL layout.

Read these files to understand what's changed:
- `./README.md` — current README (source of truth for structure)
- `./filesync/i18n/*.po` — list all .po files to see supported languages
- `./filesync/src/js/i18n.js` — RTL language detection
- `./filesync/src/css/themes.css` — dark theme support
- Recent git log: run `git log --oneline -20` to see recent feature commits
</context>

<requirements>
1. Read the current `./README.md` first
2. Add a **language selector** at the very top of the file, right after the title line, formatted as:

   ```
   [English](README.md) | [Español](README.es.md) | [Português](README.pt_BR.md) | [中文](README.zh_CN.md) | [العربية](README.ar.md) | [Français](README.fr.md) | [Deutsch](README.de.md) | [Русский](README.ru.md) | [日本語](README.ja.md) | [한국어](README.ko.md)
   ```

3. Update the **Features** section to include these new capabilities:
   - **Dark & Light Themes** — Auto-detected or toggled manually
   - **Multiple View Modes** — List, grid, and large grid views
   - **Multi-Language Support** — Available in 10 languages (English, Spanish, Portuguese, Chinese, Arabic, French, German, Russian, Japanese, Korean)
   - **RTL Layout Support** — Full right-to-left layout for Arabic

4. Update the **directory tree** in the Installation section to reflect the current file structure:
   - The `i18n/` directory now contains: `en.po`, `es.po`, `pt_BR.po`, `zh_CN.po`, `ar.po`, `fr.po`, `de.po`, `ru.po`, `ja.po`, `ko.po`
   - Keep the tree concise — list a few .po files and use `└── ...` for the rest

5. Do NOT change the screenshots, installation steps, troubleshooting, or contributing sections
   beyond what's needed for accuracy

6. Keep the existing tone, structure, and formatting style
</requirements>

<output>
Save the updated file to: `./README.md`
</output>

<verification>
- Language selector links are at the top, right after the title
- All 10 languages are listed with correct filenames
- Features section includes dark/light themes, view modes, multi-language, and RTL support
- Directory tree reflects current i18n files
- No existing content was unnecessarily removed
</verification>
