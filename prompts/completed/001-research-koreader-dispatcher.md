<objective>
Research how KOReader's Dispatcher system works so we can add FileSync server toggle as a dispatcher action (issue #15).

The goal is to understand the exact API contract a plugin must follow to register an action with KOReader's Dispatcher, which enables users to trigger plugin actions from Quick Settings or custom gestures.
</objective>

<context>
This is a KOReader plugin called FileSync located at `./`. It currently has NO dispatcher integration — the server can only be started via Settings → Network → FileSync → Start file server.

We need to understand the dispatcher pattern before implementing it.
</context>

<research>
Thoroughly explore how KOReader plugins integrate with the Dispatcher system. Use the following approach:

1. **Find the Dispatcher source code** in the KOReader codebase. It is likely located in the KOReader installation or framework directory. Search for files named `dispatcher.lua` or containing `Dispatcher` class definitions. Common KOReader paths:
   - Check if KOReader source is available locally (e.g., `/usr/lib/koreader/`, or search for koreader in common locations)
   - If not available locally, use WebFetch to examine the KOReader GitHub repository:
     - `https://raw.githubusercontent.com/koreader/koreader/master/frontend/dispatcher.lua`
     - `https://raw.githubusercontent.com/koreader/koreader/master/plugins/` (look for dispatcher usage patterns)

2. **Study existing plugin dispatcher integrations** — look at these KOReader plugins that are known to register dispatcher actions:
   - AutoSuspend plugin (likely registers suspend/standby actions)
   - AutoTurn plugin (likely registers page turn actions)
   - Statistics plugin
   - Search the KOReader repo for `onDispatcherRegisterActions` — this is likely the event handler plugins implement

3. **Document the integration pattern**, specifically:
   - What event or method must a plugin implement to register dispatcher actions?
   - What is the data structure for registering an action (name, category, title, etc.)?
   - How does a registered action map to a callback function?
   - What categories are available (e.g., "network", "device", etc.)?
   - Are there any requirements for the action to appear in Quick Settings vs gesture settings?

4. **Find a minimal, representative example** of a plugin that registers a simple toggle action (start/stop something), as this is closest to our use case (toggle FileSync server on/off).
</research>

<output>
Save your findings to `./prompts/001-research-results.md` with the following structure:

```markdown
# KOReader Dispatcher Integration Research

## How Dispatcher Registration Works
[Explain the mechanism — event name, method signature, etc.]

## Action Data Structure
[Show the exact Lua table structure for registering an action]

## Minimal Example
[Show a complete, minimal code snippet from an existing plugin]

## Recommended Approach for FileSync
[Specific recommendation for how FileSync should register its toggle action]

## Key Files / References
[List the exact file paths or URLs examined]
```
</output>

<verification>
Before completing, verify:
- You have found the actual dispatcher registration API (not guessed it)
- You have at least one concrete code example from an existing plugin
- The recommended approach accounts for FileSync's toggle behavior (start if stopped, stop if running)
</verification>
