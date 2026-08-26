-- Orphan swarm = many same-comm processes reparented to launchd (ppid=1), the
-- signature of a crashed agent harness that didn't reap its pool. Detected
-- IN-DAEMON over ALL processes (not just top-N), so idle/parked swarms are caught
-- even when they burn no energy. Two ready signals:
--
-- 1) TREND (metric) — largest same-comm ppid=1 cluster, ANY size, every tick:
--    progeny-oo metrics "SELECT ROUND(MAX(value)) AS peak FROM \"progeny_system_orphan_max_comm_count\" GROUP BY __name__"
--    A jump into the dozens = a swarm forming.
--
-- 2) NAMED swarms (log record, emitted only when a cluster >= PROGENY_SWARM_THRESHOLD,
--    default 10). Each has comm, count, sample PIDs/start-times/commands, current
--    ancestry, and first-seen parent details when progenyd observed them before
--    orphaning.
--    progeny-oo logs "<this>"
--
-- ⚠️ INTERPRET: macOS itself runs same-comm ppid=1 XPC clusters (e.g.
-- MTLCompilerService, PlugInLibraryService, *XPCService, *Extension). The
-- runaway target is an AGENT swarm — comm like `claude`, `python`, `node`,
-- `codex`. Judge by comm identity, not the raw count.
SELECT comm,
       MAX(CAST(count AS BIGINT))                            AS peak_count,
       MAX(sample_pids)                                      AS sample_pids,
       MAX(sample_start_times)                               AS sample_start_times,
       MAX(sample_commands)                                  AS sample_commands,
       MAX(original_parent_pids)                             AS original_parent_pids,
       MAX(original_parent_commands)                         AS original_parent_commands,
       MAX(original_parents_alive)                           AS original_parents_alive,
       MAX(example_ancestry)                                 AS ancestry,
       MAX(example_first_ancestry)                           AS first_ancestry,
       ROUND(MAX(CAST(total_rss_bytes AS DOUBLE)) / 1048576) AS rss_mb
FROM "<logs_stream>"
WHERE service_name = 'progenyd' AND body = 'orphan_swarm'
GROUP BY comm
ORDER BY peak_count DESC;
