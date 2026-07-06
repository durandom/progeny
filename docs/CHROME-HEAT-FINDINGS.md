# Chrome / WindowServer Heat Findings

Date: 2026-07-02

## Problem

The Mac repeatedly gets hot with high `WindowServer` CPU/GPU activity while many
Chrome renderer processes are active. We want durable monitoring that can answer:

- Which Chrome renderer PID is hot?
- Which tab, extension, or Chrome task owns that PID?
- How does that correlate with `WindowServer`, GPU load, fans, and system heat?

## Current Live Findings

- Activity Monitor showed `WindowServer` around 75% CPU and around 41% GPU.
- `powermetrics --samplers gpu_power` confirmed real GPU load:
  - GPU active residency roughly 46-52%.
  - GPU power roughly 3.1-3.4 W.
- iStat Menus 7 `history.db` confirmed sustained GPU load:
  - Last 30 minutes: GPU processor average around 51-52%.
  - Recent 5-second samples were often 40-60%+.
- Display setup is not the obvious cause:
  - Only the built-in Liquid Retina XDR display was active.
  - No external display and no mirroring were present.
- `WindowServer` sampling showed actual compositor work:
  - `CGXUpdateDisplay`
  - `WS::Displays::SLCADisplay::render_update`
  - `CompositorMetal::CompositeLayersToDestination`
  - QuartzCore / AGXMetal rendering stacks
- Chrome renderer pressure was present at the same time:
  - Around 99-125 Chrome renderer processes depending on snapshot.
  - Aggregate Chrome renderer CPU around 50-60%.
  - Aggregate renderer RSS around 27-38 GiB.
  - Hot renderer examples:
    - Before Chrome restart: PID `46986`, around 20% CPU.
    - After Chrome restart/session restore: PID `75716`, around 39% CPU.

Interpretation: this is real browser/compositor heat. `WindowServer` is likely
paying the final composition cost for active Chrome surfaces: video, WebGL,
canvas, animated web apps, screen share/capture, or an extension.

## Paths Tried

### 1. `chrome.processes` Extension API

We created a minimal unpacked extension in:

`tools/chrome-process-telemetry-extension/`

Goal:

- Use `chrome.processes.getProcessInfo([], true)`.
- Obtain `osProcessId`, CPU, task title, tab ID, and URL.

Result:

- The extension loaded, but Chrome reported:

`chrome.processes is unavailable in this Chrome build/profile.`

Conclusion:

- This would be the ideal API if available.
- On this Chrome Stable/profile it is not exposed.
- Existing third-party extensions that solve this appear to rely on the same
  API, so they have the same limitation unless run in a Chrome channel/profile
  where `chrome.processes` is enabled.

### 2. Chrome DevTools Protocol / Remote Debugging

Goal:

- Restart Chrome with `--remote-debugging-port=9222`.
- Use CDP, especially `SystemInfo.getProcessInfo`.

Steps taken:

- Saved the current Chrome session with AppleScript to:

`/tmp/chrome-session-before-cdp-restart.json`

- Quit Chrome cleanly.
- Relaunched Chrome with:

`/Applications/Google Chrome.app/Contents/MacOS/Google Chrome --remote-debugging-port=9222 --restore-last-session`

Observed:

- Chrome process command line did include `--remote-debugging-port=9222`.
- No listener appeared on `127.0.0.1:9222`.
- `curl http://127.0.0.1:9222/json/version` failed.

Reason found:

- Since Chrome 136, Chrome ignores `--remote-debugging-port` and
  `--remote-debugging-pipe` when debugging the default Chrome data directory.
  These switches require a non-default `--user-data-dir`.

Conclusion:

- CDP is not available for the normal default Chrome profile via a simple
  restart.
- CDP remains viable for:
  - Chrome for Testing.
  - A deliberately separate `--user-data-dir`.
  - Possibly a real non-default Chrome profile if it has a distinct user data
    directory and Chrome accepts remote debugging there.

Important nuance:

- The user has at least two Chrome profiles: work and personal. We still need to
  determine whether they are separate profile directories inside the default
  Chrome user data directory, or truly separate user data directories. If they
  are just `Default`, `Profile 1`, etc. under the same default user data root,
  Chrome 136's remote debugging restriction probably still applies.

### 3. Chrome Task Manager

Goal:

- Use Chrome's built-in `Window > Task Manager` to map OS PID to task/tab.

Result:

- Chrome Task Manager opens.
- It is the most reliable built-in source for PID -> task/title mapping in the
  real daily Chrome profile.

Automation attempt:

