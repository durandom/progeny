-- Identify a process and its lineage — "who spawned this?".
-- Replace <COMM> with the name (or swap the filter to  pid = '<PID>').
-- ancestry is a launchd→…→parent pid chain; ppid=1 + a dead controller = runaway.
-- pg-oo logs "<this>"
SELECT _timestamp, pid, ppid, comm, ancestry, path, command,
       ROUND(CAST(cpu_percent AS DOUBLE), 1)       AS cpu,
       ROUND(CAST(energy_nj   AS DOUBLE) / 1e6, 1) AS energy_mj,
       ROUND(CAST(rss_bytes   AS DOUBLE) / 1048576) AS rss_mb
FROM "<logs_stream>"
WHERE service_name = 'progenyd' AND comm = '<COMM>'
ORDER BY _timestamp DESC
LIMIT 10;
