<objective>
Implement full RTL (right-to-left) language support for the FileSync web UI based on the detailed
review document at `./docs/rtl-compatibility-review.md`. This covers Phases 1-4 (all critical and
medium priority changes). Phase 5 (low priority polish) is deferred.
</objective>

<context>
This is a KOReader e-reader plugin with a web UI served over HTTP. Arabic was recently added as a
supported language, requiring RTL layout support. A thorough review has already been completed and
documented in `./docs/rtl-compatibility-review.md` with exact file paths, line numbers, and
before/after code for every change needed.

The approach uses CSS logical properties and `[dir="rtl"]` selectors so that all existing LTR
languages continue to work identically. No separate RTL stylesheet is needed.
</context>

<requirements>
Read `./docs/rtl-compatibility-review.md` first — it contains the complete implementation plan with
exact code changes. Then implement ALL changes from Phases 1 through 4 as described below.

**Phase 1: Foundation**

1. In `./filesync/src/js/i18n.js`: Add RTL language detection after the `currentLang` declaration:
   - Add `var RTL_LANGS = ["ar", "he", "fa", "ur"];`
   - Add `function isRTLLanguage(lang)` that checks both the full code and the base language code

2. In `./filesync/src/js/app.js`: In the `.then()` chain before `initTheme()` and `applyStaticTranslations()`, add:
   - `document.documentElement.setAttribute("lang", currentLang.replace("_", "-"));`
   - `document.documentElement.setAttribute("dir", isRTLLanguage(currentLang) ? "rtl" : "ltr");`

3. In `./filesync/src/html/index.html`: Remove the hardcoded `lang="en"` from the `<html>` tag (JS will set it dynamically)

4. In `./filesync/src/css/layout.css`:
   - Search box input: change `padding: 0 14px 0 38px` to logical `padding-block: 0; padding-inline: 38px 14px;`
   - Search icon: change `left: 10px` to `inset-inline-start: 10px`
   - Sort select: change `padding: 0 30px 0 12px` to logical, `padding-right: 28px` to `padding-inline-end: 28px`, and add `[dir="rtl"] .sort-select { background-position: left 8px center; }`

**Phase 2: Navigation arrows**

5. In `./filesync/src/css/layout.css`: Add rule `[dir="rtl"] .breadcrumb-back { transform: scaleX(-1); }`

6. In `./filesync/src/css/modals.css` or appropriate CSS file: Add rule for the detail back button SVG: `[dir="rtl"] .detail-header .btn svg { transform: scaleX(-1); }`

7. In `./filesync/src/css/file-list.css`: Add rule `[dir="rtl"] .file-chevron svg { transform: scaleX(-1); }`

**Phase 3: Layout alignment**

8. In `./filesync/src/css/layout.css`:
   - `.header-controls`: change `margin-left: auto` to `margin-inline-start: auto`
   - Mobile `.header-actions`: change `margin-left: auto` to `margin-inline-start: auto`

9. In `./filesync/src/css/file-list.css`:
   - `.file-actions`: change `margin-left: auto` to `margin-inline-start: auto`
   - Grid view `.file-info` padding: change `padding-right: 18px` to `padding-inline-end: 18px`
   - Grid view chevron position (two places): change `right: 10px` to `inset-inline-end: 10px`
   - Desktop file-info padding: change `padding-right: 8px` to `padding-inline-end: 8px`
   - File-list-header-button: change `padding: 2px 12px 2px 0` to `padding-block: 2px; padding-inline: 0 12px;`

**Phase 4: Modal fixes**

10. In `./filesync/src/css/modals.css`:
    - Modal title: change `padding-right: 32px` to `padding-inline-end: 32px`
    - Modal close button: change `right: -12px` to `inset-inline-end: -12px`
    - Detail info value: change `text-align: right` to `text-align: end`
    - Extension suffix `border-left: none` to `border-inline-start: none`
    - Extension suffix `border-radius` to logical border-radius properties
    - Input with ext `border-radius` to logical border-radius properties

11. In `./filesync/src/css/layout.css`:
    - Nav scope select: change padding to logical, add `[dir="rtl"]` override for `background-position`
</requirements>

<implementation>
- Read each file BEFORE editing it
- Use the review document as the authoritative reference for exact before/after code
- Use CSS logical properties (`margin-inline-start`, `padding-inline-end`, `inset-inline-start`,
  `border-inline-start`, `text-align: end`, logical border-radius) which automatically adapt to
  both LTR and RTL based on the `dir` attribute
- Use `[dir="rtl"]` selectors ONLY for properties that don't have logical equivalents
  (like `background-position` and `transform: scaleX(-1)` for arrow mirroring)
- Do NOT touch Phase 5 items (date format, month names, theme/view labels, toast centering)
- Do NOT modify any .po translation files
- Do NOT add new i18n strings
- After implementing all changes, rebuild the project by running `cd filesync && bash build.sh && cd ..`
  to ensure the changes compile into the final output
</implementation>

<verification>
After all changes are made:
1. Verify the build succeeds without errors by running `cd filesync && bash build.sh && cd ..`
2. Grep for any remaining `margin-left: auto` in CSS files that should have been converted
3. Grep for `padding-right:` and `padding-left:` in the modified CSS files to confirm conversions
4. Confirm `isRTLLanguage` function exists in `i18n.js`
5. Confirm `dir` attribute setting exists in `app.js`
6. Confirm `lang="en"` has been removed from `index.html`
</verification>

<success_criteria>
- All 26 changes from Phases 1-4 of the review document are implemented
- CSS logical properties are used everywhere instead of physical directional properties
- `[dir="rtl"]` overrides are added for background-position and arrow mirroring
- The build completes successfully
- No LTR regression: all logical properties resolve identically to the previous physical values when dir="ltr"
</success_criteria>
