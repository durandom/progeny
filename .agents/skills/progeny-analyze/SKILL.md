---
name: progeny-analyze
description: >-
  AI-driven macOS system analysis over progenyd telemetry in OpenObserve — no
  dashboards. Use when the user asks what is using CPU / energy / memory, why
  the Mac is slow or hot or loud, what process ran away (overnight or while
  away), who spawned a runaway (parent/ancestry), whether there is an orphaned
  process swarm (and whether it is leaking or respawning), how a process's
  CPU/energy changed over time, or for load/thermal/memory pressure. Queries
  progeny_* metric streams + forensic logs in OpenObserve (progeny-oo) and the
  daemon's in-RAM full-history buffer (progeny-local), then interprets in prose.
license: MIT
metadata:
  author: progeny
  version: "0.1"
---

# progeny-analyze

Answer "what is my Mac doing / what went wrong" by **querying telemetry, not
reading dashboards**. Data is produced by the `progenyd` daemon (this repo): the
in-RAM buffer is read locally via `progeny-local`; if you also ship OTLP to
OpenObserve, long-term data is read via `progeny-oo`. These helper scripts live
in `.agents/skills/progeny-analyze/bin/` and should be run from the repo root
unless they are on `PATH`. Query, then explain.

The founding use case: *which exact process ran away, and who spawned it* —
historical, per-PID forensics that live TUIs can't answer.

## Preflight (once per session)

```bash
.agents/skills/progeny-analyze/bin/progeny-oo env                      # resolves OpenObserve URL + creds
.agents/skills/progeny-analyze/bin/progeny-oo streams                  # confirms progeny_* metrics + <logs_stream>
.agents/skills/progeny-analyze/bin/progeny-local stats                 # in-RAM buffer: tick count + time window
launchctl print gui/$(id -u)/local.progenyd | grep -E 'state =|pid ='   # daemon alive?
```
`progeny-oo` reads OpenObserve creds from `~/.config/progeny/openobserve.env` (override
`PROGENY_OO_ENV`); if OTLP isn't configured, skip it and use `progeny-local` alone. If
`progeny-local` can't connect, the daemon isn't running or `PROGENY_QUERY=0`. If the
daemon isn't running, there's no fresh data — say so.

## Three data surfaces

| Question type | Surface | How |
|---|---|---|
| Trends / pressure / long-term / cross-machine | **metrics** (`progeny_system_*`, `progeny_host_*`) in OpenObserve — complete aggregates | `progeny-oo metrics …` |
| "Which process / who spawned it / what command", swarms | **logs** — per-PID top-N + swarm records. ⚠️ **Not available today**, see below | `progeny-oo logs …` |
| **Deep forensics NOW** — full per-PID history, every process, **churn/trajectory** | **in-RAM ring** (localhost, ~4h, no SSD) | `progeny-local …` |

⚠️ **The OTLP logs surface has never worked.** As of 2026-08-26 OpenObserve holds
only three logs streams — `host_auth_raw`, `host_fault_raw`, `host_kernel_raw` —
all from Linux hosts. There has never been a progenyd logs stream, not even
during 2026-08-20..24 when progeny *metrics* were landing normally. progenyd is
not at fault: pointed at a local OTLP catcher it posts `/v1/logs` (161 KB per
24 s) alongside `/v1/metrics` (12 KB), so the emitter, protocol and batching are
correct. The collector accepts the logs signal and does not route it into
OpenObserve. Tracked as orrery bead `orr-xmb`.

Until that is fixed, **every per-PID question must be answered from `progeny-local`**
(the in-RAM ring), not from `progeny-oo logs`. The `queries/*.sql` files that
select from a logs stream are unexercised against the real sink.

Rule of thumb: **`progeny-oo` for "over days / is it normal", `progeny-local` for "what exactly
is happening in the last hours, every PID, changing how"**. `progeny-local` has no top-N
limit — it holds *all* processes for the window, so it answers the depth questions
OpenObserve can't. See `references/data-model.md`.

## Coverage — what's captured

The per-PID **logs carry the top-N by energy** each tick (default N=20); WAL is
off. What each failure mode maps to:

- **High-energy runaway** (hung process at 100% CPU): fully in logs — top-N by
  construction.
- **Orphan swarm** (dozens of idle same-comm agents, low energy): **detected
  in-daemon over ALL processes** — no longer a gap. `progeny_system_orphan_max_comm_count`
  (metric) trends the biggest cluster; `body='orphan_swarm'` log records name each
  cluster ≥ `PROGENY_SWARM_THRESHOLD` (default 10) with comm, count, and sample PIDs.
