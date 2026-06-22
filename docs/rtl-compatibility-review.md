# RTL Compatibility Review -- FileSync Web UI

## Executive Summary

The FileSync web UI was built entirely with LTR (left-to-right) assumptions. With Arabic recently added as a supported language, the UI needs targeted changes to support RTL layout.

**Issues found: 30 total**
- Critical: 5 (broken layout or unusable elements for RTL users)
- Medium: 15 (awkward appearance but still functional)
- Low: 10 (cosmetic issues that don't affect functionality)

**Overall RTL readiness:** Low. The `dir` attribute is never set, no CSS logical properties are used, and several components use hardcoded directional values that would render incorrectly for Arabic users.

**Effort estimate:** Medium. Most fixes are mechanical CSS property swaps (physical to logical) and a small amount of JS/HTML work to set `dir="rtl"` dynamically. No architectural changes are needed.

**Files reviewed:**
- `filesync/src/html/index.html` (HTML template)
- `filesync/src/css/base.css`
- `filesync/src/css/themes.css`
- `filesync/src/css/layout.css`
- `filesync/src/css/components.css`
- `filesync/src/css/file-list.css`
- `filesync/src/css/modals.css`
- `filesync/src/js/i18n.js`
- `filesync/src/js/state.js`
- `filesync/src/js/ui.js`
- `filesync/src/js/file-list.js`
- `filesync/src/js/file-ops.js`
- `filesync/src/js/api.js`
- `filesync/src/js/drag-drop.js`
- `filesync/src/js/app.js`
- `filesync/i18n/en.po`
- `filesync/i18n/ar.po`
- `filesync/httpserver.lua`
- `filesync/filesync_i18n.lua`
- `filesync/filesyncmanager.lua`
- `filesync/build.sh`
- `filesync/src/i18n/po2json.sh`

---

## How RTL Should Be Activated

The web UI fetches the active language from the server via `GET /api/lang`, which returns the KOReader `language` setting. The recommended approach:

1. **Define an RTL language list** in `i18n.js` (e.g., `var RTL_LANGS = ["ar", "he", "fa", "ur"];`).
2. **After language detection in `app.js`**, set `dir` and `lang` on `<html>`:
   ```js
   var isRTL = RTL_LANGS.indexOf(currentLang) !== -1 || RTL_LANGS.indexOf(currentLang.split("_")[0]) !== -1;
   document.documentElement.setAttribute("dir", isRTL ? "rtl" : "ltr");
   document.documentElement.setAttribute("lang", currentLang.replace("_", "-"));
   ```
3. **Use the `[dir="rtl"]` selector in CSS** for the few cases where logical properties alone are insufficient (icon mirroring, arrow direction).

This approach requires no server-side changes and automatically adapts when the language changes.

---

## Issues Found

### Critical

#### C1. Missing `dir` attribute on `<html>` -- no RTL layout activation

**File:** `filesync/src/html/index.html`, line 2
**Current code:**
```html
<html lang="en">
```
**Problem:** The `lang` attribute is hardcoded to `"en"` and there is no `dir` attribute. Without `dir="rtl"`, the browser renders everything in LTR mode regardless of the language. This is the root cause -- without this, nothing will be RTL.

**Severity:** Critical -- the entire UI will remain LTR for Arabic users.
**Regression risk:** None if implemented correctly (LTR is the default).

---

#### C2. Search input has hardcoded left padding for the icon

**File:** `filesync/src/css/layout.css`, line 261
```css
.search-box input {
    /* ... */
    padding: 0 14px 0 38px;
    /* ... */
}
```
**And** the search icon is positioned with `left`:

**File:** `filesync/src/css/layout.css`, lines 283-285
```css
.search-box svg {
    position: absolute;
    left: 10px;
    /* ... */
}
```

**Problem:** In RTL, the search icon should be on the right side, and the extra padding should be on the right. Currently, the icon overlaps the text input area on the left, and in RTL the text entry area would have wrong padding (cramped on the right, excess space on the left).

**Severity:** Critical -- the search bar would be visually broken with the icon overlapping text.
**Regression risk:** None if using logical properties.

---

#### C3. Sort select dropdown has hardcoded right-side arrow

**File:** `filesync/src/css/layout.css`, lines 293-309
```css
.sort-select {
    /* ... */
    padding: 0 30px 0 12px;
    /* ... */
    background-position: right 8px center;
    padding-right: 28px;
}
```
**Problem:** The dropdown arrow indicator is positioned on the right via `background-position: right 8px center` and has extra right padding. In RTL, the arrow should be on the left and the padding should be reversed. The `background-position` property does not respond to `dir` automatically.

**Severity:** Critical -- the arrow overlaps text or is invisible in RTL.
**Regression risk:** Low; requires an `[dir="rtl"]` override for `background-position`.

---

#### C4. Back button arrow (`&larr;`) points wrong direction in RTL

**File:** `filesync/src/html/index.html`, line 79
```html
<button class="btn btn-secondary btn-sm breadcrumb-back hidden" id="btnParentNav" type="button" onclick="navigateUp()" aria-label="Go up" title="Go up">&larr;</button>
```
**Problem:** The left arrow `&larr;` is a visual directional indicator meaning "go back/up." In RTL, the equivalent visual direction is a right arrow `&rarr;`. Using a Unicode arrow means it won't auto-mirror.

**Severity:** Critical -- the navigation arrow points in the wrong direction, confusing RTL users about which direction is "back."
**Regression risk:** None; can be handled via CSS `transform: scaleX(-1)` on `[dir="rtl"]` or by swapping the character dynamically.

---

#### C5. File detail back button SVG arrow points left (hardcoded LTR direction)

**File:** `filesync/src/html/index.html`, lines 202-207
```html
<button class="btn btn-secondary btn-sm" onclick="hideFileDetail()">
    <svg width="16" height="16" viewBox="0 0 24 24" ...>
        <line x1="19" y1="12" x2="5" y2="12"/>
        <polyline points="12 19 5 12 12 5"/>
    </svg>
    <span data-i18n="Back">Back</span>
</button>
```
**Problem:** The SVG draws a left-pointing arrow (line from right to left, chevron pointing left). In RTL, "back" means going to the right, so this arrow should point right.

**Severity:** Critical -- same directional confusion as C4 in the file detail view.
**Regression risk:** None; mirror via CSS `transform: scaleX(-1)` on the SVG in RTL.

---

### Medium

#### M1. `header-controls` uses `margin-left: auto`

**File:** `filesync/src/css/layout.css`, line 42
```css
.header-controls {
    /* ... */
    margin-left: auto;
    /* ... */
}
```
**Problem:** `margin-left: auto` pushes the controls to the right in LTR. In RTL, this should be `margin-right: auto` to push controls to the left. The flexbox `justify-content: space-between` on the parent partly compensates, but `margin-left: auto` on a flex child creates explicit directional behavior.

**Severity:** Medium -- the header controls may not be properly positioned.
**Regression risk:** None with logical property.

---

#### M2. `header-actions` uses `margin-left: auto` (mobile)

**File:** `filesync/src/css/layout.css`, line 119
```css
@media (max-width: 640px) {
    .header-actions {
        /* ... */
        margin-left: auto;
    }
}
```
**Problem:** Same as M1, but within the mobile breakpoint.

**Severity:** Medium.
**Regression risk:** None with logical property.

---

#### M3. `header-controls` and `header-actions` use `justify-content: flex-end`

**File:** `filesync/src/css/layout.css`, lines 104, 155-156
```css
.header-controls {
    justify-content: flex-end;
}
.header-actions {
    justify-content: flex-end;
}
```
**Problem:** `flex-end` is flow-relative in flexbox, so it respects `dir`. This is actually **fine** -- no change needed. Noted for completeness.

---

#### M4. `.file-actions` uses `margin-left: auto`

**File:** `filesync/src/css/file-list.css`, line 387
```css
.file-actions {
    /* ... */
    margin-left: auto;
}
```
**Problem:** In list view, this pushes file action buttons to the right edge. In RTL, they should be on the left, requiring `margin-right: auto`.

**Severity:** Medium -- action buttons would cluster near the file name instead of the far edge.
**Regression risk:** None with logical property.

---

#### M5. `.file-actions` desktop uses `justify-content: flex-end`

**File:** `filesync/src/css/file-list.css`, line 541
```css
.file-list:not(.view-grid):not(.view-grid-large) .file-actions {
    grid-column: 6;
    justify-content: flex-end;
    min-width: 68px;
}
```
**Problem:** `flex-end` is already direction-aware in flex. No change needed for `justify-content`. But `grid-column: 6` is a positional index; this is fine because grid column numbers are not directional -- CSS grid respects `dir` and reverses column ordering automatically.

---

#### M6. File chevron arrow points right (LTR-only)

**File:** `filesync/src/js/file-list.js`, line 136
```js
html += '<div class="file-actions file-actions-chevron"><span class="file-chevron"><svg viewBox="0 0 24 24" width="16" height="16" ...><polyline points="9 18 15 12 9 6"/></svg></span></div>';
```
**Problem:** The chevron `>` points right, indicating "click to see detail." In RTL, it should point left `<`.

**Severity:** Medium -- the directional hint is inverted, confusing RTL users.
**Regression risk:** None; mirror via CSS.

---

#### M7. Grid view `.file-actions-chevron` positioned with `right: 10px`

**File:** `filesync/src/css/file-list.css`, lines 139 and 237
```css
.file-list.view-grid .file-actions.file-actions-chevron {
    position: absolute;
    top: 50%;
    right: 10px;
    /* ... */
}
```
And identically at line 237 for `.view-grid-large`.

**Problem:** `right: 10px` positions the chevron on the right edge. In RTL, it should be on the left.

**Severity:** Medium -- the chevron is on the wrong side in grid views.
**Regression risk:** None with logical property.

---

#### M8. Grid view `.file-info` uses `padding-right: 18px`

**File:** `filesync/src/css/file-list.css`, line 107
```css
.file-list.view-grid .file-item.is-file .file-info {
    padding-right: 18px;
}
```
**Problem:** This padding gives room for the chevron on the right. In RTL, the chevron is on the left, so this should be `padding-left`.

**Severity:** Medium -- text could overlap the chevron in RTL.
**Regression risk:** None with logical property.

---

#### M9. Desktop table file info uses `padding-right: 8px`

**File:** `filesync/src/css/file-list.css`, line 492
```css
.file-list:not(.view-grid):not(.view-grid-large) .file-info {
    /* ... */
    padding-right: 8px;
}
```
**Problem:** In RTL, this should be `padding-left`.

**Severity:** Medium.
**Regression risk:** None with logical property.

---

#### M10. Modal title has `padding-right: 32px`

**File:** `filesync/src/css/modals.css`, line 107
```css
#confirmOverlay .modal .modal-title,
#modalOverlay .modal .modal-title {
    padding-right: 32px;
}
```
**Problem:** This padding prevents the title text from colliding with the close button positioned at `right: -12px`. In RTL, the close button should be on the left side, and the padding should be on the left.

**Severity:** Medium -- title text may overlap the close button in RTL.
**Regression risk:** None with logical property + matching close button position fix.

---

#### M11. Modal close button positioned at `right: -12px`

**File:** `filesync/src/css/modals.css`, lines 111-113
```css
.modal-close-btn {
    position: absolute;
    top: -12px;
    right: -12px;
    /* ... */
}
```
**Problem:** In RTL, the close button should be on the left side of the modal (at `left: -12px`).

**Severity:** Medium -- button is on the wrong corner of the modal.
**Regression risk:** None with logical properties.

---

#### M12. `.detail-ext-suffix` has `border-left: none` and directional border-radius

**File:** `filesync/src/css/modals.css`, lines 323-333
```css
.detail-ext-suffix {
    /* ... */
    border-left: none;
    border-radius: 0 var(--radius-sm) var(--radius-sm) 0;
    /* ... */
}
```
And the matching input:

**File:** `filesync/src/css/modals.css`, lines 341-345
```css
.modal-input-with-ext .modal-input {
    /* ... */
    border-radius: var(--radius-sm) 0 0 var(--radius-sm);
    /* ... */
}
```

**Problem:** In the rename modal, the input + extension suffix are visually joined. The input has rounded corners on the left, the suffix has rounded corners on the right, and `border-left: none` removes the shared border. In RTL, these sides must be swapped: the input should have rounded corners on the right, and the suffix on the left.

**Severity:** Medium -- the rename extension display would look broken with a visible double border on one side and a gap on the other.
**Regression risk:** None with logical properties.

---

#### M13. `.detail-info-value` uses `text-align: right`

**File:** `filesync/src/css/modals.css`, line 305
```css
.detail-info-value {
    /* ... */
    text-align: right;
    /* ... */
}
```
**Problem:** In RTL, the value column should be left-aligned (it's opposite the label). Using `text-align: end` would handle both directions.

**Severity:** Medium.
**Regression risk:** None with logical value.

---

#### M14. `nav-scope-select` uses `background-position` with `calc(100% - Npx)`

**File:** `filesync/src/css/layout.css`, lines 343-347
```css
.nav-scope-select {
    /* ... */
    padding: 0 28px 0 10px;
    background-position:
        calc(100% - 14px) 12px,
        calc(100% - 9px) 12px;
    /* ... */
}
```
**Problem:** The `calc(100% - Npx)` pattern for background-position does effectively compute from the right edge, which won't auto-flip in RTL. The dropdown arrow would appear on the wrong side.

**Severity:** Medium -- similar to C3 but for the scope select.
**Regression risk:** Low; requires `[dir="rtl"]` override.

---

#### M15. File-list-header-button has `padding: 2px 12px 2px 0`

**File:** `filesync/src/css/file-list.css`, line 449
```css
.file-list-header-button {
    /* ... */
    padding: 2px 12px 2px 0;
    /* ... */
}
```
**Problem:** Asymmetric left/right padding. In RTL, this should be `padding: 2px 0 2px 12px`.

**Severity:** Medium -- minor layout misalignment in the table header.
**Regression risk:** None with logical property.

---

### Low

#### L1. Breadcrumb separator `/` is directionality-neutral but may look odd

**File:** `filesync/src/js/file-list.js`, line 75
```js
html += '<span class="breadcrumb-sep">/</span>';
```
**Problem:** The `/` separator is visually neutral but the overall breadcrumb flow in RTL should go right-to-left. Since breadcrumbs are in a flex container, they will naturally reverse when `dir="rtl"` is set on the document. However, the `/` separator could be replaced with a proper separator like `\` or a chevron for better RTL appearance, though `/` is acceptable.

**Severity:** Low -- cosmetic; the breadcrumb direction will be handled by flexbox once `dir` is set.

---

#### L2. `.spinner` uses `border-top-color` for animation highlight

**File:** `filesync/src/css/components.css`, lines 477-479
```css
.spinner {
    border: 3px solid var(--border);
    border-top-color: var(--primary);
    /* ... */
}
```
And similarly in `modals.css`, lines 226 and 255.

**Problem:** `border-top-color` is not a directional property (top is always top regardless of LTR/RTL), so this is fine. The `rotate(360deg)` animation is also directionality-neutral. No change needed.

**Severity:** Low (no actual issue).

---

#### L3. `formatDate()` concatenates numbers with translated suffixes

**File:** `filesync/src/js/ui.js`, lines 18-22
```js
if (diff < 3600000) return Math.floor(diff / 60000) + t('m ago');
if (diff < 86400000) return Math.floor(diff / 3600000) + t('h ago');
if (diff < 604800000) return Math.floor(diff / 86400000) + t('d ago');
```
**Problem:** In Arabic, the number-before-unit ordering may need to be reversed or at minimum the Arabic translations ("d", "s", "y") are terse single-character abbreviations. The concatenation `number + suffix` may read oddly in RTL. The Arabic `.po` currently uses single-letter abbreviations (`"d"` => `"د"`, `"h ago"` => `"س"`, etc.) which effectively works but is semantically unusual.

**Severity:** Low -- functional but not natural Arabic phrasing. A future improvement could use a format string with `{n}` placeholder like the directory file count already does.

---

#### L4. Month names in `formatDate()` are hardcoded English

**File:** `filesync/src/js/ui.js`, line 21
```js
var months = ['Jan','Feb','Mar','Apr','May','Jun','Jul','Aug','Sep','Oct','Nov','Dec'];
```
**Problem:** Month abbreviations are always English regardless of locale. This affects all non-English languages, not just RTL.

**Severity:** Low -- cosmetic; not RTL-specific but would improve Arabic experience.

---

#### L5. Theme toggle aria-label uses hardcoded English pattern

**File:** `filesync/src/js/ui.js`, lines 106-115
```js
function getThemeModeLabel(theme) {
    return theme === "dark" ? "Dark mode" : "Light mode";
}
// ...
var title = getThemeModeLabel(currentThemePreference) + ". Switch to " + getThemeModeLabel(nextTheme).toLowerCase() + ".";
```
**Problem:** The aria-label and title are not translated. This is an i18n issue affecting all languages, not just RTL.

**Severity:** Low -- accessibility/i18n issue, not layout-breaking.

---

#### L6. View mode label uses hardcoded English

**File:** `filesync/src/js/ui.js`, lines 165-169
```js
function getViewModeLabel(mode) {
    if (mode === "grid-large") return "Large grid view";
    if (mode === "grid") return "Grid view";
    return "List view";
}
```
And the resulting title (line 196):
```js
var title = getViewModeLabel(viewMode) + ". Switch to " + getViewModeLabel(nextMode).toLowerCase() + ".";
```
**Problem:** Same as L5 -- untranslated labels. Not RTL-specific.

**Severity:** Low.

---

#### L7. `_showDetailInternal` sets `document.body.style.left = '0'` and `style.right = '0'`

**File:** `filesync/src/js/file-ops.js`, lines 100-103
```js
document.body.style.position = 'fixed';
document.body.style.top = '-' + window.scrollY + 'px';
document.body.style.left = '0';
document.body.style.right = '0';
```
And on hide (lines 228-232):
```js
document.body.style.position = '';
document.body.style.top = '';
document.body.style.left = '';
document.body.style.right = '';
```
**Problem:** Setting both `left: 0` and `right: 0` is direction-neutral (it stretches the body to fill the viewport in both directions). This is actually fine for both LTR and RTL.

**Severity:** Low (no actual issue).

---

#### L8. `file-item:hover` transform only uses `translateY`

**File:** `filesync/src/css/file-list.css`, lines 60-64
```css
.file-item:hover {
    transform: translateY(-1px);
}
.file-item:active {
    transform: translateY(0);
}
```
**Problem:** `translateY` is vertical, not directional. No RTL issue.

**Severity:** Low (no actual issue).

---

#### L9. Toast animations use `translateY` only

**File:** `filesync/src/css/components.css`, lines 433-441
```css
@keyframes toast-in {
    from { opacity: 0; transform: translateY(-12px) scale(0.95); }
    to { opacity: 1; transform: translateY(0) scale(1); }
}
```
**Problem:** Vertical-only transforms. No RTL issue.

**Severity:** Low (no actual issue).

---

#### L10. Toast container uses `left: 50%; transform: translateX(-50%)`

**File:** `filesync/src/css/components.css`, lines 397-399
```css
.toast-container {
    position: fixed;
    top: 16px;
    left: 50%;
    transform: translateX(-50%);
    /* ... */
}
```
**Problem:** This centers the toast container horizontally. While `left: 50%` plus `translateX(-50%)` is a centering pattern, it technically uses a physical property. However, the result is identical in both LTR and RTL (dead center). Could optionally use `inset-inline-start: 50%` for purity, but functionally no issue.

**Severity:** Low -- cosmetic/code-purity only.

---

## Recommended Changes

### CSS Changes

#### `filesync/src/css/layout.css`

**1. Header controls -- `margin-left: auto` to `margin-inline-start: auto`**
```css
/* Line 42 */
/* Before: */
margin-left: auto;
/* After: */
margin-inline-start: auto;
```

**2. Mobile header actions -- `margin-left: auto` to `margin-inline-start: auto`**
```css
/* Line 119 (inside @media max-width: 640px) */
/* Before: */
margin-left: auto;
/* After: */
margin-inline-start: auto;
```

**3. Search input padding -- use logical shorthand**
```css
/* Line 261 */
/* Before: */
padding: 0 14px 0 38px;
/* After: */
padding-block: 0;
padding-inline: 38px 14px;
```

**4. Search icon position -- `left` to `inset-inline-start`**
```css
/* Lines 283-285 */
/* Before: */
.search-box svg {
    position: absolute;
    left: 10px;
    top: 50%;
    transform: translateY(-50%);
    /* ... */
}
/* After: */
.search-box svg {
    position: absolute;
    inset-inline-start: 10px;
    top: 50%;
    transform: translateY(-50%);
    /* ... */
}
```

**5. Sort select padding and dropdown arrow -- use logical padding + RTL override for background-position**
```css
/* Lines 293-309 */
/* Before: */
.sort-select {
    padding: 0 30px 0 12px;
    /* ... */
    background-position: right 8px center;
    padding-right: 28px;
}
/* After: */
.sort-select {
    padding-block: 0;
    padding-inline: 12px 30px;
    /* ... */
    background-position: right 8px center;
    padding-inline-end: 28px;
}
[dir="rtl"] .sort-select {
    background-position: left 8px center;
}
```

**6. Nav scope select padding and arrow -- same pattern**
```css
/* Lines 328-349 */
/* Before: */
.nav-scope-select {
    padding: 0 28px 0 10px;
    background-position:
        calc(100% - 14px) 12px,
        calc(100% - 9px) 12px;
}
/* After: */
.nav-scope-select {
    padding-block: 0;
    padding-inline: 10px 28px;
    background-position:
        calc(100% - 14px) 12px,
        calc(100% - 9px) 12px;
}
[dir="rtl"] .nav-scope-select {
    background-position:
        14px 12px,
        9px 12px;
}
```

#### `filesync/src/css/file-list.css`

**7. Grid view file info padding**
```css
/* Line 107 */
/* Before: */
.file-list.view-grid .file-item.is-file .file-info {
    padding-right: 18px;
}
/* After: */
.file-list.view-grid .file-item.is-file .file-info {
    padding-inline-end: 18px;
}
```

**8. Grid view chevron position (two places)**
```css
/* Line 139 */
/* Before: */
.file-list.view-grid .file-actions.file-actions-chevron {
    position: absolute;
    top: 50%;
    right: 10px;
    /* ... */
}
/* After: */
.file-list.view-grid .file-actions.file-actions-chevron {
    position: absolute;
    top: 50%;
    inset-inline-end: 10px;
    /* ... */
}

/* Line 237 -- identical change */
/* Before: */
.file-list.view-grid-large .file-actions.file-actions-chevron {
    position: absolute;
    top: 50%;
    right: 10px;
    /* ... */
}
/* After: */
.file-list.view-grid-large .file-actions.file-actions-chevron {
    position: absolute;
    top: 50%;
    inset-inline-end: 10px;
    /* ... */
}
```

**9. File actions `margin-left: auto`**
```css
/* Line 387 */
/* Before: */
.file-actions {
    /* ... */
    margin-left: auto;
}
/* After: */
.file-actions {
    /* ... */
    margin-inline-start: auto;
}
```

**10. File-list-header-button padding**
```css
/* Line 449 */
/* Before: */
.file-list-header-button {
    padding: 2px 12px 2px 0;
}
/* After: */
.file-list-header-button {
    padding-block: 2px;
    padding-inline: 0 12px;
}
```

**11. Desktop file info padding**
```css
/* Line 492 */
/* Before: */
.file-list:not(.view-grid):not(.view-grid-large) .file-info {
    padding-right: 8px;
}
/* After: */
.file-list:not(.view-grid):not(.view-grid-large) .file-info {
    padding-inline-end: 8px;
}
```

**12. File chevron mirroring in RTL (new rule)**
Add at the end of `file-list.css`:
```css
[dir="rtl"] .file-chevron svg {
    transform: scaleX(-1);
}
```

#### `filesync/src/css/modals.css`

**13. Modal title padding**
```css
/* Line 107 */
/* Before: */
#confirmOverlay .modal .modal-title,
#modalOverlay .modal .modal-title {
    padding-right: 32px;
}
/* After: */
#confirmOverlay .modal .modal-title,
#modalOverlay .modal .modal-title {
    padding-inline-end: 32px;
}
```

**14. Modal close button position**
```css
/* Lines 111-113 */
/* Before: */
.modal-close-btn {
    position: absolute;
    top: -12px;
    right: -12px;
    /* ... */
}
/* After: */
.modal-close-btn {
    position: absolute;
    top: -12px;
    inset-inline-end: -12px;
    /* ... */
}
```

**15. Detail info value text alignment**
```css
/* Line 305 */
/* Before: */
.detail-info-value {
    text-align: right;
}
/* After: */
.detail-info-value {
    text-align: end;
}
```

**16. Extension suffix borders and radius**
```css
/* Lines 323-333 */
/* Before: */
.detail-ext-suffix {
    /* ... */
    border-left: none;
    border-radius: 0 var(--radius-sm) var(--radius-sm) 0;
    /* ... */
}
/* After: */
.detail-ext-suffix {
    /* ... */
    border-inline-start: none;
    border-start-start-radius: 0;
    border-start-end-radius: var(--radius-sm);
    border-end-end-radius: var(--radius-sm);
    border-end-start-radius: 0;
    /* ... */
}

