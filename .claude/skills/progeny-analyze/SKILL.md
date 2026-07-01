---
name: progeny-analyze
description: >-
  AI-driven macOS system analysis over progenyd telemetry in OpenObserve — no
  dashboards. Use when the user asks what is using CPU / energy / memory, why
  the Mac is slow or hot or loud, what process ran away (overnight or while
  away), who spawned a runaway (parent/ancestry), whether there is an orphaned
  process swarm (and whether it is leaking or respawning), how a process's
  CPU/energy changed over time, or for load/thermal/memory pressure. Queries
  progeny_* metric streams + forensic logs in OpenObserve (bin/pg-oo) and the
  daemon's in-RAM full-history buffer (bin/pg-local), then interprets in prose.
license: MIT
metadata:
  author: progeny
  version: "0.1"
---

# progeny-analyze

Answer "what is my Mac doing / what went wrong" by **querying telemetry, not
reading dashboards**. Data is produced by the `progenyd` daemon (this repo): the
in-RAM buffer is read locally via `bin/pg-local`; if you also ship OTLP to
OpenObserve, long-term data is read via `bin/pg-oo`. Query, then explain.

The founding use case: *which exact process ran away, and who spawned it* —
historical, per-PID forensics that live TUIs can't answer.

## Preflight (once per session)

```bash
bin/pg-oo env                      # resolves OpenObserve URL + creds
bin/pg-oo streams                  # confirms progeny_* metrics + <logs_stream>
bin/pg-local stats                 # in-RAM buffer: tick count + time window
launchctl print gui/$(id -u)/local.progenyd | grep -E 'state =|pid ='   # daemon alive?
```
`pg-oo` reads OpenObserve creds from `~/.config/progeny/openobserve.env` (override
`PROGENY_OO_ENV`); if OTLP isn't configured, skip it and use `pg-local` alone. If
`pg-local` can't connect, the daemon isn't running or `PROGENY_QUERY=0`. If the
daemon isn't running, there's no fresh data — say so.

## Three data surfaces

| Question type | Surface | How |
|---|---|---|
| Trends / pressure / long-term / cross-machine | **metrics** (`progeny_system_*`, `progeny_host_*`) in OpenObserve — complete aggregates | `pg-oo metrics …` |
| "Which process / who spawned it / what command", swarms | **logs** (`<logs_stream>` where `service_name='progenyd'`) — per-PID top-N + swarm records | `pg-oo logs …` |
| **Deep forensics NOW** — full per-PID history, every process, **churn/trajectory** | **in-RAM ring** (localhost, ~4h, no SSD) | `pg-local …` |

Rule of thumb: **`pg-oo` for "over days / is it normal", `pg-local` for "what exactly
is happening in the last hours, every PID, changing how"**. `pg-local` has no top-N
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
  time, churn) is in the **in-RAM ring** — query with `pg-local`. So the OTLP top-N
  limit only affects *long-term* history in OpenObserve; for "right now / last few
  hours" nothing is lost.

Never claim "no runaway" from empty per-PID OTLP logs alone — cross-check the
`orphan_max_comm_count` / CPU / energy metrics, and use `pg-local` for the full
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
   records (comm, count, sample PIDs). Judge agent-swarm (`claude`/`python`/
   `node`/`codex`) vs benign macOS XPC clusters (`*Service`/`*Extension`) by comm.

4. **"Who/what is <comm>? Who spawned it?"** → `queries/ancestry.sql`: pull the
   row's `ppid`, `ancestry` (a `1/572/933` pid chain), and full `command` (argv).
   Reparented-to-launchd (`ppid=1`) + a dead controller = the doc's runaway
   signature.

5. **"Why is it slow / hot / low on memory?"** → `queries/host-pressure.sql`:
   host CPU idle%, memory free/wired/compressed, load 1/5/15m, `thermal_level`
   (0 nominal → 3 critical). Correlate a pressure window with the process logs
   from the same time range.

6. **Deep dive / churn — "is this swarm the same PIDs or respawning?", "trace
   PID X over time", "everything running right now"** → `pg-local` (in-RAM, full
   fidelity, no top-N):
   - `pg-local comm <name>` → group rows by tick; **same PID set each tick = leak;
     growing distinct-PID count = respawn storm** (different root cause — live
     supervisor vs dead one).
   - `pg-local pid <pid>` → that PID's cpu/energy/rss trajectory tick-by-tick.
   - `pg-local window <minutes>` / `pg-local latest` → every process (no top-N).
   Use this whenever the OTLP top-N or a bare count isn't enough to be sure.

## How to answer

Query → interpret in **prose with the concrete numbers and the parent chain**,
not a table dump. State the window you looked at. If metrics say "busy" but logs
are empty, that's the coverage limit — say what to change to see more. Offer the
follow-up query rather than a dashboard link.
