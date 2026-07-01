# Design notes

## The problem

A dev Mac hits high load overnight with no obvious cause. Each incident looks
like a different culprit (Spotlight, Gatekeeper, a hung CLI call), but the engine
underneath is usually the same: a fleet of orphaned processes churning, which
macOS security/indexing daemons then react to. The daemon that shows up hot in
`top` is a *symptom*.

The decisive question is **historical and per-PID**: *which exact process ran
away, and who spawned it?* Two properties make it hard:

1. **Live tools can't answer it.** `top`/Activity Monitor show now, not 3am.
2. **Time-series monitors deliberately refuse per-PID history.** PIDs churn, so
   per-PID series are high-cardinality; every tool collapses them into named
   groups to stay affordable. Forensics is precisely the minority case they
   optimize *against*.

So progeny generates the per-PID records itself and keeps them — with the parent
lineage that turns "a runaway" into "a runaway *spawned by X*".

## Language & shape

- **Swift + `libproc`.** Ships with macOS; direct access to
  `proc_pid_rusage(RUSAGE_INFO_V6)` — energy (nanojoules), cycles, instructions,
  interrupt/idle wakeups, disk bytes, per-QoS CPU time — none of which `ps`
  exposes. No runtime beyond the system libraries; a few MB RSS.
- **Resident daemon, not a cron one-shot.** CPU% and energy are *deltas* between
  samples; a resident process holds the prior counters and computes rates
  cheaply. That's the reason to stay resident — not speed.

## Energy-first, not RAM-first

The target machine has plenty of RAM; the real cost of a 24/7 sampler is
**wakeups × core type**, i.e. energy. Levers used:

- QoS `background` → the scheduler runs the work on efficiency cores.
- A `DispatchSourceTimer` with generous **leeway** → the kernel coalesces our
  wakeups with other timers. Fewer wakeups dominates any code micro-optimization.
- One `proc_listpids` pass per tick; no kernel tracing (`fs_usage`/dtrace/
  EndpointSecurity would arm system-wide tracing that taxes *every* syscall).

Measured self-cost at a 15 s interval: ~1–2 wakeups per tick, sub-milliwatt
average.

## Metrics vs. logs — the cardinality split

OpenTelemetry has three signals; the trick is routing per-PID data to the right
one:

- **System + aggregate → metrics.** Low cardinality, trend-friendly.
- **Per-PID rows → logs.** A log record is a *wide event*; `pid` is a field, not
  a label. Log stores handle high cardinality natively. Emitting per-PID as
  *metric labels* would recreate the exact cardinality bomb every tool avoids.

This is the reconciliation: OTel fits macOS process monitoring fine once per-PID
goes through the logs pipeline, not the metrics pipeline. (progeny is the
scraper; OTel is only the wire format — the OTel Collector's host-metrics process
scraper doesn't exist on macOS anyway.)

## Three storage tiers

| Tier | Fidelity | Retention | Cost |
| --- | --- | --- | --- |
| **In-RAM ring** | every process, every field, every tick | recent window (default 4h) | RAM only, **zero SSD** |
| OTLP **logs** | top-N by energy + swarm records | long-term (your backend) | network |
| OTLP **metrics** | aggregates only | long-term | network |

The in-RAM ring is a write-ahead log that never touches disk — full forensic
depth for "what's happening in the last few hours" (including per-member
trajectories and swarm churn), served over a localhost-only HTTP endpoint. OTLP
is the summarized long-term / cross-machine layer.

## Orphan-swarm detection in the daemon

A parked swarm (dozens of idle same-command processes reparented to `launchd`)
burns little energy, so it never makes the top-N shipped to logs. Rather than ship
all ~1000 processes every tick, the daemon detects the swarm from the snapshot it
already holds and emits a bounded signal:

- a gauge `progeny_system_orphan_max_comm_count` (largest same-comm `ppid=1`
  cluster) — trends/alerts even for idle swarms;
- a `body="orphan_swarm"` log record per cluster over threshold, with the sample
  PIDs.

`ppid=1` is the discriminator: legit multi-process apps (browser helpers) are
parented to their app, not `launchd`. Detection is cheap and lives in the daemon;
*interpretation* (agent swarm vs. benign macOS XPC cluster) is left to the query
layer.

## macOS gotchas worth recording

- **`rusage` CPU times are mach-absolute units, not nanoseconds.** Treating them
  as ns under-reports CPU% by the mach timebase factor (~41.7 on Apple Silicon).
  Convert via `mach_timebase_info` (a no-op on Intel). Caught only by validating
  against `top`.
- **`comm` is truncated (~16/32 chars).** Full argv needs `KERN_PROCARGS2`
  (and `proc_pidpath` for the binary path), which only works for your own
  processes without root — fine, since the runaways you hunt are yours. It's a
  per-PID syscall, so progeny resolves argv lazily, only for the rows it ships.
- **Swift 6 top-level actor isolation.** Globals/closures in `main.swift` are
  `@MainActor`; a `DispatchSource` timer handler runs on a background queue and
  will trap on an isolation assertion. Put setup in a plain global `func`
  (nonisolated) and mark the shared state `nonisolated(unsafe)` where a single
  serial queue already guarantees safety.
