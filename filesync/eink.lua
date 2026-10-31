--- E-ink mode: a plain page for e-reader browsers, served from `GET /`.
---
--- E-reader browsers are too old for the main web UI. Kobo's (firmware 4.x)
--- is Qt 5.2.1 WebKit: ES5 only, no fetch or Promise, no CSS custom
--- properties, so the main UI's script does not even parse there. They get
--- this server-rendered page instead: no JavaScript, no animations, black on
--- white, one full page load per action, which suits e-ink screens.
---
--- It has two views, switched by a Books | Folders bar. Books (the default) is a
--- flat list of the device's ebooks (FileOps:listBooks), with title and author
--- for the books on the page shown. Folders lists folders and files (the same
--- FileOps:listDirectory call and safe mode rules as /api/files) with
--- breadcrumbs. Both have filter, sort and pages, and download through the
--- existing /api/download. There is no upload: on a Kobo, <input type="file">
--- opens a desktop Qt dialog that freezes the device.
---
--- Which page GET / serves (first match wins):
---   ?eink=1                      e-ink, remembered in the filesync_eink cookie
---   ?eink=0                      the main UI, for this URL only (the cookie is
---                                cleared, so a Kobo is never stuck on a page
---                                its browser cannot run)
---   cookie filesync_eink=1       e-ink
---   User-Agent "Kobo Touch"      e-ink (every Kobo; only in the HTTP header,
---                                Nickel's JavaScript reports "Kobo eReader")
---   User-Agent "Kindle/<digit>"  e-ink (Kindle e-readers, not Kindle Fire)
---   anything else                the main UI, unchanged
---
--- View: ?view=books|folders, remembered in the filesync_eink_view cookie.
---
--- Entries per page: ?per_page=N (one of PER_PAGE_CHOICES), remembered in the
--- filesync_eink_per_page cookie.
---
--- Kobo's browser forgets cookies when it is closed but keeps localStorage,
--- so a few lines of ES5 in <head> copy those choices into localStorage
--- and, in a new browser session, put them back into the cookies and reload
--- once, before the page is drawn. Without JavaScript the page works the same,
--- the choices just last one session.
---
--- Book covers (from /api/cover) appear only in browsers that report a colour
--- screen, through CSS @media (color): they are CSS backgrounds inside that
--- query, so other browsers never download them, and a book without a cover
--- shows nothing rather than a broken image. ?covers=0|1 turns them off/on,
--- remembered in the filesync_eink_covers cookie (default on).
---
--- Everything here is pure (no KOReader, no sockets) so it can be unit
--- tested; httpserver.lua does the I/O.

local Mobi = require("filesync/mobi")

local Eink = {}

local MODE_COOKIE = "filesync_eink"
local PER_PAGE_COOKIE = "filesync_eink_per_page"
local COVERS_COOKIE = "filesync_eink_covers"
local VIEW_COOKIE = "filesync_eink_view"
local COOKIE_MAX_AGE = 365 * 24 * 60 * 60

Eink.PER_PAGE_CHOICES = { 5, 10, 15, 20, 30 }
-- On a Kobo Libra Colour about 7 rows with covers, or 10 without, fit
-- between the browser's toolbars.
Eink.DEFAULT_PER_PAGE = 10

-- Lua patterns matched against the User-Agent header.
local EINK_USER_AGENTS = {
    "Kobo Touch",
    "Kindle/%d",
}

local SORT_FIELDS = { name = true, date = true, size = true, type = true }
local VIEWS = { books = true, folders = true }
local DEFAULT_VIEW = "books"

-- Formats FileOps:getBookCover can extract a cover from.
local COVER_EXTENSIONS = { epub = true }
for extension in pairs(Mobi.EXTENSIONS) do COVER_EXTENSIONS[extension] = true end

-- Sort links offered on the page: label msgid, sort field, order.
local SORT_LINKS = {
    { "Name A-Z", "name", "asc" },
    { "Newest first", "date", "desc" },
    { "Largest first", "size", "desc" },
}

local STYLE = [[
body{margin:0 12px 24px;font-family:serif;font-size:20px;line-height:1.3;color:#000;background:#fff}
h1{font-size:24px;margin:10px 0}
a{color:#000}
p{margin:10px 0}
form{margin:10px 0}
input{font-size:20px;padding:6px;border:2px solid #000;background:#fff;color:#000}
.bar a,.bar b{display:inline-block;padding:6px 10px;margin:0 4px 6px 0;border:2px solid #000;text-decoration:none}
.bar b{background:#000;color:#fff}
ul{list-style:none;margin:0;padding:0;border-top:2px solid #000}
li{border-bottom:1px solid #000}
li a{display:block;padding:8px 4px;text-decoration:none;word-wrap:break-word;overflow:hidden}
.dir,.title{font-weight:bold}
.title{display:block}
.meta{display:block;font-size:15px}
.cover,.color-only{display:none}
@media (color){
.cover{display:block;float:left;width:48px;height:72px;margin:0 10px 0 0;background-repeat:no-repeat;background-position:center;background-size:contain}
[dir=rtl] .cover{float:right;margin:0 0 0 10px}
.color-only{display:block}
}
]]

-- Keeps the page-size and covers cookies across browser sessions through
-- localStorage (see the header). ES5; any failure leaves the page as served.
local PREFS_SCRIPT = [[
(function () {
    try {
        var names = ["]] .. PER_PAGE_COOKIE .. [[", "]] .. COVERS_COOKIE .. [[", "]] .. VIEW_COOKIE .. [["];
        var restored = null;
        for (var i = 0; i < names.length; i++) {
            var found = document.cookie.match(new RegExp("(?:^|; )" + names[i] + "=(\\w+)"));
            var stored = localStorage.getItem(names[i]);
            if (found) {
                localStorage.setItem(names[i], found[1]);
            } else if (stored && /^\w+$/.test(stored)) {
                document.cookie = names[i] + "=" + stored + "; Path=/; Max-Age=]] .. COOKIE_MAX_AGE .. [[";
                restored = names[i] + "=" + stored;
            }
        }
        if (restored && document.cookie.indexOf(restored) !== -1
                && !sessionStorage.getItem("filesync_eink_restored")) {
            sessionStorage.setItem("filesync_eink_restored", "1");
            location.reload();
        }
    } catch (e) {}
})();
]]

--- Whether a User-Agent header belongs to an e-reader browser.
--- @param user_agent string|nil
--- @return boolean
function Eink.isEinkUserAgent(user_agent)
    if type(user_agent) ~= "string" then return false end
    for _, pattern in ipairs(EINK_USER_AGENTS) do
        if user_agent:find(pattern) then return true end
    end
    return false
end

--- Read one cookie from a Cookie header ("a=1; b=2").
--- @param cookie_header string|nil
--- @param name string
--- @return string|nil: the value, or nil if the cookie is absent
function Eink.getCookie(cookie_header, name)
    if type(cookie_header) ~= "string" then return nil end
    for pair in cookie_header:gmatch("[^;]+") do
        local key, value = pair:match("^%s*([^=%s]+)%s*=%s*(.-)%s*$")
        if key == name then return value end
    end
    return nil
end

local function setCookie(name, value, max_age)
    return name .. "=" .. value .. "; Path=/; Max-Age=" .. max_age
end

--- Decide whether GET / serves the e-ink page.
--- @param query table: the parsed query string
--- @param headers table: request headers, lowercased keys
--- @return boolean: true for the e-ink page
--- @return string|nil: a Set-Cookie header value to send, if any
function Eink.chooseMode(query, headers)
    if query.eink == "1" then
        return true, setCookie(MODE_COOKIE, "1", COOKIE_MAX_AGE)
    elseif query.eink == "0" then
        return false, setCookie(MODE_COOKIE, "", 0)
    end
    if Eink.getCookie(headers.cookie, MODE_COOKIE) == "1" then
        return true
    end
    return Eink.isEinkUserAgent(headers["user-agent"])
end

local function isPerPageChoice(n)
    for _, choice in ipairs(Eink.PER_PAGE_CHOICES) do
        if n == choice then return true end
    end
    return false
end

--- Entries per page: ?per_page= beats the cookie, which beats the default.
--- Values outside PER_PAGE_CHOICES are ignored.
--- @param query table: the parsed query string
--- @param headers table: request headers, lowercased keys
--- @return number: entries per page
--- @return string|nil: a Set-Cookie header value when ?per_page= changed it
function Eink.choosePerPage(query, headers)
    local requested = tonumber(query.per_page)
    if isPerPageChoice(requested) then
        return requested, setCookie(PER_PAGE_COOKIE, tostring(requested), COOKIE_MAX_AGE)
    end
    local stored = tonumber(Eink.getCookie(headers.cookie, PER_PAGE_COOKIE))
    if isPerPageChoice(stored) then
        return stored
    end
    return Eink.DEFAULT_PER_PAGE
end

--- Whether to show book covers (in colour browsers): ?covers=1|0 beats the
--- cookie, which beats the default (on).
--- @param query table: the parsed query string
--- @param headers table: request headers, lowercased keys
--- @return boolean
--- @return string|nil: a Set-Cookie header value when ?covers= changed it
function Eink.chooseCovers(query, headers)
    if query.covers == "1" or query.covers == "0" then
        return query.covers == "1", setCookie(COVERS_COOKIE, query.covers, COOKIE_MAX_AGE)
    end
    return Eink.getCookie(headers.cookie, COVERS_COOKIE) ~= "0"
end

--- Which view to show: ?view= beats ?path= (a folder, so the folders view),
--- which beats the cookie, which beats the default (books). Links in the
--- folders view carry ?path=, so they need no ?view=, and links that predate
--- the books view keep working.
--- @param query table: the parsed query string
--- @param headers table: request headers, lowercased keys
--- @return string: "books" or "folders"
--- @return string|nil: a Set-Cookie header value when ?view= changed it
function Eink.chooseView(query, headers)
    if VIEWS[query.view] then
        return query.view, setCookie(VIEW_COOKIE, query.view, COOKIE_MAX_AGE)
    end
    if query.path and query.path ~= "" then
        return "folders"
    end
    local stored = Eink.getCookie(headers.cookie, VIEW_COOKIE)
    return VIEWS[stored] and stored or DEFAULT_VIEW
end

--- Validated listing parameters from the query string.
--- @param query table: the parsed query string
--- @param home_path string: folder shown when ?path= is absent
--- @param per_page number: from choosePerPage
--- @param lang string|nil: KOReader UI language, e.g. "en", "pt_BR"
--- @param covers boolean|nil: from chooseCovers (default on)
--- @param view string|nil: from chooseView (default books)
--- @return table: {path, sort, order, filter, page, per_page, lang, covers, view}
function Eink.listingState(query, home_path, per_page, lang, covers, view)
    local page = math.floor(tonumber(query.page) or 1)
    if page < 1 then page = 1 end
    return {
        path = (query.path and query.path ~= "") and query.path or home_path,
        sort = SORT_FIELDS[query.sort] and query.sort or "name",
        order = query.order == "desc" and "desc" or "asc",
        filter = query.filter or "",
        page = page,
        per_page = per_page,
        lang = lang or "en",
        covers = covers ~= false,
        view = view or DEFAULT_VIEW,
    }
end

local function escapeHtml(s)
    return (tostring(s):gsub("[&<>\"']", {
        ["&"] = "&amp;", ["<"] = "&lt;", [">"] = "&gt;", ["\""] = "&quot;", ["'"] = "&#39;",
    }))
end

-- Percent-encode a query value. "/" stays readable; "+" must be encoded,
-- since the server decodes "+" as a space.
local function encodeQueryValue(s)
    return (tostring(s):gsub("[^%w%-%._~/]", function(c)
        return string.format("%%%02X", c:byte())
    end))
end

local URL_DEFAULTS = { sort = "name", order = "asc", filter = "", page = 1 }
local URL_KEYS = { "view", "path", "sort", "order", "filter", "page", "per_page", "covers" }

-- Link to the e-ink page for `state` with some parameters changed. Default
-- values are left out to keep URLs short. The folders view always keeps path,
-- because a missing path means the home folder, not the root, and that is
-- also what selects the view; the books view has no path and says view=books.
local function pageUrl(state, changes)
    local params = {
        view = state.view, path = state.path, sort = state.sort, order = state.order,
        filter = state.filter, page = state.page,
    }
    for key, value in pairs(changes or {}) do params[key] = value end
    if params.view == "folders" then params.view = nil else params.path = nil end
    local parts = {}
    for _, key in ipairs(URL_KEYS) do
        local value = params[key]
        if value ~= nil and value ~= URL_DEFAULTS[key] then
            parts[#parts + 1] = key .. "=" .. encodeQueryValue(value)
        end
    end
    return "/?" .. table.concat(parts, "&")
end

local function link(href, text, class)
    return '<a href="' .. escapeHtml(href) .. '"' .. (class and (' class="' .. class .. '"') or "")
        .. ">" .. text .. "</a>"
end

local function document(state, body, _, extra_style)
    local lang = tostring(state.lang)
    return table.concat({
        "<!DOCTYPE html>\n",
        '<html lang="', escapeHtml((lang:gsub("_", "-"))), '" dir="', lang:match("^ar") and "rtl" or "ltr", '">\n',
        '<head>\n<meta charset="UTF-8">\n',
        '<meta name="viewport" content="width=device-width, initial-scale=1.0">\n',
        "<title>", escapeHtml(_("FileSync")), "</title>\n",
        "<style>\n", STYLE, extra_style or "", "</style>\n",
        "<script>\n", PREFS_SCRIPT, "</script>\n</head>\n<body>\n",
        "<h1>", escapeHtml(_("FileSync")), "</h1>\n",
        body,
        '<p>', link("/?eink=0#" .. encodeQueryValue(state.path), escapeHtml(_("Full version"))), "</p>\n",
        "</body>\n</html>\n",
    })
end

local function breadcrumbs(listing, state, _)
    local crumbs = listing.breadcrumbs or {}
    local parts = {}
    for i, crumb in ipairs(crumbs) do
        local name = (i == 1) and _("Home") or crumb.name
        if i == #crumbs then
            parts[#parts + 1] = "<b>" .. escapeHtml(name) .. "</b>"
        else
            parts[#parts + 1] = link(pageUrl(state, { path = crumb.path, page = 1, filter = "" }), escapeHtml(name))
        end
    end
    return "<p>" .. table.concat(parts, " / ") .. "</p>\n"
end

local function filterForm(state, _)
    local hidden = {}
    if state.view == "folders" then hidden.path = state.path else hidden.view = state.view end
    if state.sort ~= URL_DEFAULTS.sort then hidden.sort = state.sort end
    if state.order ~= URL_DEFAULTS.order then hidden.order = state.order end
    local html = { '<form method="get" action="/">' }
    for _i, key in ipairs({ "view", "path", "sort", "order" }) do
        if hidden[key] then
            html[#html + 1] = '<input type="hidden" name="' .. key .. '" value="' .. escapeHtml(hidden[key]) .. '">'
        end
    end
    html[#html + 1] = '<input type="text" name="filter" value="' .. escapeHtml(state.filter)
        .. '" placeholder="' .. escapeHtml(_("Filter files...")) .. '"> '
    html[#html + 1] = '<input type="submit" value="' .. escapeHtml(_("Filter")) .. '">'
    html[#html + 1] = "</form>\n"
    return table.concat(html)
end

-- Books | Folders: the current view is a black label, the other a link.
local function viewBar(state, _)
    local parts = {}
    for _i, view in ipairs({ { "books", "Books" }, { "folders", "Folders" } }) do
        local label = escapeHtml(_(view[2]))
        if state.view == view[1] then
            parts[#parts + 1] = "<b>" .. label .. "</b>"
        else
            parts[#parts + 1] = link(pageUrl(state, { view = view[1], page = 1, filter = "" }), label)
        end
    end
    return '<p class="bar">' .. table.concat(parts, " ") .. "</p>\n"
end

local function sortBar(state, _)
    local parts = {}
    for _i, sort in ipairs(SORT_LINKS) do
        local label = escapeHtml(_(sort[1]))
        if state.sort == sort[2] and state.order == sort[3] then
            parts[#parts + 1] = "<b>" .. label .. "</b>"
        else
            parts[#parts + 1] = link(pageUrl(state, { sort = sort[2], order = sort[3], page = 1 }), label)
        end
    end
    return '<p class="bar">' .. table.concat(parts, " ") .. "</p>\n"
end

local function hasCover(entry)
    local extension = not entry.is_dir and entry.name:match("%.([^%.]+)$")
    return extension and COVER_EXTENSIONS[extension:lower()] or false
end

local function downloadLink(entry, inner)
    return link("/api/download?path=" .. encodeQueryValue(entry.path), inner)
end

local function coverSpan(cover_id)
    return cover_id and ('<span class="cover" id="' .. cover_id .. '"></span>') or ""
end

-- cover_id: id of the element that shows the book's cover, or nil.
local function entryItem(entry, state, cover_id)
    if entry.is_dir then
        return "<li>" .. link(pageUrl(state, { path = entry.path, page = 1, filter = "" }),
            escapeHtml(entry.name) .. "/", "dir") .. "</li>\n"
    end
    local meta = { entry.size_formatted or "" }
    if entry.modified and entry.modified > 0 then
        meta[#meta + 1] = os.date("%Y-%m-%d", entry.modified)
    end
    return "<li>" .. downloadLink(entry, coverSpan(cover_id) .. escapeHtml(entry.name)
        .. '<span class="meta">' .. escapeHtml(table.concat(meta, " · ")) .. "</span>") .. "</li>\n"
end

-- meta: {title, author} from FileOps:getMetadata, or nil (then the file name
-- is the title).
local function bookItem(entry, meta, cover_id)
    local info = { (entry.name:match("%.([^%.]+)$") or ""):upper(), entry.size_formatted or "" }
    local author = meta and meta.author and meta.author ~= ""
        and ('<span class="meta">' .. escapeHtml(meta.author) .. "</span>") or ""
    return "<li>" .. downloadLink(entry, coverSpan(cover_id)
        .. '<span class="title">' .. escapeHtml(meta and meta.title or entry.name) .. "</span>" .. author
        .. '<span class="meta">' .. escapeHtml(table.concat(info, " · ")) .. "</span>") .. "</li>\n"
end

local function pager(state, page, pages, _)
    if pages <= 1 then return "" end
    local parts = {}
    if page > 1 then
        parts[#parts + 1] = link(pageUrl(state, { page = page - 1 }), escapeHtml(_("Previous")))
    end
    parts[#parts + 1] = "<b>" .. page .. " / " .. pages .. "</b>"
    if page < pages then
        parts[#parts + 1] = link(pageUrl(state, { page = page + 1 }), escapeHtml(_("Next")))
    end
    return '<p class="bar">' .. table.concat(parts, " ") .. "</p>\n"
end

local function perPageBar(state, _)
    local parts = { escapeHtml(_("Per page:")) }
    for _i, n in ipairs(Eink.PER_PAGE_CHOICES) do
        if n == state.per_page then
            parts[#parts + 1] = "<b>" .. n .. "</b>"
        else
            parts[#parts + 1] = link(pageUrl(state, { per_page = n, page = 1 }), tostring(n))
        end
    end
    return '<p class="bar">' .. table.concat(parts, " ") .. "</p>\n"
end

-- Shown only in colour browsers, like the covers themselves.
local function coversBar(state, _)
    local label = state.covers and _("Hide covers") or _("Show covers")
    return '<p class="bar color-only">' .. link(pageUrl(state, { covers = state.covers and 0 or 1 }), escapeHtml(label))
        .. "</p>\n"
end

-- The part both views share: one page of `entries` as a list, then the
-- pager, per-page and covers bars. `item(entry, cover_id)` renders one <li>.
-- Returns the html and the CSS (one rule per cover, inside @media (color);
-- the URL is percent-encoded, so it holds no quote, bracket or backslash).
local function entryPage(entries, state, empty_text, item, _)
    local pages = math.max(1, math.ceil(#entries / state.per_page))
    local page = math.min(state.page, pages)
    local html, cover_rules = {}, {}
    if #entries == 0 then
        html[#html + 1] = "<p>" .. escapeHtml(empty_text) .. "</p>\n"
    else
        html[#html + 1] = "<ul>\n"
        local first = (page - 1) * state.per_page + 1
        for i = first, math.min(first + state.per_page - 1, #entries) do
            local entry, cover_id = entries[i], nil
            if state.covers and hasCover(entry) then
                cover_id = "c" .. i
                cover_rules[#cover_rules + 1] = "#" .. cover_id .. '{background-image:url("/api/cover?path='
                    .. encodeQueryValue(entry.path) .. '")}\n'
            end
            html[#html + 1] = item(entry, cover_id)
        end
        html[#html + 1] = "</ul>\n"
    end
    html[#html + 1] = pager(state, page, pages, _)
    html[#html + 1] = perPageBar(state, _)
    html[#html + 1] = coversBar(state, _)
    html[#html + 1] = "<p>" .. escapeHtml(_("To upload files, open this address on a phone or computer.")) .. "</p>\n"
    local cover_style = #cover_rules > 0 and ("@media (color){\n" .. table.concat(cover_rules) .. "}\n") or nil
    return table.concat(html), cover_style
end

--- Render a folder listing as the e-ink page (the Folders view).
--- @param listing table: FileOps:listDirectory result {path, entries, breadcrumbs}
--- @param state table: from Eink.listingState
--- @param _ function: gettext
--- @return string: the HTML page
function Eink.renderListing(listing, state, _)
    local list, cover_style = entryPage(listing.entries or {}, state, _("This folder is empty"), function(entry, cover_id)
        return entryItem(entry, state, cover_id)
    end, _)
    return document(state, viewBar(state, _) .. breadcrumbs(listing, state, _) .. filterForm(state, _)
        .. sortBar(state, _) .. list, _, cover_style)
end

--- Render the flat list of books as the e-ink page (the Books view).
--- @param books table: FileOps:listBooks result {entries, truncated}
--- @param state table: from Eink.listingState
--- @param _ function: gettext
--- @param metadata_for function: entry -> {title, author} or nil; called
---   only for the books on the page shown
--- @return string: the HTML page
function Eink.renderBooks(books, state, _, metadata_for)
    local list, cover_style = entryPage(books.entries or {}, state, _("No books found"), function(entry, cover_id)
        return bookItem(entry, metadata_for(entry), cover_id)
    end, _)
    local note = books.truncated
        and ("<p>" .. escapeHtml(_("Too many files: the list is incomplete.")) .. "</p>\n") or ""
    return document(state, viewBar(state, _) .. filterForm(state, _) .. sortBar(state, _) .. note .. list,
        _, cover_style)
end

--- Render an error (e.g. a folder that cannot be listed) as the e-ink page.
--- @param message string: shown to the user
--- @param state table: from Eink.listingState
--- @param _ function: gettext
--- @return string: the HTML page
function Eink.renderError(message, state, _)
    local body = "<p>" .. escapeHtml(message) .. "</p>\n"
        .. "<p>" .. link(pageUrl(state, { path = "/", page = 1, filter = "" }), escapeHtml(_("Home"))) .. "</p>\n"
    return document(state, body, _)
end

return Eink