- macOS Accessibility can see the `Task Manager` window.
- Accessibility did not expose the task table rows as usable AX rows/cells; it
  showed mostly nested empty groups.

Conclusion:

- Manual use works.
- Direct Accessibility scraping is not currently enough.
- OCR/screenshot extraction of the Task Manager table is a plausible next
  automation path.

### 4. macOS Process Inspection

Useful:

- `ps` can identify hot Chrome renderer PIDs and aggregate renderer CPU/RSS.
- Renderer command lines include renderer client IDs, process type, and parent
  Chrome PID.

Not enough:

- macOS process command lines do not include the tab title or URL.
- `powermetrics --show-process-gpu` did not give useful per-process GPU
  attribution on this machine; process GPU ms/s was effectively 0 while global
  GPU load was high.

### 5. iStat Menus 7 History DB

Useful:

- iStat `history.db` has a `gpu` table:
  - `time`
  - `interval`
  - `key`
  - `processor`
  - `memory`
- This gave reliable recent GPU processor and memory trends.

Open question:

- How much of iStat's process/task information is stored, if any? The current
  DB tables inspected were host-level tables such as `gpu`, `cpu`, `memory`,
  `sensors`, etc. No obvious browser task attribution was found yet.

### 6. Chrome Profile Layout (2026-07-02)

Question 1 is answered. `Local State` `profile.info_cache` shows:

- `Default` = "Marcel" (personal)
- `Profile 1` = "Work"

Both are profile directories under the single default user data root
(`~/Library/Application Support/Google/Chrome/`). There is no separate
`--user-data-dir`. Therefore the Chrome 136 restriction applies to both
profiles: CDP on the real daily session is definitively unavailable.

### 7. Renderer Sandbox Probes: lsof / sample / vmmap (2026-07-02)

Tested against a live hot renderer (PID 75419, `--renderer-client-id=37`):

- `lsof -i`: renderers hold zero network sockets. All networking goes
  through the separate network service process, so no domain attribution
  from renderer file descriptors.
- `sample <pid>`: Chrome Framework is fully stripped. Every frame resolves
  to anonymous `ChromeMain + offset`; no site-specific JS or media symbols
  ever appear.
- `lsof`/`vmmap` open files: only generic Chrome assets (tflite models,
  Subresource Filter rulesets, unlinked shared-memory temp files). No
  origin-named cache or storage paths; renderers receive content via Mojo
  IPC and shared memory, never via origin-bearing files.

Conclusion: question 5's heuristic (identify the tab from renderer-side
system inspection) is dead on all fronts. The sandbox fully isolates
renderer identity at the OS level.

### 8. Freeze-Probe: SIGSTOP + AppleScript JS Eval (new, most promising)

Deterministic PID -> tab mapping with minimal Chrome cooperation:

1. `kill -STOP <renderer-pid>`.
2. Probe every tab with AppleScript `execute tab ... javascript "1"`
   wrapped in `with timeout of 1 second`.
