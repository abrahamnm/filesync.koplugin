<objective>
Create translated README files for Arabic (ar), French (fr), and German (de).
Each file must be a complete, natural translation of the updated README.md.
</objective>

<context>
The FileSync KOReader plugin README.md has been updated with the latest features. Now we need translated
versions for each supported language. Each translated README should feel native to its language — not a
word-for-word machine translation.

The language selector at the top of each file should link to all 10 versions, with the CURRENT language
shown as bold text (not a link) instead of a clickable link.
</context>

<requirements>
1. Read `./README.md` as the source content to translate
2. Create three files:
   - `./README.ar.md` — Arabic translation
   - `./README.fr.md` — French translation
   - `./README.de.md` — German translation

3. For each file:
   - Translate ALL text content to the target language
   - Keep all markdown formatting, image paths, links, and code blocks identical
   - Keep brand names unchanged: FileSync, KOReader, Kindle, Kobo, WiFi, QR
   - Keep technical terms as-is: EPUB, PDF, MOBI, AZW3, USB, URL, etc.
   - Keep file paths and code examples in English (they are literal paths)
   - Keep the screenshots section exactly as-is (image paths don't change)
   - In the language selector, make the CURRENT language bold text instead of a link:
     - For README.ar.md: `**العربية**` instead of `[العربية](README.ar.md)`
     - For README.fr.md: `**Français**` instead of `[Français](README.fr.md)`
     - For README.de.md: `**Deutsch**` instead of `[Deutsch](README.de.md)`
   - The AGPLv3 license link should remain pointing to the English GNU page
   - For German: use formal "Sie" form

4. Use natural, fluent phrasing appropriate for each language — not literal word-for-word translation
</requirements>

<output>
- `./README.ar.md`
- `./README.fr.md`
- `./README.de.md`
</output>

<verification>
- All three files exist and are complete translations
- Language selector appears at top of each file with current language bolded
- All image paths, code blocks, and links are preserved unchanged
- Brand names and technical terms are untranslated
</verification>
