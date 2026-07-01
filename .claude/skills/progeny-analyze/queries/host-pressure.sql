-- Host pressure — WHY the Mac is slow/hot/tight. These are METRICS (one stream
-- per _search), so run each with `pg-oo metrics "<query>"`. Use --hours N for a
-- past window (e.g. overnight), then correlate with runaway.sql over the same range.

-- CPU: idle low = busy.
SELECT state, ROUND(AVG(value),1) AS avg, ROUND(MIN(value),1) AS min_
FROM "progeny_host_cpu_percent" GROUP BY state;

-- Memory: free low + compressed high = pressure (bytes).
--   pg-oo metrics "SELECT state, ROUND(AVG(value)/1073741824,1) AS avg_gb FROM \"progeny_host_memory_bytes\" GROUP BY state"

-- Load average (1/5/15m):
--   pg-oo metrics "SELECT window, ROUND(AVG(value),2) avg, ROUND(MAX(value),2) peak FROM \"progeny_host_load\" GROUP BY window"

-- Thermal (0 nominal → 3 critical): any row > 0 = throttling risk.
--   pg-oo metrics "SELECT MAX(value) AS worst FROM \"progeny_host_thermal_level\" GROUP BY __name__"

-- Process/orphan counts over time (swarm/leak detector):
--   pg-oo metrics "SELECT ROUND(AVG(value)) procs FROM \"progeny_system_process_count\" GROUP BY __name__"
--   pg-oo metrics "SELECT ROUND(MAX(value)) peak_orphans FROM \"progeny_system_orphan_count\" GROUP BY __name__"

-- NOTE: OpenObserve requires a GROUP BY for metric aggregates (it injects
-- _timestamp into the projection). For a single scalar over one stream, use
-- `GROUP BY __name__` (constant per stream) as above.