3. Tabs whose probe times out (Apple event error -1712) have their main
   frame on the frozen renderer. Fast errors (chrome:// pages, PDFs) are
   ignored.
4. `kill -CONT <renderer-pid>` (trap ensures resume on any exit).

Only Chrome requirement: the one-time toggle
`View > Developer > Allow JavaScript from Apple Events`. No restart, no
CDP, no extension, no separate user data dir.

Implemented in `.agents/skills/chrome-heat/scripts/renderer-to-tabs`.
Status: validated live (2026-07-02). First run produced 10 false
positives: Chrome Memory Saver freezes background tabs, which also time
out. Fixed with a two-pass design — baseline probe (nothing frozen)
records Chrome-frozen tabs, freeze probe runs after SIGSTOP, and only
tabs silent exclusively in pass 2 are reported. Validation run: renderer
56455 at ~16% CPU resolved to exactly one tab, an animated Windy.com
radar map.

Known limits:

- Main frames only; heat from out-of-process iframes (ads, embeds) will
  match no tab.
- One renderer can host several same-site tabs; all are listed.
- The hot tab is frozen for the probe duration (seconds).
- Security note: the toggle allows any process with Chrome automation
  permission to run JS in all tabs. Acceptable on a single-user machine,
  but it is a real widening of local attack surface.

### 9. Elimination Session Results (2026-07-02 evening)

Freeze-probe validated twice on live hot renderers:

- Renderer at 16% CPU -> single tab: Windy.com animated radar map.
- Renderer at 42% CPU + Chrome GPU process at 59% + GPU at 11 W ->
  **Foundry Virtual Tabletop** (narkat.home64.de, game + detached
  character sheet). Foundry renders its WebGL canvas continuously; this
  is the primary recurring browser heat source on this machine.

Systematic SIGSTOP elimination of every GUI frame producer (all 9
Chromium-family GPU processes, WezTerm, Telegram, Activity Monitor,
NotificationCenter, ControlCenter, Dock, iStat Menubar) moved GPU
utilization only a few points. Learnings:

- The JS-from-Apple-Events toggle is **per profile** (pref
  `browser.allow_javascript_apple_events` in each profile's
  Preferences). Enable it in every profile.
- Chrome Memory Saver tabs time out like frozen ones; the two-pass
  baseline diff in `renderer-to-tabs` is mandatory.
- A stuck macOS widget kept NotificationCenter at 36% CPU permanently;
  `killall NotificationCenter` cleared it to 0%.
- ioreg `Device Utilization %` is relative to the current GPU clock.
  Judge load by `powermetrics --samplers gpu_power` **watts** (idle
  <1 W, Foundry ~11 W), not by utilization percent alone.
- Per-process GPU attribution (`--show-process-gpu`) is broken on this
  machine (all zeros); elimination via SIGSTOP is the working method.
- macOS 26 Tahoe's compositor (Liquid Glass blur) is a documented
  systemic WindowServer cost, amplified by the Dell U4025QW 6K at
  120 Hz. Mitigations: Reduce Transparency, 60 Hz, fewer visible
  animating windows.

## Current Repo Artifacts

- `docs/TELEMETRY-TODO.md`
  - Updated with Chrome/WindowServer telemetry tasks and the Chrome 136 CDP
    constraint.
- `.agents/skills/chrome-heat/`
  - New repo-local skill for future Chrome/WindowServer heat investigations.
- `.agents/skills/chrome-heat/scripts/chrome-heat-snapshot`
  - Produces a local JSON-ish snapshot including:
    - Chrome window/tab count via AppleScript
    - CDP reachability
    - iStat GPU 30-minute stats
    - `WindowServer` CPU
    - aggregate Chrome renderer CPU/RSS
    - top Chrome renderer PIDs
- `tools/chrome-process-telemetry-extension/`
  - Minimal unpacked extension that would use `chrome.processes`, but the API is
    unavailable in the current Chrome build/profile.

## Questions For Further Research

1. Can Chrome remote debugging be enabled for one of the user's existing
   non-default Chrome profiles without losing access to the existing work or
   personal session?
   - Need to inspect Chrome profile layout:
     - `~/Library/Application Support/Google/Chrome/Local State`
     - `Default`
     - `Profile 1`
     - any separate app/user-data roots
   - Need to distinguish Chrome "profile directory" from Chrome
     `--user-data-dir`.

2. Is there any Chrome policy/enterprise setting that safely permits remote
   debugging for selected profiles on this machine?

3. Can a Chrome extension in this Chrome build access equivalent task/process
   data through another API, flag, enterprise policy, or native messaging helper?
   - Known blocked path: `chrome.processes`.

4. Can the Chrome Task Manager table be extracted reliably via:
   - OCR from screenshots.
   - Apple Vision / `textutil`-like local OCR.
   - ScreenCaptureKit frame plus OCR.
   - Chrome UI internals or localized accessibility not yet discovered.

5. Can we correlate hot renderer PID to a tab by sampling the renderer and
   identifying site-specific JS symbols, URLs, sourcemaps, media decoders, or
   network connections?
   - This is likely heuristic and weaker than Chrome Task Manager.

6. Should Progeny store a lightweight "Chrome heat label" stream:
   - process PID / parent PID / CPU / RSS from `ps`
   - Chrome Task Manager OCR label when available
   - iStat GPU processor/memory
   - `WindowServer` CPU
   - active screen capture clients

## Most Promising Next Approaches

(Revised 2026-07-02: profile layout answered — CDP on the real session is
dead; OCR rejected as too fragile; renderer-side system inspection
empirically dead, see sections 6-8.)

1. Enable `View > Developer > Allow JavaScript from Apple Events` and
   validate the freeze-probe (`renderer-to-tabs`) against a live hot
   renderer.
2. Wire the freeze-probe into the heat workflow: progeny identifies the
   hot renderer PID, `renderer-to-tabs` names the tab, on demand.
3. Consider a lightweight Chrome enrichment stream in Progeny
   (renderer client id, parent Chrome PID, aggregate renderer CPU/RSS)
   so hot-renderer history survives even without tab labels.

## References

- Chrome Developers Blog, "Changes to remote debugging switches to improve
  security", published 2025-03-17.
- Chrome DevTools Protocol `SystemInfo.getProcessInfo`.
- Chrome Extensions `chrome.processes` API documentation.
