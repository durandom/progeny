-- Top energy consumers in the window. Run with --hours 0.25 for "right now".
-- energy_nj is per-interval; SUM over the window = total energy spent.
-- pg-oo logs "<this>" --hours 0.25
SELECT comm, ppid, ancestry,
       ROUND(MAX(CAST(cpu_percent AS DOUBLE)), 1)         AS max_cpu,
       ROUND(SUM(CAST(energy_nj  AS DOUBLE)) / 1e9, 2)    AS energy_j,
       ROUND(MAX(CAST(rss_bytes  AS DOUBLE)) / 1048576)   AS rss_mb
FROM "<logs_stream>"
WHERE service_name = 'progenyd'
GROUP BY comm, ppid, ancestry
ORDER BY energy_j DESC
LIMIT 15;
