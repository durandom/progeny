# progeny data model in OpenObserve

Produced by `progenyd` → OTLP → an OTel collector → OpenObserve.
Query with `progeny-oo <metrics|logs> "<SQL>" [--hours N]`. From the repo root,
the helper scripts live in `.agents/skills/progeny-analyze/bin/`.

## Metrics (`progeny-oo metrics …`) — complete, all processes aggregated

Each metric is its own stream. Columns: `value` (double), `_timestamp` (µs),
plus the dimension column(s) below, `__name__`, `service_name`.

| Stream | Dimension col | Meaning |
|---|---|---|
| `progeny_system_cpu_percent` | — | Σ per-process CPU% (can exceed 100 = multi-core) |
| `progeny_system_energy_nanojoules` | — | Σ per-interval energy (nJ) of the top-N procs |
| `progeny_system_process_count` | — | total process count |
| `progeny_system_orphan_count` | — | total # reparented to launchd (ppid=1); mostly legit macOS |
| `progeny_system_orphan_max_comm_count` | — | **largest same-comm ppid=1 cluster** — the swarm trend/alert scalar |
| `progeny_host_cpu_percent` | `state` = user/system/idle | host CPU |
| `progeny_host_memory_bytes` | `state` = wired/active/compressed/free | host memory |
| `progeny_host_load` | `window` = 1m/5m/15m | load average |
| `progeny_host_thermal_level` | — | 0 nominal · 1 fair · 2 serious · 3 critical |
| `progeny_host_external_power_connected` | — | 1 when external power is connected, 0 when on battery |
| `progeny_host_battery_percent` | — | battery charge percent when available |
| `progeny_host_battery_power_watts` | — | battery watts when available; negative = discharging |
| `progeny_host_fan_rpm` | `fan` = 0..N | fan RPM when a sensor source is available |
| `progeny_host_cpu_power_watts`, `progeny_host_gpu_power_watts` | — | CPU/GPU watts when a privileged/IOReport source is available |
| `progeny_spotlight_active` | — | 1 when Spotlight process activity is currently meaningful |
| `progeny_spotlight_process_count` | `kind` = total/worker/active_worker | active Spotlight process counts |
| `progeny_spotlight_cpu_percent` | `kind` = total/mds/mds_stores/worker | Spotlight CPU split |
| `progeny_spotlight_energy_nanojoules` | — | Spotlight per-interval energy |
| `progeny_spotlight_disk_bytes` | `direction` = read/write | Spotlight per-interval disk IO |
| `progeny_spotlight_mds_stores_rss_bytes` | — | `mds_stores` resident/footprint bytes |

## In-RAM ring (`progeny-local …`) — full fidelity, recent window, no SSD

Served by the daemon on `127.0.0.1:9847` (`PROGENY_QUERY_PORT`) over the last
`PROGENY_MEM_WINDOW_MIN` minutes (default 240 = 4h). Holds **every process** each
tick — no top-N limit — so it answers depth/churn questions OpenObserve can't.

| Route | Returns |
|---|---|
| `progeny-local stats` | `{ticks, capacity, window}` — how much history is buffered |
| `progeny-local latest` | every process in the newest snapshot (NDJSON) |
| `progeny-local pid <pid>` | that PID across every tick — its cpu/energy/rss trajectory |
| `progeny-local comm <name>` | every row for a command over the window — **swarm churn** |
| `progeny-local window <minutes>` | every process row in the last N minutes |
| `progeny-local host latest` | newest host metrics |
| `progeny-local host window <minutes>` | host metrics over the last N minutes |
| `progeny-local spotlight latest` | newest Spotlight aggregate |
| `progeny-local spotlight window <minutes>` | Spotlight aggregate over the last N minutes |

Each line is a full `ProcSample` (all fields below) plus `ts`. Numeric fields are
**real JSON numbers here** (unlike the OO logs, which stringify them) — no CAST.
`command`/`path` present only for the tick's top-N-by-energy; core fields
(pid/ppid/comm/ancestry/cpu/energy/rss/…) present for all.
`first_*` fields preserve the first parent seen for a PID/start-time pair, so a
process that later reparents to launchd can still point back to the launcher if
progenyd observed it before orphaning.

