# Telemetry TODO

This backlog tracks host telemetry gaps found while diagnosing fan noise, heat,
Spotlight indexing, WindowServer load, and browser renderer churn.

## Fan RPM Reliability

- [ ] Emit fan metadata alongside `fanRPMs`:
  - `fanSource`: `smc`, `istat`, `none`
  - `fanSensorAgeSec`: age of the source sample when known
  - `fanSampleStatus`: `ok`, `off_or_zero`, `smc_unavailable`, `istat_missing`,
    `istat_stale`, `istat_locked`, `no_candidate`
  - `fanCandidateCount`: number of plausible sensors seen before de-duplication
- [ ] Prefer iStat Menus as the primary fan source when it is installed and
  fresh on this workstation. Keep native SMC as fallback.
- [ ] Preserve explicit zero/off readings instead of collapsing every missing or
  unreadable source into an empty `fanRPMs` array. Empty should mean "no source
  produced a trustworthy value"; zero should mean "the source says the fan is
  stopped".
- [ ] Add short debug logging gated by an env var such as
  `PROGENY_SENSOR_DEBUG=1` so the next gap explains itself without sampling
  code changes.
- [ ] Check whether iStat's history database exposes stable sensor names/types,
  not only numeric `key` values. If names exist, use them to identify fan,
  temperature, power, and voltage sensors instead of heuristic value ranges.

## iStat-Derived Host Metrics

- [ ] Inventory iStat Menus 7 `history.db` tables and columns on this machine.
- [ ] Treat iStat as the preferred source for host telemetry that it already
  collects reliably on this workstation. Avoid duplicate reads through IOKit,
  `powermetrics`, or shell commands unless iStat lacks the metric, is stale, or
  cannot distinguish the needed source.
- [ ] Add a read-only iStat sensor reader with freshness checks and a strict
  per-sample timeout.
- [ ] Capture useful low-cardinality iStat metrics when fresh:
  - fan RPM per fan
  - CPU/GPU/SoC/package temperatures
  - CPU/GPU/ANE/package power if present
  - battery/power-adapter watts if iStat has cleaner values than IOKit
  - SSD temperature if present
- [ ] Emit source labels only where cardinality is bounded, e.g.
  `sensor=cpu_package`, not raw localized display names.

## Additional macOS Host Metrics

- [ ] Memory pressure:
  - `memory_pressure` state or equivalent VM pressure signal
  - swap used/free from `vm.swapusage`
  - pagein/pageout, compression/decompression deltas from `vm_stat`
- [ ] Power and throttling:
  - `powermetrics --samplers cpu_power,gpu_power,ane_power,thermal`
  - CPU/GPU/ANE watts
  - CPU frequency or residency if available
  - P-limit / thermal throttling indicators
- [ ] Wakeups and interrupts:
  - per-system wakeup rate
  - top processes by wakeups when available
  - interrupt rate by class when available
- [ ] Disk:
  - per-volume free/used bytes
  - per-device read/write bytes and operations
  - filesystem pressure indicators when available
- [ ] Network:
  - per-interface RX/TX byte deltas
  - active interface identification
  - optional per-process network attribution from `powermetrics`
- [ ] Battery/power:
  - charging state
  - adapter connected/type if available
  - battery cycle count and health fields if stable

## Heat Culprit Analysis

- [ ] Add a local helper query that summarizes the last N minutes by process
  group: CPU sum, max CPU, energy, disk read/write, max RSS, distinct PID count,
  parent command, and representative command.
- [ ] Add a "current heat" helper that combines:
  - host latest/window
  - process top CPU/energy
  - Spotlight aggregate
  - fan/thermal/power state
- [ ] Add Chrome-specific grouping:
  - group renderer/GPU/utility helpers under the parent Chrome PID
  - include renderer command details when available
  - map renderer PIDs to Chrome task titles via Chrome Task Manager for the
    real daily Chrome profile
  - do not rely on CDP for the default Chrome profile: Chrome 136+ ignores
    `--remote-debugging-port` unless paired with a non-default `--user-data-dir`
  - evaluate OCR/screenshot extraction of Chrome Task Manager rows, because
    macOS Accessibility exposes the Task Manager window but not the process
    table rows
  - keep CDP support only for Chrome for Testing or explicit non-default
    automation profiles
- [ ] Add WindowServer-specific notes:
  - correlate WindowServer CPU with Chrome GPU process, display count, active
    screen recording, remote desktop, video playback, and animated web content
  - record whether Computer Use, screen recording, Parsec, or other capture
    clients are active

## Control Ideas For WindowServer And Chrome

- [ ] Build a checklist for reducing WindowServer pressure:
  - pause/close screen recording and remote desktop clients
  - reduce animated browser tabs
  - check external display scaling/HDR/refresh settings
  - restart only the offending app first; avoid killing WindowServer unless
    prepared to log out
- [ ] Build a checklist for Chrome renderer pressure:
  - use Chrome Task Manager to identify the hot tab/extension
  - suspend or close hot renderers
  - inspect GPU process load separately from renderer CPU
  - keep per-tab attribution separate from aggregate Chrome process load
