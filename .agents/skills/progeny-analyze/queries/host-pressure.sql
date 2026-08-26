-- Host pressure — WHY the Mac is slow/hot/tight. These are METRICS (one stream
-- per _search), so run each with `progeny-oo metrics "<query>"`. Use --hours N for a
-- past window (e.g. overnight), then correlate with runaway.sql over the same range.

-- CPU: idle low = busy.
SELECT state, ROUND(AVG(value),1) AS avg, ROUND(MIN(value),1) AS min_
FROM "progeny_host_cpu_percent" GROUP BY state;

-- Memory: free low + compressed high = pressure (bytes).
--   progeny-oo metrics "SELECT state, ROUND(AVG(value)/1073741824,1) AS avg_gb FROM \"progeny_host_memory_bytes\" GROUP BY state"

-- Load average (1/5/15m):
--   progeny-oo metrics "SELECT window, ROUND(AVG(value),2) avg, ROUND(MAX(value),2) peak FROM \"progeny_host_load\" GROUP BY window"

-- Thermal (0 nominal → 3 critical): any row > 0 = throttling risk.
--   progeny-oo metrics "SELECT MAX(value) AS worst FROM \"progeny_host_thermal_level\" GROUP BY __name__"

-- Battery/system power when available. Negative battery watts means discharging.
--   progeny-oo metrics "SELECT ROUND(AVG(value),2) avg_w, ROUND(MIN(value),2) min_w, ROUND(MAX(value),2) max_w FROM \"progeny_host_battery_power_watts\" GROUP BY __name__"
--   progeny-oo metrics "SELECT ROUND(AVG(value),1) avg_pct FROM \"progeny_host_battery_percent\" GROUP BY __name__"
--   progeny-oo metrics "SELECT ROUND(AVG(value),1) external_power FROM \"progeny_host_external_power_connected\" GROUP BY __name__"

-- Optional hardware streams. Missing streams/rows mean unavailable, not zero.
--   progeny-oo metrics "SELECT fan, ROUND(AVG(value),0) avg_rpm, ROUND(MAX(value),0) max_rpm FROM \"progeny_host_fan_rpm\" GROUP BY fan"
--   progeny-oo metrics "SELECT ROUND(AVG(value),2) avg_w, ROUND(MAX(value),2) max_w FROM \"progeny_host_cpu_power_watts\" GROUP BY __name__"
--   progeny-oo metrics "SELECT ROUND(AVG(value),2) avg_w, ROUND(MAX(value),2) max_w FROM \"progeny_host_gpu_power_watts\" GROUP BY __name__"

-- Process/orphan counts over time (swarm/leak detector):
--   progeny-oo metrics "SELECT ROUND(AVG(value)) procs FROM \"progeny_system_process_count\" GROUP BY __name__"
--   progeny-oo metrics "SELECT ROUND(MAX(value)) peak_orphans FROM \"progeny_system_orphan_count\" GROUP BY __name__"

-- NOTE: OpenObserve requires a GROUP BY for metric aggregates (it injects
-- _timestamp into the projection). For a single scalar over one stream, use
-- `GROUP BY __name__` (constant per stream) as above.