- **Full per-PID depth for the recent window** (every process, trajectory over
  time, churn) is in the **in-RAM ring** — query with `progeny-local`. So the OTLP top-N
  limit only affects *long-term* history in OpenObserve; for "right now / last few
  hours" nothing is lost.

Never claim "no runaway" from empty per-PID OTLP logs alone — cross-check the
`orphan_max_comm_count` / CPU / energy metrics, and use `progeny-local` for the full
recent picture.

## Analysis playbook (question → query → read)

Each has a ready query in `queries/`. Numeric log fields are stored as **strings**
— always `CAST(x AS DOUBLE)`. Default window is 1h; pass `--hours N`.

1. **"What's eating my CPU/energy right now?"** → `queries/top-energy.sql`
   (last ~15 min, group by comm+ancestry, rank by summed `energy_nj`). Report the
   top few with their CPU%, energy, and **who spawned them** (ancestry).

2. **"What ran away overnight / while I was away?"** → `queries/runaway.sql`
   with `--hours N`: a PID sustaining high CPU across many samples
   (`COUNT(*) > k AND AVG(cpu) > 50`). Sustained, not a single spike.

3. **"Is there an orphan swarm?"** → `queries/orphan-swarm.sql`: check the
   `orphan_max_comm_count` metric (trend), then the `body='orphan_swarm'` log
   records (comm, count, sample PIDs, sample commands, original parent pids and
   commands, `original_parents_alive`). Judge agent-swarm (`claude`/`python`/
   `node`/`codex`) vs benign macOS XPC clusters (`*Service`/`*Extension`) by comm.

4. **"Who/what is <comm>? Who spawned it?"** → `queries/ancestry.sql`: pull the
   row's current `ppid`, `ancestry` (a `1/572/933` pid chain), full `command`
   (argv), and the first-seen fields: `first_ppid`, `first_ancestry`,
   `first_parent_comm`, `first_parent_command`, `original_parent_alive`.
   Reparented-to-launchd (`ppid=1`) + `first_ppid != 1` + dead first parent is
   the strongest runaway/orphan signature. If `first_ppid=1`, progenyd first saw
   it after it was already orphaned.

5. **"Why is it slow / hot / low on memory?"** → `queries/host-pressure.sql`:
   host CPU idle%, memory free/wired/compressed, load 1/5/15m, `thermal_level`
   (0 nominal → 3 critical), battery power watts when available, and fan/CPU/GPU
   power only if the host exposes those optional streams. Correlate a pressure
   window with the process logs from the same time range. Missing fan RPM or
   package watts means unavailable, not zero.

6. **"Is Spotlight causing this?"** → `progeny-local spotlight latest` or
   `progeny-local spotlight window <minutes>` for current/local evidence:
   active flag, worker count, `mds`/`mds_stores`/worker CPU, energy, disk deltas,
   and hot PIDs/commands. For "which files are being indexed", progeny only
   proves process pressure; use a short `sudo fs_usage -w -f filesys mds
   mds_stores mdworker_shared` burst and interpret it with
   `docs/SPOTLIGHT-RUNBOOK.md`.

7. **Deep dive / churn — "is this swarm the same PIDs or respawning?", "trace
   PID X over time", "everything running right now"** → `progeny-local` (in-RAM, full
   fidelity, no top-N):
   - `progeny-local comm <name>` → group rows by tick; **same PID set each tick = leak;
     growing distinct-PID count = respawn storm** (different root cause — live
     supervisor vs dead one).
   - `progeny-local pid <pid>` → that PID's cpu/energy/rss trajectory tick-by-tick.
   - `progeny-local window <minutes>` / `progeny-local latest` → every process (no top-N).
   - `progeny-local host latest` / `progeny-local host window <minutes>` → local
     host CPU/load/memory/thermal/battery-power samples.
   - `progeny-local spotlight latest` / `progeny-local spotlight window <minutes>` →
     Spotlight-specific aggregate pressure.
   Use this whenever the OTLP top-N or a bare count isn't enough to be sure.

## How to answer

Query → interpret in **prose with the concrete numbers and the parent chain**,
not a table dump. State the window you looked at. If metrics say "busy" but logs
are empty, that's the coverage limit — say what to change to see more. Offer the
follow-up query rather than a dashboard link.