/* Lines 341-345 */
/* Before: */
.modal-input-with-ext .modal-input {
    border-radius: var(--radius-sm) 0 0 var(--radius-sm);
}
/* After: */
.modal-input-with-ext .modal-input {
    border-start-start-radius: var(--radius-sm);
    border-start-end-radius: 0;
    border-end-end-radius: 0;
    border-end-start-radius: var(--radius-sm);
}
```

#### `filesync/src/css/layout.css` -- Breadcrumb back button mirroring

**17. Add RTL rule for breadcrumb back arrow:**
```css
/* Add after the .breadcrumb-back rules (~line 182) */
[dir="rtl"] .breadcrumb-back {
    transform: scaleX(-1);
}
```

#### `filesync/src/css/modals.css` or `file-list.css` -- Detail back button arrow mirroring

**18. Add RTL rule for detail view back button SVG:**
```css
/* Add a new rule */
[dir="rtl"] .detail-header .btn svg {
    transform: scaleX(-1);
}
```

### HTML Changes

#### `filesync/src/html/index.html`

**19. Remove hardcoded `lang="en"` -- the JS will set both `lang` and `dir` dynamically.**
```html
<!-- Line 2 -->
<!-- Before: -->
<html lang="en">
<!-- After: -->
<html>
```

Alternatively, keep `lang="en"` as a safe default that will be overridden by JS. Either approach works; removing it makes it clearer that JS is the source of truth.

**20. Add `dir` and `lang` setup to the early inline script (optional -- for flash prevention):**
```html
<!-- Line 11-19: add dir/lang detection alongside theme detection -->
<script>
(function() {
    try {
        var storedTheme = localStorage.getItem("filesync_theme");
        var initialTheme = storedTheme === "light" || storedTheme === "dark"
            ? storedTheme
            : "light";
        document.documentElement.setAttribute("data-theme", initialTheme);
    } catch (e) {}
})();
</script>
```
No changes needed here -- the `dir` attribute will be set after the `/api/lang` fetch returns, which happens quickly. A brief LTR flash is acceptable for the first load.

### JavaScript Changes

#### `filesync/src/js/i18n.js`

**21. Add RTL language detection:**
```js
/* Add after line 6 (after var currentLang = "en";) */
var RTL_LANGS = ["ar", "he", "fa", "ur"];

