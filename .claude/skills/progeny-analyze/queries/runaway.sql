-- Sustained runaway: one PID hot across MANY samples (not a single spike).
-- Run over the suspect window, e.g. --hours 12 for "overnight".
-- pg-oo logs "<this>" --hours 12
SELECT pid, comm, ppid, ancestry,
       COUNT(*)                                        AS samples,
       ROUND(AVG(CAST(cpu_percent AS DOUBLE)), 1)      AS avg_cpu,
       ROUND(MAX(CAST(cpu_percent AS DOUBLE)), 1)      AS max_cpu,
       ROUND(MAX(CAST(rss_bytes   AS DOUBLE)) / 1048576) AS rss_mb,
       MAX(command)                                    AS command
FROM "<logs_stream>"
WHERE service_name = 'progenyd'
GROUP BY pid, comm, ppid, ancestry
HAVING COUNT(*) > 10 AND AVG(CAST(cpu_percent AS DOUBLE)) > 50
ORDER BY avg_cpu DESC
LIMIT 20;
