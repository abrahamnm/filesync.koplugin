<objective>
Change the FileSync plugin's default HTTP port from 8080 to 80, so that a fresh
install serves at `http://<device-ip>/` and users can type just the IP address
into a browser with no `:port` suffix.

This is an add-on to the current branch `feat/allow-low-ports`, which already
allows ports below 1024 with an automatic fallback when the privileged bind
fails. This change makes 80 the out-of-the-box experience on devices that run
KOReader as root (Kobo/Kindle), while keeping non-root devices (Android,
desktop) working exactly as before via the fallback.

Typing an IP is the single most fiddly step of the setup flow on an e-ink
device, so removing four characters from it is the whole point of the change —
keep that outcome in view when deciding what to display to the user.
</objective>

<context>
- Project: KOReader plugin written in Lua. Read `./CLAUDE.md` for project
  conventions before editing.
- Work happens on the existing branch `feat/allow-low-ports`. Do NOT create a
  new branch and do NOT open a new PR — commit onto this branch so the change
  lands in the open PR.
- Key files:
  - `./filesync/filesyncmanager.lua` — `DEFAULT_PORT`, `getPort`, `setPort`,
    `configurePort`, server start with privileged-port fallback, URL/QR display.
  - `./filesync/httpserver.lua` — `HttpServer.port` table default.
  - `./README.md` plus the translated `README.*.md` files — document the default
    port.
  - `./filesync/static/index.html` — mentions 8080.
</context>

<requirements>
1. Introduce two distinct constants in `filesyncmanager.lua`:
   - `DEFAULT_PORT = 80` — the port a fresh install uses.
   - `FALLBACK_PORT = 8080` — the port used when binding a privileged port
     fails.
   The fallback path must NOT reuse `DEFAULT_PORT` any more; retrying 80 after
   80 already failed would be a guaranteed second failure.

2. Update the privileged-port fallback in the server start path to try
   `FALLBACK_PORT` and to report `FALLBACK_PORT` in its user-facing message.

3. Update `configurePort`:
   - The `input_hint` should show the new default (`80`).
   - The sub-1024 warning message must reference `FALLBACK_PORT`, not
     `DEFAULT_PORT`.
   - The accepted range stays 1–65535.

4. Update `HttpServer.port` in `httpserver.lua` to 80 so the module default
   matches. It is always overridden by the manager, but leaving it at 8080 is a
   stale-value trap for the next reader.

5. Omit the port from displayed URLs when it is 80. `filesyncmanager.lua:425`
   builds `"http://" .. self._ip .. ":" .. self._port`; when the effective port
   is 80 the URL must render as `http://<ip>` with no colon or port. Apply this
   everywhere a URL is shown to the user, including the QR code payload — a QR
   that encodes `http://192.168.1.5:80` still works, but the on-screen text
   users read and retype is the reason this change exists.

6. Do NOT migrate existing users. Anyone who has already run the plugin has
   `filesync_port` saved in `G_reader_settings` and must keep their current
   port; only installs with no saved setting pick up 80. Silently moving a
   working setup to a port that may not bind is worse than a slightly longer
   URL.

7. Update documentation to state the new default:
   - `./README.md` (e.g. line 166 "default: 8080") and every translated
     `README.*.md` that carries the same sentence — ar, de, es, fr, ja, ko,
     pt_BR, ru, zh_CN. Translate the added wording into each README's language;
     do not leave English text in a translated file.
   - `./filesync/static/index.html` where 8080 appears.
   - Where the docs mention the default, note briefly that devices which cannot
     bind port 80 (Android, desktop) automatically fall back to 8080, so users
     are not confused when their URL needs `:8080`.
</requirements>

<implementation>
- Match the surrounding Lua style: existing comment density, `T(_(...))` for
  user-facing strings, `logger.warn`/`logger.err` for diagnostics.
- Any new or changed user-facing string must go through `_()` so it stays
  translatable.
- Keep the change minimal and surgical. Do not refactor the port-handling code
  beyond what these requirements need — the PR is already in review and
  unrelated churn makes it harder to land.
- Do not commit generated analysis or review documents to the repo.
</implementation>

<verification>
Before declaring complete:
1. `grep -rn "8080" filesync/ README*.md` and confirm every remaining hit is
   intentional (the `FALLBACK_PORT` constant and the fallback docs) — no stale
   "default: 8080" text survives.
2. Re-read the server start path and confirm the failure sequence is
   80 → fails → 8080, with no path that retries 80.
3. Confirm `getPort()` returns a previously saved port unchanged and only
   returns 80 when `filesync_port` is absent.
4. Trace the URL/QR display code for both cases: port 80 renders `http://<ip>`;
   port 8080 renders `http://<ip>:8080`.
5. Run any lint/check command the project defines in `./CLAUDE.md`.
</verification>

<output>
Modify in place:
- `./filesync/filesyncmanager.lua`
- `./filesync/httpserver.lua`
- `./filesync/static/index.html`
- `./README.md` and the translated `README.*.md` files

Then commit onto the existing `feat/allow-low-ports` branch with a message in
the repo's existing style (e.g. `feat: use port 80 by default`) and push, so the
open PR picks up the change. Update the PR description to mention the new
default and the 8080 fallback.
</output>

<success_criteria>
- A fresh install binds port 80 on Kobo/Kindle and shows `http://<ip>` with no
  port suffix.
- A device that cannot bind 80 falls back to 8080, tells the user so, and shows
  `http://<ip>:8080`.
- Users with a saved port keep it.
- All docs, in every language, state the new default and the fallback.
- The change is committed and pushed to `feat/allow-low-ports`; no new branch or
  PR is created.
</success_criteria>