function isRTLLanguage(lang) {
    if (RTL_LANGS.indexOf(lang) !== -1) return true;
    var base = lang.split("_")[0];
    return RTL_LANGS.indexOf(base) !== -1;
}
```

#### `filesync/src/js/app.js`

**22. Set `dir` and `lang` after language detection resolves:**

In the `.then()` chain where `currentLang` is set (around lines 76-87), add direction-setting:
```js
/* After the language detection block, before applyStaticTranslations() */
/* Current code ends with: */
// .then(function() {
//     initTheme();
//     applyStaticTranslations();
//     return loadFiles();
// })

/* Change to: */
.then(function() {
    // Set document direction and language
    document.documentElement.setAttribute("lang", currentLang.replace("_", "-"));
    document.documentElement.setAttribute("dir", isRTLLanguage(currentLang) ? "rtl" : "ltr");
    initTheme();
    applyStaticTranslations();
    return loadFiles();
})
```

#### `filesync/src/js/ui.js`

**23. Translate the theme toggle label (improvement, not strictly RTL):**
```js
/* Lines 106-115 */
/* Before: */
function getThemeModeLabel(theme) {
    return theme === "dark" ? "Dark mode" : "Light mode";
}
// ...
var title = getThemeModeLabel(currentThemePreference) + ". Switch to " + getThemeModeLabel(nextTheme).toLowerCase() + ".";

