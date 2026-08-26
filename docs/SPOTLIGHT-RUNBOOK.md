# Spotlight indexing runbook

Use this when `mds`, `mds_stores`, or many `mdworker_shared` processes drive CPU,
load, or fan noise. The goal is to answer two questions:

1. Is Spotlight genuinely indexing, or is a daemon stuck?
2. Which path or workload is feeding the indexer?

## 1. Confirm host pressure

```bash
.agents/skills/progeny-analyze/bin/progeny-local host latest
.agents/skills/progeny-analyze/bin/progeny-local stats
```

Look for high `load1`, low `cpuIdlePct`, elevated `thermalState`, and whether the
machine is on external power. Missing `fanRPMs` means the sensor source is not
available yet, not that the fans are stopped.

## 2. Confirm the Spotlight processes

```bash
.agents/skills/progeny-analyze/bin/progeny-local comm mds
.agents/skills/progeny-analyze/bin/progeny-local comm mds_stores
.agents/skills/progeny-analyze/bin/progeny-local comm mdworker_shared

ps -axo pid,ppid,user,%cpu,%mem,rss,command |
  awk 'NR==1 || /[m]ds|[m]dworker|[M]etadata/ {print}' |
  head -n 80
```

Expected active-indexing shape:

- `mds` has steady CPU and performs many small metadata reads.
- `mds_stores` writes to `.Spotlight-V100` and may have high RSS.
- Many short-lived `mdworker_shared -s mdworker -c MDSImporterWorker` processes
  read source files in parallel.

If only `mds_stores` is hot and workers are absent, take a sample before assuming
normal indexing.

## 3. Check Spotlight volume policy and journals

```bash
sudo mdutil -a -s
sudo mdutil -P /System/Volumes/Data
sudo mdutil -L /System/Volumes/Data
```

Read `mdutil -P` for:

- `Exclusions`: paths Spotlight should ignore.
- `journals.live_user`, `journals.live_system`, `journals.scan`,
  `journals.repair`: pending work sources.
- recently modified `live.*` index shards and large `journal.*` files.

An exclusion can coexist with current indexing if the work was already journaled,
if the exclusion does not match the canonical path in the active store, or if the
index store is processing stale backlog.

## 4. Capture the file paths being indexed

`fs_usage` is the best quick answer for "what is Spotlight touching right now".
Keep the sample short because it traces kernel file activity.

```bash
sudo fs_usage -w -f filesys mds mds_stores mdworker_shared
```

Stop after a few seconds with `Ctrl-C`. The important lines are `open`, `read`,
`pread`, `RdData`, `WrData`, and paths outside `.Spotlight-V100`.

If the output is too noisy, write a short capture and summarize paths:

```bash
sudo fs_usage -w -f filesys mds mds_stores mdworker_shared > /tmp/spotlight-fs.txt

awk '
  match($0, "/System/Volumes/Data/[^ ]+") {
    path = substr($0, RSTART, RLENGTH)
    sub("/System/Volumes/Data", "", path)
    print path
  }
' /tmp/spotlight-fs.txt |
  sed 's#/node_modules/.*#/node_modules/...#' |
  sort | uniq -c | sort -nr | head -n 30
```

## 5. Sample `mds_stores` when it looks stuck

```bash
pid=$(pgrep -x mds_stores | head -n 1)
sudo sample "$pid" 3 1
sudo lsof -n -p "$pid" | head -n 160
```

Interpretation:

- Stacks containing `setAttributesBulk`, `si_writeBackAndIndex...`,
  `CITokenizerGetTokens...`, or CoreNLP tokenization point to real index
  write/tokenization work.
- `lsof` dominated by `.Spotlight-V100/Store-V2/...` means the store writer is
  active. Combine this with `fs_usage` to identify the source paths.

## 6. Today's observed pattern

On 2026-07-02 around 00:55 Europe/Berlin, the machine showed:

- `thermalState=fair`, `load1` around 45, `cpuIdlePct` around 32%.
- `mds_stores` reached about 119% CPU in progeny's local ring and wrote tens of
  MB per 15 s tick.
- `mdworker_shared` churned many short-lived importer workers.
- `sample mds_stores` showed Spotlight store writes and tokenizer work.
- `fs_usage` showed active indexing under:

```text
/Users/mhild/src/durandom/spellkave/wt-authorcli-1361/node_modules/...
```

Examples included `.js`, `.js.map`, `.d.ts`, `.d.ts.map`, and `package.json`
files from package trees such as `@opentelemetry`, `@luma.gl`, `@swc`,
`@jridgewell`, `apache-arrow`, and `docx-preview`.

This is the likely cause of the fan event: Spotlight was walking a large
JavaScript dependency tree and feeding many small source/map/type files to
parallel metadata importers, while `mds_stores` wrote the resulting index terms.

There is a notable policy mismatch: `mdutil -P /System/Volumes/Data` listed
`/Users/mhild/src` in `Exclusions`, but `fs_usage` still observed indexing below
that path. Treat that as a separate investigation: verify whether the exclusion
was applied after the work was already journaled, whether the canonical path
differs, or whether the store needs reindex/policy refresh.

## 7. Mitigation checklist

Do not blindly disable Spotlight globally. Prefer narrower fixes:

```bash
sudo mdutil -i off /path/to/noisy/tree
sudo mdutil -i on /path/to/noisy/tree
```

For source trees, prefer persistent exclusions for generated dependency/cache
directories:

- `node_modules`
- build outputs (`.build`, `dist`, `target`, `DerivedData`)
- package-manager caches
- agent/worktree scratch directories

After changing exclusions, use `fs_usage` again to verify that Spotlight stopped
touching the noisy path.

## 8. Progeny monitoring gaps to close

Progeny can already prove the pressure correlation: host load/thermal plus
per-process CPU, energy, disk deltas, RSS, command, and lineage. It does not yet
capture the file path being indexed because that requires short-lived filesystem
tracing (`fs_usage`, DTrace, EndpointSecurity, or FSEvents correlation), which is
more expensive and higher privilege than the normal sampler.

Useful next telemetry:

- A bounded Spotlight detector: count active `mds`, `mds_stores`, and
  `mdworker*` processes, their aggregate CPU/energy/disk deltas, and active
  worker count. This is exposed as `progeny-local spotlight latest` and
  `progeny-local spotlight window <minutes>`.
- A manual burst-capture command for Spotlight path forensics that runs
  `fs_usage` for 5-10 seconds and summarizes top source directories.
- Optional `mdutil -P` snapshot capture on demand, not every tick.
- Fan RPM support is best-effort and emitted as `progeny.host.fan.rpm{fan=N}`
  when available. On the Mac17,6 test machine, `powermetrics --samplers thermal`
  exposed thermal pressure but no fan RPM, and no direct `fan`/`rpm` channel was
  visible in the ordinary IOKit registry walk. progeny now tries native SMC fan
  keys first, then falls back to fresh iStat Menus 7 sensor-history values when
  iStat is installed and running. Empty `fanRPMs` means no provider produced a
  fresh value.
