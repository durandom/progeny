# progeny

**Process lineage & energy forensics for macOS.** A tiny, native, resident daemon
that answers the question monitoring tools can't: *which process ran away — and
who spawned it?*

> Every off-the-shelf monitor deliberately throws away per-PID history (it's
> high-cardinality). progeny keeps it — with the parent-ancestry chain — so you
> can reconstruct a runaway or an orphaned agent swarm after the fact, without a
> dashboard.

- **Native & lean** — Swift + `libproc`, ships-with-macOS APIs. ~2–18 MB RSS.
- **Energy-first** — background-QoS, coalesced timer → 1–2 wakeups per sample.
  Reads real per-process energy (`ri_energy_nj`), cycles, wakeups, per-QoS CPU.
- **Forensic** — every process with its `pid`, `ppid`, full **ancestry chain**
  (`1/572/933`), full argv, energy, and rusage counters.
- **Three query surfaces** — an in-RAM full-history buffer (no disk), plus
  optional OTLP metrics + logs to any OpenTelemetry backend.
- **No dashboards required** — an included Claude Code skill answers system
  questions in prose by querying the data.

---

## Why

Diagnosing a Mac that ran hot overnight, the useful question is *historical and
per-PID*: which exact process(es) misbehaved, and what spawned them. Live TUIs
(`top`, Activity Monitor) can't answer it, and time-series monitors collapse
per-PID data into groups to control cardinality — optimizing away exactly the
case forensics needs.

progeny generates the per-PID records itself and keeps them, routed so that
cardinality never becomes a problem (see [docs/DESIGN.md](docs/DESIGN.md)):

| Data | Where it goes | Why |
| --- | --- | --- |
| System + aggregate metrics | OTLP **metrics** | low cardinality, trend-friendly |
| Per-PID rows (pid, ppid, ancestry, argv, energy) | OTLP **logs** + **in-RAM ring** | PID is a *field*, never a metric label |
| Orphan-swarm clusters | detected in-daemon → metric + log | catches idle swarms the top-N misses |

## Requirements

- macOS 14+ (Apple Silicon or Intel)
- Swift 6.1+ toolchain (Xcode or Command Line Tools — `swift --version`)

## Build & run

```bash
swift build -c release

# Foreground, self-contained: in-RAM buffer + localhost query server on :9847.
./.build/release/progenyd

# Query the in-RAM buffer (another terminal):
curl -s http://127.0.0.1:9847/stats
curl -s http://127.0.0.1:9847/latest            # every process, newest snapshot
curl -s http://127.0.0.1:9847/comm/node         # one command across time (swarm churn)
```

No external services are needed: by default progeny keeps the last few hours of
full per-PID history **in RAM** (zero SSD writes) and serves it over localhost.

## Install as a resident agent (launchd)

```bash
install -m 0755 .build/release/progenyd ~/.local/bin/progenyd
sed "s|__HOME__|$HOME|g" deploy/local.progenyd.plist > ~/Library/LaunchAgents/local.progenyd.plist
launchctl bootstrap gui/$(id -u) ~/Library/LaunchAgents/local.progenyd.plist   # start
# ...
launchctl bootout   gui/$(id -u)/local.progenyd                                # stop
```

The agent runs at `ProcessType Background` (efficiency cores) with `KeepAlive`.

## Configuration (environment)

| Variable | Default | Meaning |
| --- | --- | --- |
| `PROGENY_INTERVAL_SEC` | `15` | sample interval (seconds) |
| `PROGENY_TOP_N` | `20` | per-PID rows shipped per tick, ranked by energy (argv-enriched) |
| `PROGENY_SWARM_THRESHOLD` | `10` | same-command `ppid=1` cluster size that flags an orphan swarm |
| `PROGENY_MEM_WINDOW_MIN` | `240` | in-RAM history window (minutes); ~a few hundred MB at 4h |
| `PROGENY_QUERY` | `1` | enable the localhost query server |
| `PROGENY_QUERY_PORT` | `9847` | query server port (bound to `127.0.0.1` only) |
| `PROGENY_OTLP` | `0` | export OTLP metrics + logs |
| `PROGENY_OTLP_ENDPOINT` | — | OTLP/HTTP base URL (SDK appends `/v1/{metrics,logs}`) |
| `PROGENY_WAL` | `0` | also write a flat-NDJSON write-ahead log to disk (off by default) |
| `PROGENY_WAL_DIR` | `~/.local/state/progeny` | WAL directory |
| `PROGENY_STDOUT` | `0` | also print NDJSON to stdout (dev) |

## The in-RAM query server

Bound to `127.0.0.1:PROGENY_QUERY_PORT` (never exposed off-host). Full fidelity —
every process, no top-N limit — over the buffered window. NDJSON out.

| Route | Returns |
| --- | --- |
| `/stats` | buffered tick count + time window |
| `/latest` | every process in the newest snapshot |
| `/pid/<pid>` | one PID's cpu/energy/rss trajectory across ticks |
| `/comm/<name>` | every row for a command over time — **swarm churn** (stable PID set = leak; growing = respawn) |
| `/window/<minutes>` | every process row in the last N minutes |

## OpenTelemetry export (optional)

Set `PROGENY_OTLP=1` and `PROGENY_OTLP_ENDPOINT` to ship to any OTLP/HTTP backend
(an OTel Collector, OpenObserve, …). progeny emits:

- **metrics**: `progeny_system_*` (cpu, energy, process/orphan counts,
  `orphan_max_comm_count`) and `progeny_host_*` (cpu, memory, load, thermal).
- **logs**: per-PID `body="proc"` records (pid, ppid, comm, command, ancestry,
  energy, …) + `body="orphan_swarm"` cluster records, all tagged
  `service.name=progenyd`.

A ready local collector config for testing is in
[`deploy/otelcol-local.yaml`](deploy/otelcol-local.yaml).

## AI-driven analysis (no dashboards)

[`.claude/skills/progeny-analyze`](.claude/skills/progeny-analyze) is a
[Claude Code](https://claude.com/claude-code) skill that answers system questions
in prose — "what's eating my CPU/energy?", "what ran away overnight and who
spawned it?", "is this swarm leaking or respawning?" — by querying the in-RAM
buffer (`pg-local`) and, if configured, OpenObserve (`pg-oo`). See its `SKILL.md`.

## Design

The rationale — forensic-first, energy-first, the metrics-vs-logs cardinality
split, the in-RAM buffer, and a couple of sharp macOS gotchas found along the way
— is written up in [docs/DESIGN.md](docs/DESIGN.md).

## License

[MIT](LICENSE) © 2026 Marcel Hild
