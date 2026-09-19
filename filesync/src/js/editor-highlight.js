// ===== In-browser syntax highlighter =====
// A small, self-contained, dependency-free tokenizer used by the editor.
// It maps a filename/language to a set of regex rules and produces
// HTML-safe, class-tagged markup (see editor CSS for token colours).
//
// ES5 only (no arrow functions / template literals / lookbehind / sticky
// regex) to stay compatible with the older WebKit engines on e-readers.
//
// Design notes
// ------------
// Scanning is a single left-to-right pass. At each position the ordered
// rule list is tried; the first rule whose pattern matches *at that
// position* wins. Patterns are anchored (a leading '^' is inserted at
// build time) so exec never scans ahead — keeping the pass roughly linear.
// Block comments span lines and are handled with explicit state.
//   Public API:
//     EditorHighlight.detectLanguage(filename) -> language id or null
//     EditorHighlight.highlight(code, language) -> HTML string (escaped)

var EditorHighlight = (function () {
    'use strict';

    // ------------------------------------------------------------------
    // Language detection tables
    // ------------------------------------------------------------------

    var LANG_BY_EXT = {
        txt: null, text: null, log: null,
        md: 'markdown', markdown: 'markdown', mkd: 'markdown', mdown: 'markdown',
        lua: 'lua',
        js: 'javascript', mjs: 'javascript', cjs: 'javascript', jsx: 'javascript',
        ts: 'typescript', tsx: 'typescript',
        json: 'json',
        xml: 'xml', svg: 'xml', xhtml: 'xml',
        yml: 'yaml', yaml: 'yaml',
        toml: 'toml',
        ini: 'ini', cfg: 'ini', conf: 'ini', properties: 'ini', env: 'ini', editorconfig: 'ini',
        sh: 'bash', bash: 'bash', zsh: 'bash',
        py: 'python', pyw: 'python',
        rb: 'ruby',
        php: 'php',
        go: 'go',
        rs: 'rust',
        c: 'c', h: 'c',
        cpp: 'cpp', hpp: 'cpp', cc: 'cpp', cxx: 'cpp',
        cs: 'csharp',
        java: 'java',
        kt: 'kotlin', kts: 'kotlin',
        css: 'css',
        scss: 'scss', sass: 'scss',
        less: 'less',
        sql: 'sql',
        html: 'html', htm: 'html',
        csv: 'csv',
    };

    var LANG_BY_FILENAME = {
        'makefile': 'makefile',
        'gnumakefile': 'makefile',
        'dockerfile': 'dockerfile',
        'containerfile': 'dockerfile',
        'gemfile': 'ruby',
        'rakefile': 'ruby',
        'cmakelists.txt': 'cmake',
        '.bashrc': 'bash',
        '.bash_profile': 'bash',
        '.zshrc': 'bash',
        '.profile': 'bash',
        '.gitignore': 'ini',
        '.gitattributes': 'ini',
        '.gitmodules': 'ini',
        '.editorconfig': 'ini',
        '.env': 'ini',
    };

    var KEYWORDS = {
        lua: 'and break do else elseif end false for function goto if in local nil not or repeat return then true until while',
        javascript: 'break case catch class const continue debugger default delete do else enum export extends false finally for function if import in instanceof let new null of return static super switch this throw true try typeof var void while with yield async await',
        typescript: 'break case catch class const continue debugger default delete do else enum export extends false finally for function if import in instanceof let new null of return static super switch this throw true try typeof var void while with yield async await interface type namespace declare abstract readonly implements private protected public is keyof infer satisfies',
        python: 'and as assert async await break class continue def del elif else except False finally for from global if import in is lambda None nonlocal not or pass raise return True try while with yield',
        ruby: 'alias and BEGIN begin break case class def defined do else elsif END end ensure false for if in module next nil not or redo rescue retry return self super then true undef unless until when while yield',
        php: 'abstract and array as break callable case catch class clone const continue declare default do echo else elseif empty enddeclare endfor endforeach endif endswitch endwhile extends final finally fn for foreach function global goto if implements include include_once instanceof insteadof interface isset list namespace new or print private protected public require require_once return static switch throw trait try unset use var while xor yield',
        go: 'break case chan const continue default defer else fallthrough for func go goto if import interface map package range return select struct switch type var',
        rust: 'as async await break const continue crate dyn else enum extern false fn for if impl in let loop match mod move mut pub ref return self Self static struct super trait true type unsafe use where while',
        c: 'auto break case char const continue default do double else enum extern float for goto if inline int long register restrict return short signed sizeof static struct switch typedef union unsigned void volatile while',
        cpp: 'alignas alignof and and_eq asm atomic_cancel atomic_commit atomic_noexcept auto bitand bitor bool break case catch char char16_t char32_t class compl concept const constexpr const_cast continue co_await co_return co_yield decltype default delete do double dynamic_cast else enum explicit export extern false float for friend goto if inline int long mutable namespace new noexcept not not_eq nullptr operator or or_eq private protected public register reinterpret_cast requires return short signed sizeof static static_assert static_cast struct switch template this thread_local throw true try typedef typeid typename union unsigned using virtual void volatile wchar_t while xor xor_eq',
        java: 'abstract assert boolean break byte case catch char class const continue default do double else enum extends final finally float for goto if implements import instanceof int interface long native new package private protected public return short static strictfp super switch synchronized this throw throws transient try void volatile while true false null',
        csharp: 'abstract as base bool break byte case catch char checked class const continue decimal default delegate do double else enum event explicit extern false finally fixed float for foreach goto if implicit in int interface internal is lock long namespace new null object operator out override params private protected public readonly ref return sbyte sealed short sizeof stackalloc static string struct switch this throw true try typeof uint ulong unchecked unsafe ushort using virtual void volatile while async await',
        bash: 'if then else elif fi case esac for while until do done function select time in coproc',
        css: 'inherit initial unset auto none',
        scss: 'inherit initial unset auto none if else each for while mixin include extend function return',
        less: 'inherit initial unset auto none when',
        sql: 'select from where insert into values update set delete create table index view drop alter add column primary key foreign references not null default and or in like between is exists as asc desc group by order having join inner left right full outer on union all distinct limit offset case when then else end begin commit rollback transaction if while',
        kotlin: 'as break class continue do else false for fun if in interface is null object package return super this throw true try typealias typeof val var when while by catch constructor delegate dynamic field file finally get import init param property receiver set setparam where actual abstract annotation companion const crossinline data enum expect external final infix inline inner internal lateinit noinline open operator out override private protected public reified sealed suspend tailrec vararg',
    };

    var BUILTINS = {
        javascript: 'console window document globalThis Object Array String Number Boolean Promise JSON Math Date RegExp Error parseInt parseFloat isNaN undefined NaN Infinity fetch setTimeout setInterval Map Set Symbol WeakMap WeakSet Proxy Reflect',
        lua: 'print ipairs pairs tostring tonumber type error assert pcall xpcall select unpack require setmetatable getmetatable rawget rawset collectgarbage os io string table math coroutine debug _G',
        python: 'print len range str int float list dict set tuple enumerate zip map filter sorted sum min max abs input open isinstance issubclass type super object Exception ValueError TypeError KeyError IndexError self repr round hex oct chr ord bool bytes bytearray frozenset',
        bash: 'echo cd pwd ls cat grep sed awk find xargs mkdir rm mv cp touch chmod sudo export source set unset printf read test true false',
        c: 'printf fprintf sprintf snprintf scanf malloc calloc realloc free memcpy memset strlen strcmp strcpy exit abort',
        cpp: 'cout cin cerr endl make_shared make_unique move forward swap static_cast dynamic_cast reinterpret_cast const_cast',
    };

    var TYPES = {
        typescript: 'string number boolean any void never unknown object symbol bigint',
        c: 'size_t int8_t int16_t int32_t int64_t uint8_t uint16_t uint32_t uint64_t intptr_t uintptr_t FILE va_list time_t off_t',
        cpp: 'string vector map set unordered_map list deque stack pair iterator ostream istream cout cin cerr',
        java: 'String Integer Long Double Float Boolean Character Byte Short Object Class System Exception RuntimeException Math',
        csharp: 'string int long float double decimal bool byte char object var dynamic DateTime TimeSpan Guid',
    };

    // ------------------------------------------------------------------
    // Rule helpers
    // ------------------------------------------------------------------

    function esc(s) {
        return String(s)
            .replace(/&/g, '&amp;')
            .replace(/</g, '&lt;')
            .replace(/>/g, '&gt;');
    }

    // Wrap a pattern so it only matches at position 0 (strip a leading ^).
    function anchor(pattern) {
        var src = pattern.source;
        if (src.charAt(0) === '^') src = src.substring(1);
        return new RegExp('^(?:' + src + ')');
    }

    // Build a non-capturing alternation, longest words first so a shorter
    // keyword never shadows a longer one at the same position.
    function alternation(words) {
        var list = words.split(/\s+/).filter(function (w) { return w.length > 0; });
        list.sort(function (a, b) { return b.length - a.length; });
        return '(?:' + list.join('|') + ')';
    }

    var STRING_RE = /"(?:\\.|[^"\\\n])*"?|'(?:\\.|[^'\\\n])*'?/;
    var TEMPLATE_RE = /`(?:\\.|[^`\\])*`?/;
    var NUMBER_RE = /0[xX][0-9a-fA-F]+|0[bB][01]+|0[oO][0-7]+|\d+(?:\.\d+)?(?:[eE][+-]?\d+)?/;
    var OP_RE = /[{}()[\];.,<>+\-*/%&|^!~?=:@]+/;

    // Ordered rule lists. Each entry { cls, re } where re is anchored.
    function buildRules(lang) {
        var rules = [];
        var def = LANG_DEFS[lang];

        if (def && def.block) {
            rules.push({ cls: 'tok-com', re: anchor(new RegExp(def.block[0])) });
        }
        if (def && def.lineComment) {
            rules.push({ cls: 'tok-com', re: anchor(new RegExp(def.lineComment + '[^\\n]*')) });
        }
        if (def && def.template) rules.push({ cls: 'tok-str', re: anchor(TEMPLATE_RE) });
        rules.push({ cls: 'tok-str', re: anchor(STRING_RE) });
        rules.push({ cls: 'tok-num', re: anchor(NUMBER_RE) });
        if (def) {
            if (def.keywords) rules.push({ cls: 'tok-kw', re: anchor(new RegExp('\\b' + alternation(def.keywords) + '\\b')) });
            if (def.builtins) rules.push({ cls: 'tok-fn', re: anchor(new RegExp('\\b' + alternation(def.builtins) + '\\b')) });
            if (def.types) rules.push({ cls: 'tok-type', re: anchor(new RegExp('\\b' + alternation(def.types) + '\\b')) });
            if (def.fnCall) rules.push({ cls: 'tok-fn', re: anchor(/\b[A-Za-z_$][\w$]*(?=\s*\()/) });
        }
        rules.push({ cls: 'tok-op', re: anchor(OP_RE) });
        return rules;
    }

    function buildDataRules(kind) {
        if (kind === 'json') {
            return [
                { cls: 'tok-kw', re: anchor(/true|false|null/) },
                { cls: 'tok-num', re: anchor(NUMBER_RE) },
                { cls: 'tok-str', re: anchor(/"(?:\\.|[^"\\\n])*"?/) },
                { cls: 'tok-op', re: anchor(/[{}[\],:]/) },
            ];
        }
        if (kind === 'ini') {
            return [
                { cls: 'tok-com', re: anchor(/[#;][^\n]*/) },
                { cls: 'tok-prop', re: anchor(/[A-Za-z0-9_.-]+(?=\s*[=:])/) },
                { cls: 'tok-kw', re: anchor(/\b(?:true|false|null|yes|no|on|off)\b/) },
                { cls: 'tok-num', re: anchor(NUMBER_RE) },
                { cls: 'tok-str', re: anchor(STRING_RE) },
                { cls: 'tok-op', re: anchor(/[=:]/) },
            ];
        }
        if (kind === 'toml') {
            return [
                { cls: 'tok-com', re: anchor(/[ \t]*#[^\n]*/) },
                // [table] and [[array-of-tables]] section headers: only at the
                // start of a line, so inline arrays like `ports = [80, 8080]`
                // are not mistaken for headers.
                { cls: 'tok-tag', re: anchor(/[ \t]*\[\[[^\]\n]*\]\]|[ \t]*\[[^\]\n]*\]/), lineStart: true },
                // dotted/plain keys followed by '='
                { cls: 'tok-prop', re: anchor(/[A-Za-z0-9_".-]+(?=\s*=)/) },
                { cls: 'tok-kw', re: anchor(/\b(?:true|false)\b/) },
                { cls: 'tok-num', re: anchor(NUMBER_RE) },
                { cls: 'tok-str', re: anchor(/"""(?:\\[\s\S]|[^\\])*?"""|'''[\s\S]*?'''|"(?:\\.|[^"\\\n])*"|'(?:[^'\n]|'')*'/) },
                { cls: 'tok-op', re: anchor(/[=.,{}\[\]]/) },
            ];
        }
        if (kind === 'yaml') {
            return [
                { cls: 'tok-com', re: anchor(/[ \t]*#[^\n]*/) },
                { cls: 'tok-prop', re: anchor(/[ \t]*-?[A-Za-z0-9_.-]+(?=\s*:)/) },
                { cls: 'tok-kw', re: anchor(/\b(?:true|false|null|yes|no|on|off)\b/) },
                { cls: 'tok-num', re: anchor(NUMBER_RE) },
                { cls: 'tok-str', re: anchor(/"(?:\\.|[^"\\\n])*"?|'(?:[^'\n]|'')*'?/) },
                { cls: 'tok-op', re: anchor(/[?:,&|*[\]{}-]/) },
            ];
        }
        if (kind === 'markdown') {
            return [
                { cls: 'tok-com', re: anchor(/<!--[\s\S]*?-->/) },
                // fenced code block opener/closer (``` or ~~~, with optional lang)
                { cls: 'tok-tag', re: anchor(/[ \t]*(?:```+|~~~+)[^\n]*/) },
                // ATX headings
                { cls: 'tok-tag', re: anchor(/#{1,6}[^\n]*/) },
                // setext heading underline (=== or ---)
                { cls: 'tok-tag', re: anchor(/^[ \t]*={2,}[ \t]*$|^[ \t]*-{3,}[ \t]*$/) },
                // blockquote
                { cls: 'tok-com', re: anchor(/^[ \t]*&gt;[^\n]*|^[ \t]*>[^\n]*/) },
                // inline code span (single backtick, no newline)
                { cls: 'tok-str', re: anchor(/`[^`\n]*`/) },
                // bold / italic / strikethrough
                { cls: 'tok-kw', re: anchor(/\*\*[^*\n]+\*\*|__[^_\n]+__/) },
                { cls: 'tok-kw', re: anchor(/\*[^*\n]+\*|_[^_\n]+_/) },
                { cls: 'tok-com', re: anchor(/~~[^~\n]+~~/) },
                // links [text](url) and image ![alt](url)
                { cls: 'tok-prop', re: anchor(/!?\[[^\]]*\]\([^)\n]*\)/) },
                // horizontal rule
                { cls: 'tok-op', re: anchor(/^[ \t]*(?:-{3,}|\*{3,}|_{3,})[ \t]*$/) },
            ];
        }
        if (kind === 'csv') {
            return [
                // quoted fields (RFC 4180: "" escapes a quote)
                { cls: 'tok-str', re: anchor(/"(?:[^"]|"")*"?/) },
                { cls: 'tok-num', re: anchor(/\b\d+(?:\.\d+)?\b/) },
                { cls: 'tok-op', re: anchor(/,/) },
            ];
        }
        if (kind === 'html' || kind === 'xml') {
            return [
                { cls: 'tok-com', re: anchor(/<!--[\s\S]*?-->/) },
                { cls: 'tok-tag', re: anchor(/<\/?[A-Za-z][\w:-]*/) },
                { cls: 'tok-attr', re: anchor(/\b[A-Za-z_:][\w:.-]*(?=\s*=)/) },
                { cls: 'tok-str', re: anchor(/"[^"\n]*"|'[^'\n]*'/) },
                { cls: 'tok-op', re: anchor(/[<>/=]+/) },
            ];
        }
        if (kind === 'css') {
            // Order matters: comments first, then hex colours, at-rules,
            // property names (ident before ':'), numbers, strings, then a
            // narrow selector/tag matcher and finally operators. Putting the
            // property/hex rules before any broad identifier matcher is what
            // keeps values like `#3b82f6` or `margin: 0 auto` tokenising
            // correctly instead of being swallowed by a selector rule.
            return [
                { cls: 'tok-com', re: anchor(/\/\*[\s\S]*?\*\//) },
                { cls: 'tok-num', re: anchor(/#[0-9a-fA-F]{3,8}\b/) },
                { cls: 'tok-tag', re: anchor(/@[a-z-]+/) },
                { cls: 'tok-kw', re: anchor(/\b(?:inherit|initial|unset|auto|none|important|!important)\b/) },
                { cls: 'tok-prop', re: anchor(/[a-zA-Z-]+(?=\s*:)/) },
                { cls: 'tok-num', re: anchor(NUMBER_RE) },
                { cls: 'tok-str', re: anchor(STRING_RE) },
                // selectors: .class / #id / element / :pseudo — but only match
                // when NOT followed by ':' (that would be a property) and not
                // a hex colour.
                { cls: 'tok-tag', re: anchor(/[.#][a-zA-Z][\w-]*|[a-zA-Z][\w-]*(?![:\w-])|::?[a-zA-Z-]+/) },
                { cls: 'tok-fn', re: anchor(/[a-zA-Z-]+(?=\()/) },
                { cls: 'tok-op', re: anchor(/[{}();:,.>+~*=]/) },
            ];
        }
        if (kind === 'scss' || kind === 'less') {
            var lessLike = kind === 'less';
            // SCSS: variables use $name; at-rules use @name.
            // LESS:  variables use @name; at-rules/mixins also start with @.
            var varRule = lessLike
                ? /@@?[a-zA-Z_][\w-]*/
                : /\$[a-zA-Z_][\w-]*/;
            var atRule = /@[a-zA-Z-]+/;
            return [
                { cls: 'tok-com', re: anchor(/\/\*[\s\S]*?\*\/|(?:^|[^\\])\/\/[^\n]*/) },
                { cls: 'tok-num', re: anchor(/#[0-9a-fA-F]{3,8}\b/) },
                { cls: 'tok-kw', re: anchor(new RegExp('\\b' + alternation(KEYWORDS[kind]) + '\\b')) },
                // mixins/at-rules (media, mixin, include, extend, ...)
                { cls: 'tok-tag', re: anchor(atRule) },
                // variables ($x / @x)
                { cls: 'tok-prop', re: anchor(varRule) },
                // property names
                { cls: 'tok-prop', re: anchor(/[a-zA-Z-]+(?=\s*:)/) },
                { cls: 'tok-num', re: anchor(NUMBER_RE) },
                { cls: 'tok-str', re: anchor(STRING_RE) },
                // selectors: .class / #id / & parent / element
                { cls: 'tok-tag', re: anchor(/[.#&][a-zA-Z][\w-]*|[a-zA-Z][\w-]*(?![:\w-])/) },
                { cls: 'tok-fn', re: anchor(/[a-zA-Z-]+(?=\()/) },
                { cls: 'tok-op', re: anchor(/[{}();:,.>+~*=@$]/) },
            ];
        }
        return null;
    }

    var LANG_DEFS = {
        lua: { lineComment: '--', keywords: KEYWORDS.lua, builtins: BUILTINS.lua, fnCall: true },
        javascript: { lineComment: '//', block: ['/\\*', '\\*/'], keywords: KEYWORDS.javascript, builtins: BUILTINS.javascript, template: true, fnCall: true },
        typescript: { lineComment: '//', block: ['/\\*', '\\*/'], keywords: KEYWORDS.typescript, builtins: BUILTINS.javascript, types: TYPES.typescript, template: true, fnCall: true },
        python: { lineComment: '#', keywords: KEYWORDS.python, builtins: BUILTINS.python, fnCall: true },
        ruby: { lineComment: '#', keywords: KEYWORDS.ruby, fnCall: true },
        php: { lineComment: '//', block: ['/\\*', '\\*/'], keywords: KEYWORDS.php, builtins: 'echo print isset empty array function', fnCall: true },
        go: { lineComment: '//', block: ['/\\*', '\\*/'], keywords: KEYWORDS.go, builtins: 'make new len cap append copy panic recover println print printf', fnCall: true },
        rust: { lineComment: '//', block: ['/\\*', '\\*/'], keywords: KEYWORDS.rust, fnCall: true },
        c: { lineComment: '//', block: ['/\\*', '\\*/'], keywords: KEYWORDS.c, builtins: BUILTINS.c, types: TYPES.c, fnCall: true },
        cpp: { lineComment: '//', block: ['/\\*', '\\*/'], keywords: KEYWORDS.cpp, builtins: BUILTINS.cpp, types: TYPES.cpp, fnCall: true },
        csharp: { lineComment: '//', block: ['/\\*', '\\*/'], keywords: KEYWORDS.csharp, builtins: 'Console', types: TYPES.csharp, fnCall: true },
        java: { lineComment: '//', block: ['/\\*', '\\*/'], keywords: KEYWORDS.java, builtins: 'System', types: TYPES.java, fnCall: true },
        kotlin: { lineComment: '//', block: ['/\\*', '\\*/'], keywords: KEYWORDS.kotlin, fnCall: true },
        bash: { lineComment: '#', keywords: KEYWORDS.bash, builtins: BUILTINS.bash, fnCall: true },
        sql: { lineComment: '--', block: ['/\\*', '\\*/'], keywords: KEYWORDS.sql, fnCall: true },
        makefile: { lineComment: '#' },
        dockerfile: { lineComment: '#', builtins: 'FROM RUN CMD LABEL MAINTAINER EXPOSE ENV ADD COPY ENTRYPOINT VOLUME USER WORKDIR ARG ONBUILD STOPSIGNAL HEALTHCHECK SHELL' },
        cmake: { lineComment: '#', keywords: 'if endif else elseif endforeach endfunction function endfunction macro endmacro return set add_executable add_library target_link_libraries find_package project include message foreach while', fnCall: true },
    };

    var ruleCache = {};
    function rulesFor(lang) {
        if (!lang) return null;
        if (ruleCache[lang]) return ruleCache[lang];
        var rules = LANG_DEFS[lang] ? buildRules(lang) : buildDataRules(lang);
        ruleCache[lang] = rules;
        return rules;
    }

    // ------------------------------------------------------------------
    // Detection
    // ------------------------------------------------------------------

    // Backup suffixes that, when trailing a known extension, should be ignored
    // so the base file type is highlighted (e.g. "bookshelf.lua.old" -> lua).
    var BACKUP_SUFFIXES = { old: true, bak: true, orig: true, backup: true, copy: true, '~': true, save: true, new: true };

    function detectLanguage(filename) {
        if (!filename) return null;
        var lower = String(filename).toLowerCase();
        if (LANG_BY_FILENAME[lower]) return LANG_BY_FILENAME[lower];

        var parts = lower.split('.');
        if (parts.length >= 2) {
            // Try the deepest known extension first (e.g. "foo.bar.lua" -> lua)
            for (var i = parts.length - 1; i >= 1; i--) {
                var joined = parts.slice(i).join('.');
                if (LANG_BY_EXT[joined]) return LANG_BY_EXT[joined];
            }
            // No known extension at the end. If the trailing segment is a
            // backup suffix, drop it and re-resolve the remainder so a file
            // like "settings.lua.old" still highlights as Lua, and a file like
            // "Makefile.old" still highlights as Makefile.
            var last = parts[parts.length - 1];
            if (BACKUP_SUFFIXES[last] && parts.length >= 2) {
                var trimmed = parts.slice(0, -1).join('.');
                if (trimmed && trimmed !== lower) {
                    return detectLanguage(trimmed) || null;
                }
            }
            return LANG_BY_EXT[last] || null;
        }
        return null;
    }

    // ------------------------------------------------------------------
    // Tokenizer
    // ------------------------------------------------------------------

    function highlight(code, lang) {
        if (!code) return '';
        code = String(code);
        var rules = rulesFor(lang);
        if (!rules) return esc(code);

        var out = [];
        var i = 0;
        var n = code.length;
        var def = LANG_DEFS[lang];
        var blockOpen = def && def.block ? def.block[0] : null;
        var blockClose = def && def.block ? def.block[1] : null;
        var inBlock = false;

        // Regex rules are matched against a bounded window starting at the
        // current position rather than the whole remaining string. Scanning
        // the entire tail per token would make a long unbroken line O(n^2)
        // (each substring() copies the rest of the file). A window that is
        // much larger than any single token keeps the pass effectively
        // linear while remaining correct for multi-line block comments.
        var WINDOW = 65536;

        while (i < n) {
            var c = code.charAt(i);

            // Handle block comments spanning multiple lines.
            if (inBlock) {
                var closeIdx = code.indexOf(blockClose, i);
                if (closeIdx === -1) {
                    out.push('<span class="tok-com">' + esc(code.substring(i)) + '</span>');
                    break;
                }
                var blockText = code.substring(i, closeIdx + blockClose.length);
                out.push('<span class="tok-com">' + esc(blockText) + '</span>');
                i = closeIdx + blockClose.length;
                inBlock = false;
                continue;
            }

            // Try the rules in order; each is anchored so it must match here.
            var matchedAny = false;
            var windowEnd = i + WINDOW;
            if (windowEnd > n) windowEnd = n;
            var window = code.substring(i, windowEnd);

            for (var r = 0; r < rules.length; r++) {
                var rule = rules[r];
                // Rules flagged lineStart only apply at the beginning of a line
                // (i == 0, or the previous character is a newline). This lets
                // grammars like TOML/CSV/Markdown distinguish a line-scoped
                // construct (a [section] header, the CSV header row, a setext
                // underline) from an inline one (an array [a, b]).
                if (rule.lineStart) {
                    if (i !== 0 && code.charAt(i - 1) !== '\n') continue;
                }
                var m = rule.re.exec(window);
                if (m && m.index === 0 && m[0].length > 0) {
                    var matched = m[0];
                    var cls = rule.cls;
                    // Detect a block-comment opener (comment rules come first,
                    // so a single slash will normally be a comment opener
                    // only when followed by '*').
                    if (blockOpen && cls === 'tok-com' && code.charAt(i) === blockOpen.charAt(0) && blockOpen.length > 1 && code.substring(i, i + blockOpen.length) === blockOpen) {
                        var bClose = code.indexOf(blockClose, i + blockOpen.length);
                        if (bClose === -1 || bClose >= windowEnd) {
                            // Closer not found in window: switch to block state
                            // and let the next iteration consume it.
                            inBlock = true;
                            // Consume the opener itself so we don't loop forever.
                            out.push('<span class="tok-com">' + esc(blockOpen) + '</span>');
                            i += blockOpen.length;
                        } else {
                            var bText = code.substring(i, bClose + blockClose.length);
                            out.push('<span class="tok-com">' + esc(bText) + '</span>');
                            i = bClose + blockClose.length;
                        }
                        matchedAny = true;
                        break;
                    }
                    out.push('<span class="' + cls + '">' + esc(matched) + '</span>');
                    i += matched.length;
                    matchedAny = true;
                    break;
                }
            }

            if (matchedAny) continue;

            // Whitespace runs are emitted verbatim (fast path).
            if (c === ' ' || c === '\t' || c === '\n') {
                var j = i;
                while (j < n && (code.charAt(j) === ' ' || code.charAt(j) === '\t' || code.charAt(j) === '\n')) j++;
                out.push(code.substring(i, j));
                i = j;
                continue;
            }

            // Fallback: no rule matched at this position.
            // Emitting one escaped char at a time is quadratic on long
            // unbroken runs, so consume as much plain text as possible.
            //
            // Case A — we're at the start of an identifier (word char) and
            // no word-rule (keyword/builtin/type/fnCall) matched. Since all
            // word rules are anchored at word boundaries, the *whole word*
            // is plain text — consume it in one step.
            var isWordChar = (c >= 'a' && c <= 'z') || (c >= 'A' && c <= 'Z')
                || (c >= '0' && c <= '9') || c === '_' || c === '$';
            if (isWordChar) {
                var w = i + 1;
                while (w < n) {
                    var wc = code.charAt(w);
                    if (!((wc >= 'a' && wc <= 'z') || (wc >= 'A' && wc <= 'Z')
                        || (wc >= '0' && wc <= '9') || wc === '_' || wc === '$')) break;
                    w++;
                }
                out.push(esc(code.substring(i, w)));
                i = w;
                continue;
            }

            // Case B — a character that cannot start any token. Consume a
            // run of such characters in bulk. Letters/digits/quotes stop the
            // run so tokenization resumes correctly at the next candidate.
            var k = i + 1;
            while (k < n) {
                var kc = code.charAt(k);
                var isWord = (kc >= 'a' && kc <= 'z') || (kc >= 'A' && kc <= 'Z')
                    || (kc >= '0' && kc <= '9') || kc === '_' || kc === '$'
                    || kc === '"' || kc === "'" || kc === '`';
                if (isWord) break;
                k++;
            }
            out.push(esc(code.substring(i, k)));
            i = k;
        }
        return out.join('');
    }

    return {
        detectLanguage: detectLanguage,
        highlight: highlight,
    };
})();
