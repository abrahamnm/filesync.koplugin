<objective>
Translate all strings in the FileSync KOReader plugin from English to Japanese (ja).
Every single msgid must have a corresponding msgstr translation — no line may be left empty.
</objective>

<context>
This is a KOReader e-reader plugin that provides wireless file management via a web UI.
The project uses GNU gettext .po files for internationalization.

Source file (English): `./filesync/i18n/en.po`
Reference translation (Spanish): `./filesync/i18n/es.po`

Read both files to understand the exact format and how translations are structured.
</context>

<requirements>
1. Read `./filesync/i18n/en.po` to get all source strings
2. Read `./filesync/i18n/es.po` to see how an existing translation is structured
3. Create `./filesync/i18n/ja.po` with ALL msgid entries translated to Japanese
4. Every msgstr MUST be filled in — no empty msgstr values (except the header block)
5. Preserve all .po format details exactly:
   - Keep `msgid` values identical to the English source
   - Keep `\n` escape sequences in multi-line strings
   - Keep `%1` placeholders unchanged
   - Keep `{n}` template variables unchanged
   - Keep `.sdr` file extensions unchanged
   - Keep "FileSync" and "KOReader" as-is (brand names)
   - Keep technical terms like "WiFi", "HTTP", "QR", "IP", "URL" as-is
6. Use natural, polite Japanese phrasing suitable for a software UI (prefer です/ます form where appropriate, but keep UI labels concise)
7. For the header block, set `"Language: ja\n"` and update the comment to say "Japanese translations"
8. The section comment `# Web UI translations` should be preserved as-is
9. For short UI labels (like "m ago", "h ago", "d ago"), use appropriately concise Japanese expressions (e.g., 分前, 時間前, 日前)
</requirements>

<output>
Save the completed translation to: `./filesync/i18n/ja.po`
</output>

<verification>
Before saving, verify:
- Every msgid from en.po has a corresponding entry in ja.po
- No msgstr is empty (except the header metadata block)
- All placeholders (%1, {n}) are preserved
- The file is valid .po format
- Brand names (FileSync, KOReader) are untranslated
</verification>
