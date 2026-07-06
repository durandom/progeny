---
name: chrome-heat
description: Correlate Chrome renderer, Chrome GPU process, WindowServer, and macOS GPU heat on this Mac. Use when the user asks why Chrome, WindowServer, GPU, fans, heat, or a Chrome Helper renderer is high; when mapping hot Chrome PIDs to tabs/extensions; when deciding whether Chrome DevTools Protocol, Chrome Task Manager, iStat, powermetrics, or progeny telemetry is the right source; or when investigating sustained browser/compositor load.
---

# chrome-heat

Investigate browser/compositor heat by combining local process telemetry, iStat
GPU history, Progeny history, and Chrome's own task labels.

## Core workflow

1. Run `scripts/chrome-heat-snapshot` from this skill. Report the top Chrome
   renderers, Chrome GPU process, `WindowServer`, iStat GPU recent average, and
   whether CDP is reachable.
2. Query Progeny when trend or history matters:
   - `.agents/skills/progeny-analyze/bin/progeny-local window <minutes>`
   - `.agents/skills/progeny-analyze/bin/progeny-local host window <minutes>`
3. If a Chrome renderer PID is hot, map PID to tab:
   - Preferred: `scripts/renderer-to-tabs <pid>` — freezes the renderer with
     SIGSTOP and probes every tab via AppleScript JS eval; tabs silent only
     during the freeze are the match. Requires the per-profile Chrome toggle
     `View > Developer > Allow JavaScript from Apple Events` (check
     `browser.allow_javascript_apple_events` in each profile's Preferences —
     enable it in every profile, not just one).
   - Renderers with `--extension-process` in their command line host an
     extension, not a tab; the probe reports no match for them.
   - Fallback: Chrome menu `Window > Task Manager`, show/sort `Process ID`.
   - CDP is only valid when `scripts/chrome-heat-snapshot` says it is reachable.
   - Judge GPU load in watts via `sudo powermetrics --samplers gpu_power`;
     ioreg/iStat utilization percent is relative to the current GPU clock and
     overstates light load.
4. Interpret `WindowServer` as compositor load. If `WindowServer` and Chrome
   renderer/GPU are both hot and the `WindowServer` sample shows
   `CompositorMetal`/QuartzCore, the likely cause is a browser surface producing
   frames: video, WebGL/canvas, animated web app, screen share/capture, or an
   extension.

## Chrome remote debugging constraint

Do not assume the user's normal Chrome profile can expose CDP. Since Chrome 136,
`--remote-debugging-port` and `--remote-debugging-pipe` are ignored for the
default Chrome data directory. They require `--user-data-dir` pointing to a
non-standard directory. That protects the real profile but also means CDP cannot
observe the user's existing tabs in the default profile.

Use CDP only for:

- Chrome for Testing / automation profiles.
- A deliberately separate Chrome profile started with both
  `--remote-debugging-port=<port>` and `--user-data-dir=<non-default-dir>`.

For the real profile with logged-in tabs, use Chrome Task Manager as the label
source. See `references/chrome-remote-debugging.md`.

## Safety

- Do not kill Chrome renderers automatically. Ask before ending a tab/process.
- Before any Chrome restart, save a session snapshot with AppleScript or the
  user's native Chrome session restore must be accepted as sufficient.
- Do not print private URLs in final answers unless the user explicitly asks.
