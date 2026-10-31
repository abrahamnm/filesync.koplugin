--- Tests for e-ink mode: browser detection, mode and page-size choice, and
--- the server-rendered page.

local Eink = require("filesync/eink")

-- Captured from a Kobo Libra Colour, firmware 4.46.23836 (HTTP header).
local KOBO_UA = "Mozilla/5.0 (Linux; U; Android 2.0; en-us;) AppleWebKit/538.1 (KHTML, like Gecko) "
    .. "Version/4.0 Mobile Safari/538.1 (Kobo Touch 0390/4.46.23836)"
-- The same browser's JavaScript navigator.userAgent; never sent as a header.
local KOBO_JS_UA = "Mozilla/5.0 (Unknown; Linux) AppleWebKit/538.1 (KHTML, like Gecko) Kobo eReader Safari/538.1"

local identity = function(s) return s end

local function count(haystack, needle)
    local n, start = 0, 1
    while true do
        local found = haystack:find(needle, start, true)
        if not found then return n end
        n, start = n + 1, found + #needle
    end
end

-- State of the folders view (what renderListing is given); the books view
-- tests ask for view = "books".
local function state(changes)
    local s = Eink.listingState({}, "/", 15, "en", true, "folders")
    for key, value in pairs(changes or {}) do s[key] = value end
    return s
end

local function file(name, extra)
    local entry = { name = name, path = "/Books/" .. name, is_dir = false,
                    size = 1417, size_formatted = "1.4 KB", modified = 0 }
    for key, value in pairs(extra or {}) do entry[key] = value end
    return entry
end

local function books_listing(entries)
    return {
        path = "/Books",
        entries = entries,
        breadcrumbs = { { name = "Home", path = "/" }, { name = "Books", path = "/Books" } },
    }
end

