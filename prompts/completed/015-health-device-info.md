<objective>
Add a read-only `device` block to FileSync's `GET /api/health` response that describes the screen KOReader is running on: model, native screen size, colour capability and KOReader version.

Why: Inkbrary, an iOS companion app that talks to FileSync, is adding **Sleep Screens**, which sends images to a reader to use as its sleep screen. To crop and convert an image correctly, the app needs the reader's real screen size and to know whether it shows colour. Today it has to ask the user, through a Kobo-only model picker. But KOReader runs on Kobo, Kindle, PocketBook, Boox/Android, reMarkable, Cervantes and more, and KOReader itself already knows all of this. Exposing it from `/api/health` lets the app work it out automatically on every device KOReader supports.

The change must be **purely additive**: any existing client of `/api/health` keeps working unchanged.
</objective>

<context>
- **Project:** a KOReader plugin in Lua. There is no `CLAUDE.md` in this repo. Follow the surrounding code's style, and the conventions visible in `./prompts/completed/`.
- **The endpoint:** `./filesync/httpserver.lua`, around line 302:

  ```lua
  if method == "GET" and path == "/api/health" then
      self:_sendJSON(client, 200, { status = "ok", root_dir = self.root_dir, fileops_loaded = FileOps ~= nil })
  ```

  The API list comment near line 246 documents it as `returns {status, root_dir, fileops_loaded}`.
- **The Device module:** `./filesync/filesyncmanager.lua` already uses `require("device")`, `Device.screen` and the `Device:isKindle()` / `isKobo()` / `isPocketBook()` / `isAndroid()` checks. `httpserver.lua` doesn't require `device` yet. Decide whether the server should require it, or whether the manager should pass a device-info table or provider in when it creates the server; the second option is easier to test. Explain the choice.
- **Tests:** busted, in `./spec/` (`httpserver_spec.lua` stubs KOReader modules through `package.loaded`), configured in `./.busted`.
- **Safe mode:** FileSync has a safe mode that refuses some paths and writes. The health endpoint answers in every mode, and so must the new block. It contains no secrets.

**The contract:** Inkbrary is being built against this exact shape at the same time (Inkbrary prompt 117), so use these names and types:

```json
{
  "status": "ok",
  "root_dir": "/mnt/onboard",
  "fileops_loaded": true,
  "device": {
    "model": "Kobo_monza",
    "platform": "kobo",
    "screen": { "width": 1264, "height": 1680, "dpi": 300 },
    "color_screen": true,
    "color_enabled": true,
    "koreader_version": "v2025.08"
  }
}
```

- `model`: `Device.model`, as KOReader reports it.
- `platform`: one of `kobo`, `kindle`, `pocketbook`, `android`, `remarkable`, `cervantes`, `sdl`, `other`, from KOReader's device checks. Find the right checks in KOReader's `frontend/device/` sources.
- `screen.width` / `screen.height`: the panel's **native size in portrait orientation**, so width ≤ height, **whatever the current rotation.** Use the framebuffer's native or raw size, not the current rotated `getWidth()`/`getHeight()`, or swap the values so the smaller one is the width. `dpi` is `Screen:getDPI()`.
- `color_screen`: `Device:hasColorScreen()`, the hardware capability.
- `color_enabled`: whether KOReader is currently rendering in colour (its colour-rendering setting, for example `Screen:isColorEnabled()` or the equivalent in the KOReader version this plugin targets). `false` on black-and-white devices.
- `koreader_version`: KOReader's version string, for example from `require("version")`.

Look up each API in KOReader's source, at the minimum version this plugin supports, and use guarded calls (`pcall` or existence checks). On an older KOReader without an API, **leave out only that field.** Never fail the health response, and never send the `device` block half-built in a way that breaks JSON. Write down in the code which KOReader APIs each field uses.
</context>

<requirements>
1. **Build the `device` table:**
   - Keep it cheap, since health is called on every handshake; computing it once per server start is fine if the values can't change. `color_enabled` *can* change, so read that one fresh each time.
   - It must never error.
   - Include no identifiers that point to a person or a particular device: no serial numbers, no MAC addresses, no Wi-Fi names.
2. **Add `device` to the `/api/health` response,** and update the API list comment at the top of `httpserver.lua` to document the new block.
3. **Tests (busted):**
   - With a stubbed device (Kobo colour, Kindle black-and-white, a landscape-rotated screen, an older KOReader missing the colour APIs), assert the exact JSON block, including width ≤ height.
   - Assert the existing three fields are unchanged.
   - Assert a throwing device API doesn't break the response.
4. **Docs:** if the README or `./docs/` describe the HTTP API, document the new block in English. Leave the translated READMEs alone unless they already document `/api/health` field by field; in that case, add the block to each so they stay in sync. Note in the summary which files you changed.
5. Don't bump the version in `_meta.lua` or touch the release workflow. Releasing is the user's decision.
</requirements>

<constraints>
- **Create a branch `feat/health-device-info` from `master`** and work there. **Do not commit or push.** The user reviews and tests on their Kobo Libra Colour first.
- No changes to any other endpoint, to safe-mode rules, or to the web UI.
- Never install or run anything on the user's devices. Verifying on hardware is the user's job; write the curl check they can run.
</constraints>

<verification>
- Run the busted suite (follow `./.busted`). Everything passes, including the new tests.
- Lint-check the Lua the way the repo does, if it has a linter config. Otherwise make sure every new file and function parses (`luac -p` or equivalent).
- Read the final `/api/health` handler and the device-info builder once more, specifically for error paths.
- `git status` shows only your changes, on `feat/health-device-info`, with nothing committed.
</verification>

<success_criteria>
- `/api/health` returns the `device` block exactly as in the contract, on every platform. Missing APIs drop only their own field, and old clients see no change.
- Tests cover colour and black-and-white devices, rotation, older KOReader versions, and failing APIs.
- The summary includes:
  - the KOReader APIs used for each field, and the minimum KOReader version each needs;
  - the exact curl command for the user to run against their Kobo, with the expected output for a Libra Colour (`curl -s http://<kobo-ip>:<port>/api/health`);
  - anything that couldn't be verified without hardware.
</success_criteria>