/* After: */
function getThemeModeLabel(theme) {
    return theme === "dark" ? t("Dark mode") : t("Light mode");
}
// ...
var title = t("theme_toggle_title")
    .replace("{current}", getThemeModeLabel(currentThemePreference))
    .replace("{next}", getThemeModeLabel(nextTheme));
```
(This requires adding "Dark mode", "Light mode", and a template string to the .po files. This is an i18n improvement beyond strict RTL scope, so it can be deferred.)

**24. Translate the view mode label (same category as #23, can be deferred).**

### i18n System Changes

**25. No changes needed to the i18n loading system (`filesync/filesync_i18n.lua`, `po2json.sh`, build pipeline).** The language code is already passed from KOReader settings through `/api/lang` to the JavaScript, and translations are already embedded in the built HTML. The only addition is the client-side RTL detection (items #21 and #22 above).

**26. No changes needed to `ar.po`.** The Arabic translations are complete and correct. The `dir="rtl"` is a presentation concern handled by HTML/CSS, not translation data.

---

## LTR Regression Prevention

### Why these changes are safe for LTR

1. **CSS logical properties** (`margin-inline-start`, `padding-inline-end`, `inset-inline-start`, `border-inline-start`, `text-align: end`, etc.) resolve to their physical equivalents based on the `dir` attribute:
   - In `dir="ltr"`: `inline-start` = `left`, `inline-end` = `right`
   - In `dir="rtl"`: `inline-start` = `right`, `inline-end` = `left`
   - When no `dir` is set (or `dir="ltr"`), behavior is identical to the current hardcoded physical properties.

2. **`[dir="rtl"]` selectors** only apply when the document direction is explicitly RTL. They have zero effect on LTR pages.

3. **Flexbox and Grid** already respect `dir` for `justify-content`, `align-items`, and column ordering. The changes here do not alter flex/grid behavior -- they simply replace physical margin/padding properties that sit alongside flexbox.

### Testing strategy

- **LTR smoke test:** After applying all changes, open the UI in English (or any LTR language) and verify:
  - Header layout (brand left, controls right)
  - Search bar icon on the left, text input alignment
  - Sort dropdown arrow on the right
  - Breadcrumb navigation left-to-right with back arrow pointing left
  - File list with action buttons on the right, chevrons pointing right
  - File detail view with back arrow pointing left
  - Modal dialogs with close button on the upper-right corner
  - Rename modal with extension suffix on the right

- **RTL smoke test:** Set KOReader language to Arabic and verify the mirror of everything above:
  - Header layout (brand right, controls left)
  - Search bar icon on the right, text input right-aligned
  - Sort dropdown arrow on the left
  - Breadcrumb navigation right-to-left with back arrow pointing right
  - File list with action buttons on the left, chevrons pointing left
  - File detail view with back arrow pointing right
  - Modal dialogs with close button on the upper-left corner
  - Rename modal with extension suffix on the left

- **Browser DevTools shortcut:** In Chrome/Firefox DevTools, you can toggle `dir="rtl"` on the `<html>` element to instantly preview RTL layout without changing the server language.

---

## Implementation Priority

### Phase 1: Foundation (must-do, enables all other fixes)
1. **[C1]** Add `dir` and `lang` attribute setting in JavaScript (`i18n.js` + `app.js`)
2. **[C2]** Fix search box: logical padding + logical icon position (`layout.css`)
3. **[C3]** Fix sort select: logical padding + RTL background-position override (`layout.css`)

### Phase 2: Navigation arrows (high visual impact)
4. **[C4]** Fix breadcrumb back arrow: add `[dir="rtl"]` scaleX mirror (`layout.css`)
5. **[C5]** Fix detail back button arrow: add `[dir="rtl"]` scaleX mirror (`modals.css` or inline)
6. **[M6]** Fix file chevron arrow: add `[dir="rtl"]` scaleX mirror (`file-list.css`)

### Phase 3: Layout alignment (medium priority)
7. **[M1, M2]** Fix `margin-left: auto` to `margin-inline-start: auto` in header (`layout.css`)
8. **[M4]** Fix `margin-left: auto` in file actions (`file-list.css`)
9. **[M7, M8]** Fix grid view chevron position and file-info padding (`file-list.css`)
10. **[M9]** Fix desktop table file-info padding (`file-list.css`)
11. **[M15]** Fix header button padding (`file-list.css`)

### Phase 4: Modal fixes (medium priority)
12. **[M10]** Fix modal title padding (`modals.css`)
13. **[M11]** Fix modal close button position (`modals.css`)
14. **[M12]** Fix extension suffix borders and radius (`modals.css`)
15. **[M13]** Fix detail info value text alignment (`modals.css`)
16. **[M14]** Fix nav scope select arrow position (`layout.css`)

### Phase 5: Polish (low priority, can be deferred)
17. **[L3]** Consider template-based date format strings for better Arabic
18. **[L4]** Consider localizable month names
19. **[L5, L6]** Translate theme/view mode labels
20. **[L10]** Optionally convert toast centering to use `inset-inline-start`