describe("filesync.eink", function()

    describe("isEinkUserAgent", function()
        it("detects the Kobo browser", function()
            assert.is_true(Eink.isEinkUserAgent(KOBO_UA))
            -- Nickel's other template, without model and firmware
            assert.is_true(Eink.isEinkUserAgent(
                "Mozilla/5.0 (Linux; U; en-us;) AppleWebKit/538.1 (KHTML, like Gecko) Version/4.0 Mobile Safari/538.1 (Kobo Touch)"))
        end)

        it("detects Kindle e-reader browsers", function()
            assert.is_true(Eink.isEinkUserAgent(
                "Mozilla/5.0 (X11; U; Linux armv7l like Android; en-us) AppleWebKit/531.2+ (KHTML, like Gecko) Version/5.0 Safari/531.2+ Kindle/3.0+"))
            assert.is_true(Eink.isEinkUserAgent(
                "Mozilla/5.0 (Linux; U; en-US) AppleWebKit/528.5+ (KHTML, like Gecko, Safari/528.5+) Version/4.0 Kindle/3.0 (screen 600x800; rotate)"))
        end)

        it("leaves phones, desktops and Kindle Fire tablets alone", function()
            for _, ua in ipairs({
                "Mozilla/5.0 (iPhone; CPU iPhone OS 17_5 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.5 Mobile/15E148 Safari/604.1",
                "Mozilla/5.0 (Linux; Android 14; Pixel 8) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/126.0.0.0 Mobile Safari/537.36",
                "Mozilla/5.0 (Macintosh; Intel Mac OS X 14.5; rv:127.0) Gecko/20100101 Firefox/127.0",
                "Mozilla/5.0 (Linux; Android 9; KFTRWI) AppleWebKit/537.36 (KHTML, like Gecko) Silk/118.3.1 like Chrome/118.0.5993.144 Safari/537.36",
                "Mozilla/5.0 (Linux; U; Android 2.3.4; en-us; Kindle Fire Build/GINGERBREAD) AppleWebKit/533.1 (KHTML, like Gecko) Version/4.0 Mobile Safari/533.1",
                KOBO_JS_UA,
            }) do
                assert.is_false(Eink.isEinkUserAgent(ua), ua)
            end
        end)

        it("handles a missing or empty User-Agent", function()
            assert.is_false(Eink.isEinkUserAgent(nil))
            assert.is_false(Eink.isEinkUserAgent(""))
        end)
    end)

    describe("getCookie", function()
        it("reads one cookie among several, ignoring spaces", function()
            local header = "fsprobe=1;  filesync_eink = 1 ;other=x"
            assert.are.equal("1", Eink.getCookie(header, "filesync_eink"))
            assert.are.equal("x", Eink.getCookie(header, "other"))
        end)

        it("does not confuse cookies that share a prefix", function()
            assert.is_nil(Eink.getCookie("filesync_eink_per_page=10", "filesync_eink"))
            assert.are.equal("10", Eink.getCookie("filesync_eink_per_page=10", "filesync_eink_per_page"))
        end)

        it("returns nil when absent, and an empty value when empty", function()
            assert.is_nil(Eink.getCookie(nil, "filesync_eink"))
            assert.is_nil(Eink.getCookie("", "filesync_eink"))
            assert.are.equal("", Eink.getCookie("filesync_eink=", "filesync_eink"))
        end)
    end)

    describe("chooseMode", function()
        it("serves the main UI to ordinary browsers, without cookies", function()
            local eink, cookie = Eink.chooseMode({}, { ["user-agent"] = "Mozilla/5.0 (iPhone)" })
            assert.is_false(eink)
            assert.is_nil(cookie)
        end)

        it("serves e-ink to a detected e-reader, without setting a cookie", function()
            local eink, cookie = Eink.chooseMode({}, { ["user-agent"] = KOBO_UA })
            assert.is_true(eink)
            assert.is_nil(cookie)
        end)

        it("remembers ?eink=1 in a cookie", function()
            local eink, cookie = Eink.chooseMode({ eink = "1" }, { ["user-agent"] = "Mozilla/5.0 (iPhone)" })
            assert.is_true(eink)
            assert.are.equal("filesync_eink=1; Path=/; Max-Age=31536000", cookie)
        end)

        it("uses the cookie on later visits", function()
            assert.is_true((Eink.chooseMode({}, { cookie = "filesync_eink=1", ["user-agent"] = "Mozilla/5.0 (iPhone)" })))
            assert.is_false((Eink.chooseMode({}, { cookie = "filesync_eink=0", ["user-agent"] = "Mozilla/5.0 (iPhone)" })))
        end)

        it("makes ?eink=0 win over detection and the cookie, and clears the cookie", function()
            local eink, cookie = Eink.chooseMode({ eink = "0" }, { cookie = "filesync_eink=1", ["user-agent"] = KOBO_UA })
            assert.is_false(eink)
            assert.are.equal("filesync_eink=; Path=/; Max-Age=0", cookie)
        end)

        it("ignores other values of ?eink", function()
            local eink, cookie = Eink.chooseMode({ eink = "yes" }, { ["user-agent"] = "Mozilla/5.0 (iPhone)" })
            assert.is_false(eink)
            assert.is_nil(cookie)
        end)
    end)

    describe("choosePerPage", function()
        it("defaults when nothing is set", function()
            local n, cookie = Eink.choosePerPage({}, {})
            assert.are.equal(Eink.DEFAULT_PER_PAGE, n)
            assert.is_nil(cookie)
        end)

        it("takes an allowed ?per_page= and remembers it", function()
            local n, cookie = Eink.choosePerPage({ per_page = "10" }, { cookie = "filesync_eink_per_page=20" })
            assert.are.equal(10, n)
            assert.are.equal("filesync_eink_per_page=10; Path=/; Max-Age=31536000", cookie)
        end)

        it("uses the cookie when the query has no valid value", function()
            for _, bad in ipairs({ "7", "abc", "-5", "1e9", "" }) do
                local n, cookie = Eink.choosePerPage({ per_page = bad }, { cookie = "filesync_eink_per_page=20" })
                assert.are.equal(20, n, bad)
                assert.is_nil(cookie)
            end
        end)

        it("ignores a cookie outside the allowed values", function()
            assert.are.equal(Eink.DEFAULT_PER_PAGE, (Eink.choosePerPage({}, { cookie = "filesync_eink_per_page=1000" })))
        end)
    end)

    describe("chooseCovers", function()
        it("shows covers by default", function()
            local covers, cookie = Eink.chooseCovers({}, {})
            assert.is_true(covers)
            assert.is_nil(cookie)
        end)

        it("takes ?covers=0 or 1 and remembers it", function()
            local covers, cookie = Eink.chooseCovers({ covers = "0" }, {})
            assert.is_false(covers)
            assert.are.equal("filesync_eink_covers=0; Path=/; Max-Age=31536000", cookie)
            covers, cookie = Eink.chooseCovers({ covers = "1" }, { cookie = "filesync_eink_covers=0" })
            assert.is_true(covers)
            assert.are.equal("filesync_eink_covers=1; Path=/; Max-Age=31536000", cookie)
        end)

        it("uses the cookie, and ignores other query values", function()
            assert.is_false((Eink.chooseCovers({}, { cookie = "filesync_eink_covers=0" })))
            local covers, cookie = Eink.chooseCovers({ covers = "maybe" }, { cookie = "filesync_eink_covers=0" })
            assert.is_false(covers)
            assert.is_nil(cookie)
        end)
    end)

    describe("chooseView", function()
        it("defaults to the books view", function()
            local view, set_cookie = Eink.chooseView({}, {})
            assert.are.equal("books", view)
            assert.is_nil(set_cookie)
        end)

        it("takes ?view= and remembers it in a cookie", function()
            local view, set_cookie = Eink.chooseView({ view = "folders" }, {})
            assert.are.equal("folders", view)
            assert.are.equal("filesync_eink_view=folders; Path=/; Max-Age=31536000", set_cookie)
            view, set_cookie = Eink.chooseView({ view = "books" }, { cookie = "filesync_eink_view=folders" })
            assert.are.equal("books", view)
            assert.are.equal("filesync_eink_view=books; Path=/; Max-Age=31536000", set_cookie)
        end)

        it("uses the cookie when there is no ?view= or ?path=", function()
            assert.are.equal("folders", (Eink.chooseView({}, { cookie = "a=1; filesync_eink_view=folders" })))
            assert.are.equal("books", (Eink.chooseView({}, { cookie = "filesync_eink_view=books" })))
        end)

        it("shows the folders view for a link with ?path=, whatever the cookie says", function()
            local view, set_cookie = Eink.chooseView({ path = "/Books" }, { cookie = "filesync_eink_view=books" })
            assert.are.equal("folders", view)
            assert.is_nil(set_cookie)
            assert.are.equal("books", (Eink.chooseView({ path = "" }, {})))
        end)

        it("ignores values that are not a view", function()
            assert.are.equal("books", (Eink.chooseView({ view = "evil" }, { cookie = "filesync_eink_view=<x>" })))
            local _, set_cookie = Eink.chooseView({ view = "evil" }, {})
            assert.is_nil(set_cookie)
        end)
    end)

    describe("listingState", function()
        it("starts at the home folder, sorted by name, with covers", function()
            local s = Eink.listingState({}, "/Books", 15, "it")
            assert.are.same({ path = "/Books", sort = "name", order = "asc", filter = "",
                              page = 1, per_page = 15, lang = "it", covers = true, view = "books" }, s)
            assert.are.equal("folders", Eink.listingState({}, "/Books", 15, "it", true, "folders").view)
            assert.is_false(Eink.listingState({}, "/Books", 15, "it", false).covers)
        end)

        it("keeps valid parameters and replaces invalid ones", function()
            local s = Eink.listingState({ path = "/x", sort = "date", order = "desc", filter = "abc", page = "3" }, "/", 10)
            assert.are.same({ path = "/x", sort = "date", order = "desc", filter = "abc",
                              page = 3, per_page = 10, lang = "en", covers = true, view = "books" }, s)
            s = Eink.listingState({ path = "", sort = "evil", order = "sideways", page = "-2" }, "/home", 10)
            assert.are.equal("/home", s.path)
            assert.are.equal("name", s.sort)
            assert.are.equal("asc", s.order)
            assert.are.equal(1, s.page)
            assert.are.equal(2, Eink.listingState({ page = "2.7" }, "/", 10).page)
            assert.are.equal(1, Eink.listingState({ page = "abc" }, "/", 10).page)
        end)
    end)

    describe("renderListing", function()
        it("escapes file names", function()
            local html = Eink.renderListing(books_listing({ file([[<b>&"'.epub]]) }), state({ path = "/Books" }), identity)
            assert.is_truthy(html:find("&lt;b&gt;&amp;&quot;&#39;.epub", 1, true))
            assert.is_nil(html:find("<b>&\"'", 1, true))
        end)

        it("links files to /api/download with an encoded path", function()
            local html = Eink.renderListing(books_listing({
                file("A & B #1?+%.epub"),
                file("Città.epub"),
            }), state({ path = "/Books" }), identity)
            assert.is_truthy(html:find('href="/api/download?path=/Books/A%20%26%20B%20%231%3F%2B%25.epub"', 1, true))
            assert.is_truthy(html:find('href="/api/download?path=/Books/Citt%C3%A0.epub"', 1, true))
        end)

        it("links folders to their e-ink listing and marks them", function()
            local html = Eink.renderListing(books_listing({
                { name = "Sci Fi", path = "/Books/Sci Fi", is_dir = true },
            }), state({ path = "/Books" }), identity)
            assert.is_truthy(html:find('<a href="/?path=/Books/Sci%20Fi" class="dir">Sci Fi/</a>', 1, true))
        end)

        it("keeps a non-default sort in links and escapes & in attributes", function()
            local html = Eink.renderListing(books_listing({
                { name = "Sub", path = "/Books/Sub", is_dir = true },
            }), state({ path = "/Books", sort = "date", order = "desc" }), identity)
            assert.is_truthy(html:find('href="/?path=/Books/Sub&amp;sort=date&amp;order=desc"', 1, true))
        end)

        it("shows breadcrumbs from the root, with the current folder unlinked", function()
            local html = Eink.renderListing(books_listing({}), state({ path = "/Books" }),
                function(s) return "[" .. s .. "]" end)
            assert.is_truthy(html:find('<a href="/?path=/">[Home]</a> / <b>Books</b>', 1, true))
        end)

        it("says when a folder is empty", function()
            local html = Eink.renderListing(books_listing({}), state({ path = "/Books" }), identity)
            assert.is_truthy(html:find("This folder is empty", 1, true))
            assert.is_nil(html:find("<ul>", 1, true))
        end)

        it("splits long folders into pages and clamps the page number", function()
            local entries = {}
            for i = 1, 32 do entries[i] = file(string.format("book %02d.epub", i)) end
            local listing = books_listing(entries)

            local first = Eink.renderListing(listing, state({ path = "/Books" }), identity)
            assert.are.equal(15, count(first, "<li>"))
            assert.is_truthy(first:find("book 01.epub", 1, true))
            assert.is_nil(first:find("book 16.epub", 1, true))
            assert.is_truthy(first:find("<b>1 / 3</b>", 1, true))
            assert.is_truthy(first:find('<a href="/?path=/Books&amp;page=2">Next</a>', 1, true))
            assert.is_nil(first:find(">Previous<", 1, true))

            local last = Eink.renderListing(listing, state({ path = "/Books", page = 99 }), identity)
            assert.are.equal(2, count(last, "<li>"))
            assert.is_truthy(last:find("book 32.epub", 1, true))
            assert.is_truthy(last:find("<b>3 / 3</b>", 1, true))
            assert.is_truthy(last:find('<a href="/?path=/Books&amp;page=2">Previous</a>', 1, true))
            assert.is_nil(last:find(">Next<", 1, true))
        end)

        it("shows no pager when everything fits", function()
            local html = Eink.renderListing(books_listing({ file("a.epub") }), state({ path = "/Books" }), identity)
            assert.is_nil(html:find(" / 1</b>", 1, true))
        end)

        it("marks the current sort and page size and links the others", function()
            local html = Eink.renderListing(books_listing({}), state({ path = "/Books", per_page = 10 }), identity)
            assert.is_truthy(html:find("<b>Name A-Z</b>", 1, true))
            assert.is_truthy(html:find('<a href="/?path=/Books&amp;sort=date&amp;order=desc">Newest first</a>', 1, true))
            assert.is_truthy(html:find("<b>10</b>", 1, true))
            assert.is_truthy(html:find('<a href="/?path=/Books&amp;per_page=20">20</a>', 1, true))
        end)

        it("keeps the folder and sort in the filter form and escapes the filter", function()
            local html = Eink.renderListing(books_listing({}),
                state({ path = "/Books", sort = "size", order = "desc", filter = [["><x]] }), identity)
            assert.is_truthy(html:find('<input type="hidden" name="path" value="/Books">', 1, true))
            assert.is_truthy(html:find('<input type="hidden" name="sort" value="size">', 1, true))
            assert.is_truthy(html:find('name="filter" value="&quot;&gt;&lt;x"', 1, true))
        end)

        it("is plain HTML: no animation, transition, CSS variables or file input", function()
            local entries = { { name = "Sub", path = "/Books/Sub", is_dir = true }, file("a.epub") }
            local html = Eink.renderListing(books_listing(entries), state({ path = "/Books" }), identity)
            for _, banned in ipairs({ "animation", "transition", "var(--", "type=\"file\"" }) do
                assert.is_nil(html:lower():find(banned, 1, true), banned)
            end
        end)

        it("has one small script that only keeps the choices across browser sessions", function()
            local html = Eink.renderListing(books_listing({}), state({ path = "/Books" }), identity)
            assert.are.equal(1, count(html, "<script"))
            local script = html:match("<script>\n(.-)</script>")
            -- Works on the two choice cookies, through localStorage
            assert.is_truthy(script:find('"filesync_eink_per_page", "filesync_eink_covers", "filesync_eink_view"', 1, true))
            assert.is_truthy(script:find("localStorage.setItem", 1, true))
            -- Reloads at most once per session, and only if the cookie stuck
            assert.are.equal(1, count(script, "location.reload()"))
            assert.is_truthy(script:find('sessionStorage.getItem("filesync_eink_restored")', 1, true))
            assert.is_truthy(script:find("document.cookie.indexOf(restored) !== -1", 1, true))
            -- No network, timers or modern syntax
            for _, banned in ipairs({ "fetch", "XMLHttpRequest", "setTimeout", "setInterval",
                                      "=>", "let ", "const ", "`" }) do
                assert.is_nil(script:find(banned, 1, true), banned)
            end
            -- Placed in <head>, so a restoring reload happens before anything is drawn
            assert.is_truthy(html:find("</script>\n</head>", 1, true))
        end)

        it("always offers the upload hint and the way back to the full version", function()
            local html = Eink.renderListing(books_listing({}), state({ path = "/Books" }), identity)
            assert.is_truthy(html:find("To upload files, open this address on a phone or computer.", 1, true))
            assert.is_truthy(html:find('<a href="/?eink=0#/Books">Full version</a>', 1, true))
        end)

        it("sets the language and right-to-left direction", function()
            local html = Eink.renderListing(books_listing({}), state({ lang = "pt_BR" }), identity)
            assert.is_truthy(html:find('<html lang="pt-BR" dir="ltr">', 1, true))
            html = Eink.renderListing(books_listing({}), state({ lang = "ar" }), identity)
            assert.is_truthy(html:find('<html lang="ar" dir="rtl">', 1, true))
        end)

        it("shows covers of EPUB and MOBI-family books, only in colour browsers", function()
            local html = Eink.renderListing(books_listing({
                { name = "Sub", path = "/Books/Sub", is_dir = true },
                file("A & B.epub"),
                file("Kindle.AZW3"),
                file("Paper.pdf"),
            }), state({ path = "/Books" }), identity)
            -- Each cover is a CSS background inside @media (color), with the
            -- book's path percent-encoded in the URL.
            local covers_css = html:match("@media %(color%){\n(#c.-\n)}\n")
            assert.is_truthy(covers_css)
            assert.is_truthy(covers_css:find('#c2{background-image:url("/api/cover?path=/Books/A%20%26%20B.epub")}', 1, true))
            assert.is_truthy(covers_css:find('#c3{background-image:url("/api/cover?path=/Books/Kindle.AZW3")}', 1, true))
            assert.are.equal(2, count(html, "/api/cover?"))
            assert.is_truthy(html:find('<span class="cover" id="c2"></span>A &amp; B.epub', 1, true))
            -- Hidden unless the browser reports colour
            assert.is_truthy(html:find(".cover,.color-only{display:none}", 1, true))
            assert.is_nil(html:find("<img", 1, true))
        end)

        it("offers to hide covers, in colour browsers only", function()
            local html = Eink.renderListing(books_listing({}), state({ path = "/Books" }), identity)
            assert.is_truthy(html:find('<p class="bar color-only"><a href="/?path=/Books&amp;covers=0">Hide covers</a></p>', 1, true))
        end)

        it("requests no covers when they are off, and offers to show them", function()
            local html = Eink.renderListing(books_listing({ file("a.epub") }),
                state({ path = "/Books", covers = false }), identity)
            assert.is_nil(html:find("/api/cover", 1, true))
            assert.is_nil(html:find('class="cover"', 1, true))
            assert.is_truthy(html:find('<a href="/?path=/Books&amp;covers=1">Show covers</a>', 1, true))
        end)

        it("numbers cover ids by position, across pages", function()
            local entries = {}
            for i = 1, 20 do entries[i] = file(string.format("book %02d.epub", i)) end
            local html = Eink.renderListing(books_listing(entries), state({ path = "/Books", page = 2 }), identity)
            assert.is_truthy(html:find('<span class="cover" id="c16"></span>book 16.epub', 1, true))
            assert.is_nil(html:find('id="c1"', 1, true))
            assert.are.equal(5, count(html, "/api/cover?"))
        end)

        it("shows size and date under a file name", function()
            local modified = os.time({ year = 2026, month = 10, day = 19, hour = 12 })
            local html = Eink.renderListing(books_listing({ file("a.epub", { modified = modified }) }),
                state({ path = "/Books" }), identity)
            assert.is_truthy(html:find('<span class="meta">1.4 KB · 2026-10-19</span>', 1, true))
        end)
    end)

    describe("view bar", function()
        it("marks the current view and links the other one, in both views", function()
            local folders = Eink.renderListing(books_listing({}), state({ path = "/Books" }), identity)
            assert.is_truthy(folders:find('<p class="bar"><a href="/?view=books">Books</a> <b>Folders</b></p>', 1, true))
            local books = Eink.renderBooks({ entries = {} }, state({ view = "books", path = "/Books" }), identity, function() end)
            assert.is_truthy(books:find('<p class="bar"><b>Books</b> <a href="/?path=/Books">Folders</a></p>', 1, true))
        end)

        it("keeps the sort when switching view, but not the filter or page", function()
            local html = Eink.renderListing(books_listing({}),
                state({ path = "/Books", sort = "size", order = "desc", filter = "x", page = 3 }), identity)
            assert.is_truthy(html:find('<a href="/?view=books&amp;sort=size&amp;order=desc">Books</a>', 1, true))
        end)
    end)

    describe("renderBooks", function()
        local function book(name, extra)
            local entry = { name = name, path = "/Books/Sub/" .. name, is_dir = false,
                            size = 2048, size_formatted = "2.0 KB", modified = 0, type = "ebook" }
            for key, value in pairs(extra or {}) do entry[key] = value end
            return entry
        end
        local function books_state(changes)
            local merged = { view = "books", path = "/Books" }
            for key, value in pairs(changes or {}) do merged[key] = value end
            return state(merged)
        end
        local function render(entries, changes, metadata_for)
            return Eink.renderBooks({ entries = entries }, books_state(changes), identity,
                metadata_for or function() return nil end)
        end

        it("lists each book with title, author, format and size, linked to /api/download", function()
            local html = render({ book("dune.epub") }, nil, function()
                return { title = "Dune", author = "Frank Herbert" }
            end)
            assert.is_truthy(html:find('<a href="/api/download?path=/Books/Sub/dune.epub">', 1, true))
            assert.is_truthy(html:find('<span class="title">Dune</span>', 1, true))
            assert.is_truthy(html:find('<span class="meta">Frank Herbert</span>', 1, true))
            assert.is_truthy(html:find('<span class="meta">EPUB · 2.0 KB</span>', 1, true))
        end)

        it("falls back to the file name, and shows no author line without one", function()
            local html = render({ book("dune.epub") })
            assert.is_truthy(html:find('<span class="title">dune.epub</span>', 1, true))
            assert.are.equal(1, count(html, '<span class="meta">'))
            html = render({ book("a.epub") }, nil, function() return { title = "A", author = "" } end)
            assert.are.equal(1, count(html, '<span class="meta">'))
        end)

        it("escapes title, author and file name", function()
            local html = render({ book([[<i>.epub]]) }, nil, function()
                return { title = [[<b>"T"</b>]], author = "A & B" }
            end)
            assert.is_truthy(html:find("&lt;b&gt;&quot;T&quot;&lt;/b&gt;", 1, true))
            assert.is_truthy(html:find("A &amp; B", 1, true))
            assert.is_nil(html:find("<b>\"T\"", 1, true))
        end)

        it("asks for metadata only for the books on the page shown", function()
            local entries = {}
            for i = 1, 32 do entries[i] = book(string.format("book %02d.epub", i)) end
            local asked = {}
            local html = render(entries, { page = 2, per_page = 10 }, function(entry)
                asked[#asked + 1] = entry.name
                return nil
            end)
            assert.are.equal(10, #asked)
            assert.are.equal("book 11.epub", asked[1])
            assert.are.equal("book 20.epub", asked[10])
            assert.are.equal(10, count(html, "<li>"))
            assert.is_truthy(html:find("<b>2 / 4</b>", 1, true))
        end)

        it("pages and sorts with view=books links and no path", function()
            local entries = {}
            for i = 1, 12 do entries[i] = book(string.format("book %02d.epub", i)) end
            local html = render(entries, { per_page = 10, sort = "date", order = "desc" })
            assert.is_truthy(html:find('<a href="/?view=books&amp;sort=date&amp;order=desc&amp;page=2">Next</a>', 1, true))
            assert.is_truthy(html:find('<a href="/?view=books&amp;sort=size&amp;order=desc">Largest first</a>', 1, true))
            assert.is_nil(html:find("view=books&amp;path", 1, true))
        end)

        it("keeps the view in the filter form instead of a folder", function()
            local html = render({}, { sort = "size", order = "desc", filter = "du" })
            assert.is_truthy(html:find('<input type="hidden" name="view" value="books">', 1, true))
            assert.is_truthy(html:find('<input type="hidden" name="sort" value="size">', 1, true))
            assert.is_nil(html:find('name="path"', 1, true))
            assert.is_truthy(html:find('name="filter" value="du"', 1, true))
        end)

        it("says when there are no books, and when the scan was cut short", function()
            local html = render({})
            assert.is_truthy(html:find("No books found", 1, true))
            assert.is_nil(html:find("<ul>", 1, true))
            assert.is_nil(html:find("incomplete", 1, true))
            html = Eink.renderBooks({ entries = {}, truncated = true }, books_state(), identity, function() end)
            assert.is_truthy(html:find("Too many files: the list is incomplete.", 1, true))
        end)

        it("shows covers of EPUB and MOBI-family books only, like the folders view", function()
            local html = render({ book("a.epub"), book("b.pdf"), book("c.azw3") })
            assert.are.equal(2, count(html, "/api/cover?"))
            assert.is_truthy(html:find('#c1{background-image:url("/api/cover?path=/Books/Sub/a.epub")}', 1, true))
            assert.is_truthy(html:find('<span class="cover" id="c1"></span><span class="title">a.epub</span>', 1, true))
            assert.is_nil(render({ book("a.epub") }, { covers = false }):find("/api/cover", 1, true))
        end)

        it("is plain HTML and keeps the way back to the full version and the upload hint", function()
            local html = render({ book("a.epub") })
            for _, banned in ipairs({ "animation", "transition", "var(--", "type=\"file\"" }) do
                assert.is_nil(html:lower():find(banned, 1, true), banned)
            end
            assert.are.equal(1, count(html, "<script"))
            assert.is_truthy(html:find("To upload files, open this address on a phone or computer.", 1, true))
            assert.is_truthy(html:find("Full version", 1, true))
        end)
    end)

    describe("renderError", function()
        it("escapes the message and links home", function()
            local html = Eink.renderError("Path not found: /<x>", state({ path = "/<x>" }), identity)
            assert.is_truthy(html:find("Path not found: /&lt;x&gt;", 1, true))
            assert.is_truthy(html:find('<a href="/?path=/">Home</a>', 1, true))
            assert.is_nil(html:find("<x>", 1, true))
        end)
    end)
end)
