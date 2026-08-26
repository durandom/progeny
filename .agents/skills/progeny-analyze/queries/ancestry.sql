-- Identify a process and its lineage — "who spawned this?".
-- Replace <COMM> with the name (or swap the filter to  pid = '<PID>').
-- ancestry is the current launchd→…→parent pid chain. first_* preserves the
-- launcher progenyd saw when this PID/start-time first appeared.
-- ppid=1 + first_ppid!=1 + original_parent_alive=false = strong orphan signature.
-- progeny-oo logs "<this>"
SELECT _timestamp, pid, ppid, comm, ancestry, path, command,
       first_seen_sec, first_ppid, first_ancestry,
       first_parent_comm, first_parent_path, first_parent_command,
       original_parent_alive,
       ROUND(CAST(cpu_percent AS DOUBLE), 1)       AS cpu,
       ROUND(CAST(energy_nj   AS DOUBLE) / 1e6, 1) AS energy_mj,
       ROUND(CAST(rss_bytes   AS DOUBLE) / 1048576) AS rss_mb
FROM "<logs_stream>"
WHERE service_name = 'progenyd' AND comm = '<COMM>'
ORDER BY _timestamp DESC
LIMIT 10;