Churn read: group `progeny-local comm <name>` by `ts`; a **stable PID set** each tick =
leaked/parked pool, a **growing distinct-PID count** = respawn storm.

## Logs (`progeny-oo logs …`) — per-PID, top-N-by-energy only

The logs stream name depends on your collector's routing (discover it with
`progeny-oo streams`); always filter `WHERE service_name = 'progenyd'` to isolate
progeny's rows from anything else in that stream. `body = 'proc'`. Examples below
use `<logs_stream>` as a placeholder.

⚠️ **Every numeric field is stored as a STRING** — `CAST(x AS DOUBLE)` (or
`BIGINT`) for any math, comparison, or ordering.

| Column | Type (stored) | Meaning |
|---|---|---|
| `pid`, `ppid` | string int | process / parent id |
| `comm` | string | short name (truncated ~16/32 char) |
| `command` | string | **full argv** — the forensic detail `comm` loses |
| `path` | string | full executable path |
| `ancestry` | string | `1/572/933` = launchd→…→parent pid chain |
| `orphaned` | string bool | `ppid == 1` |
| `first_seen_sec` | string int | unix seconds when progenyd first saw this PID/start-time pair |
| `first_ppid` | string int | parent PID at first sighting |
| `first_ancestry` | string | parent chain at first sighting |
| `first_parent_comm`, `first_parent_path`, `first_parent_command` | string | first-seen parent identity, when readable |
| `original_parent_alive` | string bool | whether the first-seen parent PID is alive in the current snapshot |
| `cpu_percent` | string double | over the sample interval |
| `energy_nj` | string int | per-interval energy (nJ) — sum over window for total |
| `rss_bytes`, `wakeups`, `cycles`, `instructions`, `disk_read`, `disk_write` | string int | rusage counters (per-interval deltas) |
| `_timestamp` | µs | row time |

### Orphan-swarm records (a second log `body` in the same stream)

Rows with `body = 'orphan_swarm'` (severity warning) — emitted only when a
same-comm ppid=1 cluster reaches `PROGENY_SWARM_THRESHOLD` (default 10). Computed
over ALL processes, so idle swarms are covered despite the top-N logs.

| Column | Meaning |
|---|---|
| `comm` | the clustered command name |
| `count` | # of ppid=1 instances (string int) |
| `sample_pids` | comma-joined PIDs to inspect/kill |
| `sample_start_times` | comma-joined process start times for sample PIDs |
| `sample_commands` | joined command lines for sample PIDs when enriched |
| `original_parent_pids`, `original_parent_commands` | first-seen launcher details when progenyd saw the process before orphaning |
| `original_parents_alive` | # swarm members whose first-seen parent is still alive |
| `example_ancestry` | one member's launchd→parent chain |
| `example_first_ancestry` | one member's first-seen chain |
| `total_rss_bytes`, `sum_energy_nj` | cluster totals (string int) |

## Gotchas

- **Coverage:** per-PID logs carry only the **top-N by energy** per tick (default
  20); WAL is off. High-energy runaways and orphan swarms are both covered (the
  latter via `orphan_max_comm_count` + `body='orphan_swarm'`). Only a *lone
  low-energy non-swarm* process is absent — raise `PROGENY_TOP_N` / set
  `PROGENY_WAL=1` if that ever matters.
- **Time is microseconds** in SQL; `progeny-oo --hours N` sets the window (default 1h).
- **Stream names are double-quoted** in SQL (`FROM "progeny_host_load"`).
- **energy_nj / rss / cycles are per-interval deltas**, not cumulative — SUM for
  a window total, AVG/MAX for a rate.
- **Fan RPM / package temperatures / CPU/GPU watts are best-effort.** macOS does
  not expose them through the same unprivileged APIs as `ri_energy_nj`; absent
  values mean "not available", not zero. Fan RPM may come from native SMC keys or,
  on machines where iStat Menus exposes the only practical source, from fresh
  iStat Menus 7 sensor-history values.
- A single `_search` hits **one stream/type**; host-pressure = several queries.
- **Metric aggregates need a `GROUP BY`** — OO injects `_timestamp` into the
  projection, so a bare `SELECT MAX(value)` fails. For one scalar over a stream
  use `GROUP BY __name__` (constant per stream); otherwise group by a dimension
  (`state`/`window`).
