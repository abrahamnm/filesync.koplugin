<objective>
Thoroughly analyze the FileSync KOReader plugin's web UI for RTL (right-to-left) language compatibility.
The plugin now supports Arabic, which is an RTL language. Review all HTML, CSS, and JavaScript to identify
every change needed to properly support RTL layouts while preserving full functionality and UX/UI for
existing LTR languages. Produce a detailed report documenting findings and recommended changes.
</objective>

<context>
This is a KOReader e-reader plugin with a web-based file manager UI served over HTTP.
The web UI was built for LTR languages (English, Spanish, Portuguese, Chinese, French, German, Russian,
Japanese, Korean). Arabic (ar) was recently added, which requires RTL text direction and mirrored layouts.

The goal is to ensure the UI works correctly for RTL users without breaking anything for LTR users.
This means using CSS logical properties, `dir` attributes, and conditional styling — not hard-coded
directional values.
</context>

<research>
Read ALL of the following files to understand the full UI implementation:

1. All HTML template files — search for `*.html` files in the project
2. All CSS files — search for `*.css` files in the project
3. All JavaScript files — search for `*.js` files in the project
4. The i18n/localization system — read `./filesync/i18n/en.po` and `./filesync/i18n/ar.po` to understand what strings exist
5. The server-side code that serves the web UI — look for Lua files that handle HTTP responses and template rendering
6. Any configuration that determines the active language

Use Glob to find all relevant files, then read each one thoroughly.
</research>

<analysis_requirements>
For each file, thoroughly analyze and document:

1. **CSS Issues** — Identify every instance of:
   - Hardcoded `left`/`right` properties that should use `inline-start`/`inline-end` logical equivalents
   - Hardcoded `margin-left`/`margin-right`, `padding-left`/`padding-right` that should be logical
   - `text-align: left`/`right` that should be `start`/`end`
   - `float: left`/`right` usage
   - `direction`-sensitive flexbox or grid layouts
   - Absolute/fixed positioning with `left`/`right` offsets
   - Border-radius with directional values (e.g., `border-top-left-radius`)
   - Transforms like `translateX` or `rotate` that assume LTR direction
   - Any icon or arrow that would need mirroring in RTL

2. **HTML Issues** — Identify:
   - Missing `dir` attribute on `<html>` or `<body>` tags
   - Missing `lang` attribute that should reflect the active language
   - Inline styles with directional properties
   - Input fields, search bars, or text areas that need RTL support
   - Navigation elements (breadcrumbs, back buttons) that assume LTR flow

3. **JavaScript Issues** — Identify:
   - Hardcoded directional logic (e.g., computing positions with `left`/`right`)
   - String concatenation that assumes LTR order
   - DOM manipulation that sets directional inline styles
   - Animations or transitions with directional assumptions
   - Any drag-and-drop or swipe logic that assumes LTR

4. **i18n System** — Check:
   - Whether the system can detect the language's text direction
   - How the language is selected and applied to the UI
   - Whether the `dir="rtl"` attribute gets set when Arabic is active

5. **Functional Impact** — For each issue found, assess:
   - Severity: Critical (broken layout/unusable), Medium (awkward but usable), Low (cosmetic)
   - What it looks like in RTL vs what it should look like
   - Whether fixing it could affect LTR layouts (regression risk)
</analysis_requirements>

<output_format>
Save the complete analysis report to: `./docs/rtl-compatibility-review.md`

Structure the report as follows:

```markdown
# RTL Compatibility Review — FileSync Web UI

## Executive Summary
[Brief overview: how many issues found, overall RTL readiness, effort estimate]

## How RTL Should Be Activated
[Describe the recommended approach for setting dir="rtl" based on the active language]

## Issues Found

### Critical
[Issues that would make the UI broken or unusable for RTL users]

### Medium
[Issues that would make the experience awkward but still functional]

### Low
[Cosmetic issues that don't affect functionality]

## Recommended Changes

### CSS Changes
[File-by-file list of specific CSS properties to change, with before/after examples]

### HTML Changes
[Specific template modifications needed]

### JavaScript Changes
[Specific JS modifications needed]

### i18n System Changes
[Changes to language detection/direction setting]

## LTR Regression Prevention
[How to ensure all changes are safe for LTR languages — testing strategy, CSS logical properties explanation]

## Implementation Priority
[Ordered list of changes to make, grouped by priority]
```
</output_format>

<constraints>
- Do NOT modify any code — this is a review/documentation task only
- Be specific: reference exact file paths, line numbers, and code snippets for every issue
- For each recommended change, show the exact current code and what it should become
- Ensure recommendations use CSS logical properties (margin-inline-start, padding-inline-end, etc.)
  which automatically adapt to both LTR and RTL without separate stylesheets
- The report must be actionable — a developer should be able to implement all changes directly from it
</constraints>

<verification>
Before saving the report, verify:
- Every HTML/CSS/JS file in the web UI has been reviewed
- Every directional CSS property has been flagged
- Every issue includes the file path, line number, current code, and recommended fix
- The report covers all 5 analysis categories (CSS, HTML, JS, i18n, functional impact)
- LTR regression prevention is addressed
</verification>
