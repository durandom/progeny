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
  (`1/572/933`), first-seen parent command, full argv, energy, and rusage counters.
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

## Prebuilt binaries

GitHub Releases ship one Apple Silicon archive:

- `progenyd_<version>_darwin_arm64.tar.gz`

Intel Macs build from source. This repo only publishes the archive;
install path, checksum pin, and launchd belong to the deploy stack.

Publish a release by pushing a semver tag; see [docs/RELEASING.md](docs/RELEASING.md):

```bash
git tag v0.1.0
git push origin v0.1.0
```

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

## Run as root

Use a system LaunchDaemon when progeny should run as root. Stop the per-user
LaunchAgent first if it is already using the default query port `9847`.

```bash
swift build -c release

launchctl bootout gui/$(id -u)/local.progenyd 2>/dev/null || true

sudo install -d -m 0755 /usr/local/sbin
sudo install -m 0755 .build/release/progenyd /usr/local/sbin/progenyd
sudo install -m 0644 deploy/local.progenyd.daemon.plist /Library/LaunchDaemons/local.progenyd.plist

sudo launchctl bootstrap system /Library/LaunchDaemons/local.progenyd.plist
sudo launchctl print system/local.progenyd | grep -E 'state =|pid ='
```

Stop/remove the root daemon:

```bash
sudo launchctl bootout system/local.progenyd
sudo rm /Library/LaunchDaemons/local.progenyd.plist
```

The localhost query server remains bound to `127.0.0.1`. Logs go to
`/var/log/progenyd.log`. Running as root improves argv/path visibility for
processes owned by other users and is the right place to add privileged hardware
sampling later.

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
| `/host/latest` | newest host metrics, including CPU/load/memory/thermal and battery power when available |
| `/host/window/<minutes>` | host metrics over a window |
| `/spotlight/latest` | newest Spotlight aggregate: active flag, mds/mds_stores/worker CPU, worker count, disk deltas |
| `/spotlight/window/<minutes>` | Spotlight aggregate over a window |

## OpenTelemetry export (optional)

Set `PROGENY_OTLP=1` and `PROGENY_OTLP_ENDPOINT` to ship to any OTLP/HTTP backend
(an OTel Collector, OpenObserve, …). progeny emits:

- **metrics**: `progeny_system_*` (cpu, energy, process/orphan counts,
  `orphan_max_comm_count`) and `progeny_host_*` (cpu, memory, load, thermal,
  battery power; fan/CPU/GPU power streams are emitted only when values are
  available), plus `progeny_spotlight_*` aggregates for `mds`, `mds_stores`, and
  `mdworker*` activity.
- **logs**: per-PID `body="proc"` records (pid, ppid, comm, command, ancestry,
  first parent command, energy, …) + enriched `body="orphan_swarm"` cluster
  records, all tagged `service.name=progenyd`.

A ready local collector config for testing is in
[`deploy/otelcol-local.yaml`](deploy/otelcol-local.yaml).

Fan RPM is best-effort. progeny first tries the native SMC fan keys; on Apple
Silicon systems where those keys are not exposed to progeny but iStat Menus is
installed, it can fall back to the current console user's iStat Menus 7 sensor
history database and emit fresh RPM values from there.

## AI-driven analysis (no dashboards)

[`.agents/skills/progeny-analyze`](.agents/skills/progeny-analyze) is a
[Claude Code](https://claude.com/claude-code) skill that answers system questions
in prose — "what's eating my CPU/energy?", "what ran away overnight and who
spawned it?", "is this swarm leaking or respawning?" — by querying the in-RAM
buffer (`progeny-local`) and, if configured, OpenObserve (`progeny-oo`). The helper
scripts live in `.agents/skills/progeny-analyze/bin/`; see its `SKILL.md`.

## Design

The rationale — forensic-first, energy-first, the metrics-vs-logs cardinality
split, the in-RAM buffer, and a couple of sharp macOS gotchas found along the way
— is written up in [docs/DESIGN.md](docs/DESIGN.md).

## License

[MIT](LICENSE) © 2026 Marcel Hild
