SELECT process_id,
       SUM(CASE WHEN task_status='NEW' THEN 1 ELSE 0 END)        AS new_cnt,
       SUM(CASE WHEN task_status='WAITING' THEN 1 ELSE 0 END)    AS waiting_cnt,
       SUM(CASE WHEN task_status='SUBMITTED' THEN 1 ELSE 0 END)  AS submitted_cnt,
       SUM(CASE WHEN task_status='IN_PROGRESS' THEN 1 ELSE 0 END)AS running_cnt,
       SUM(CASE WHEN task_status='COMPLETED' THEN 1 ELSE 0 END)  AS done_cnt,
       SUM(CASE WHEN task_status='ERRORED' THEN 1 ELSE 0 END)    AS err_cnt
FROM maintain_task_log
GROUP BY process_id
ORDER BY process_id;

==

  SELECT process_id, batch_id, status, status_message, start_time, end_time
FROM ACCOUNTDBO.maintain_process_log
WHERE process_id IN (
  SELECT process_id
  FROM ACCOUNTDBO.maintain_task_log
  GROUP BY process_id
)
ORDER BY start_time DESC;

====
       
Got you. Here’s a “schema-level stats status” mini-dashboard you can paste into SQL*Plus/SQLcl/SQL Developer for ACCOUNTDBO. It tells you what Oracle thinks about prefs, coverage, staleness, locks, and recent work.

0) Make DML deltas current (one liner)
BEGIN DBMS_STATS.FLUSH_DATABASE_MONITORING_INFO; END;
/

1) DBMS_STATS preferences currently in effect for the schema
SELECT pref_name,
       DBMS_STATS.GET_PREFS(pref_name, 'ACCOUNTDBO') AS value
FROM (
  SELECT 'INCREMENTAL' pref_name FROM dual UNION ALL
  SELECT 'INCREMENTAL_STALENESS' FROM dual UNION ALL
  SELECT 'ESTIMATE_PERCENT' FROM dual UNION ALL
  SELECT 'METHOD_OPT' FROM dual UNION ALL
  SELECT 'DEGREE' FROM dual UNION ALL
  SELECT 'CASCADE' FROM dual UNION ALL
  SELECT 'PUBLISH' FROM dual UNION ALL
  SELECT 'STALE_PERCENT' FROM dual UNION ALL
  SELECT 'NO_INVALIDATE' FROM dual
)
ORDER BY pref_name;

2) Coverage & staleness summary (tables vs partitions)
-- totals
SELECT
  (SELECT COUNT(*) FROM dba_tables         WHERE owner='ACCOUNTDBO') AS tables_total,
  (SELECT COUNT(*) FROM dba_tab_partitions WHERE table_owner='ACCOUNTDBO') AS partitions_total
FROM dual;

-- tables missing table-level stats
SELECT COUNT(*) AS tables_missing_stats
FROM   dba_tables t
WHERE  t.owner='ACCOUNTDBO'
AND    NOT EXISTS (
  SELECT 1
  FROM   dba_tab_statistics s
  WHERE  s.owner=t.owner AND s.table_name=t.table_name
  AND    s.partition_name IS NULL AND s.last_analyzed IS NOT NULL
);

-- partitions missing partition-level stats
SELECT COUNT(*) AS partitions_missing_stats
FROM   dba_tab_partitions p
WHERE  p.table_owner='ACCOUNTDBO'
AND    NOT EXISTS (
  SELECT 1
  FROM   dba_tab_statistics s
  WHERE  s.owner=p.table_owner AND s.table_name=p.table_name
  AND    s.partition_name=p.partition_name AND s.last_analyzed IS NOT NULL
);

-- stale stats counts
SELECT
  (SELECT COUNT(*) FROM dba_tab_statistics
    WHERE owner='ACCOUNTDBO' AND partition_name IS NULL AND stale_stats='YES') AS tables_stale,
  (SELECT COUNT(*) FROM dba_tab_statistics
    WHERE owner='ACCOUNTDBO' AND partition_name IS NOT NULL AND stale_stats='YES') AS partitions_stale
FROM dual;

-- locked stats (won't auto-refresh)
SELECT COUNT(*) AS objects_with_locked_stats
FROM   dba_tab_statistics
WHERE  owner='ACCOUNTDBO'
AND    NVL(stattype_locked,'NONE') <> 'NONE';

3) “What changed a lot since last analyze?” (prioritize gathering)
WITH mods AS (
  SELECT table_owner, table_name, SUM(inserts+updates+deletes) dml
  FROM   dba_tab_modifications
  WHERE  table_owner='ACCOUNTDBO'
  GROUP  BY table_owner, table_name
)
SELECT s.table_name,
       s.num_rows,
       NVL(m.dml,0) AS dml_since_analyze,
       ROUND(NVL(m.dml,0)/NULLIF(s.num_rows,0)*100,2) AS pct_changed,
       s.last_analyzed,
       s.stale_stats
FROM   dba_tab_statistics s
LEFT   JOIN mods m
       ON m.table_owner=s.owner AND m.table_name=s.table_name
WHERE  s.owner='ACCOUNTDBO'
AND    s.partition_name IS NULL
ORDER  BY pct_changed DESC NULLS LAST, NVL(m.dml,0) DESC
FETCH FIRST 50 ROWS ONLY;

4) Recent optimizer-stats jobs that touched this schema
SELECT start_time, end_time, target, type, status, message
FROM   dba_optstat_operations
WHERE  target LIKE 'ACCOUNTDBO%'
ORDER  BY start_time DESC
FETCH FIRST 30 ROWS ONLY;

5) Index sanity (unusable = broken, coalesce/rebuild candidates elsewhere)
SELECT COUNT(*) AS unusable_global_indexes
FROM   dba_indexes
WHERE  owner='ACCOUNTDBO' AND status='UNUSABLE';

SELECT COUNT(*) AS unusable_index_partitions
FROM   dba_ind_partitions
WHERE  index_owner='ACCOUNTDBO' AND status='UNUSABLE';

6) Histogram footprint (spot unexpected column histograms)
SELECT COUNT(*) AS columns_with_histograms
FROM   dba_tab_col_statistics
WHERE  owner='ACCOUNTDBO' AND histogram <> 'NONE';

7) “How fresh are we?” (age buckets for table stats)
SELECT CASE
         WHEN last_analyzed >= SYSDATE-1   THEN '≤ 1 day'
         WHEN last_analyzed >= SYSDATE-7   THEN '2–7 days'
         WHEN last_analyzed >= SYSDATE-30  THEN '8–30 days'
         WHEN last_analyzed IS NULL         THEN 'Never'
         ELSE '30+ days'
       END AS age_bucket,
       COUNT(*) AS tables
FROM   dba_tab_statistics
WHERE  owner='ACCOUNTDBO' AND partition_name IS NULL
GROUP  BY CASE
         WHEN last_analyzed >= SYSDATE-1   THEN '≤ 1 day'
         WHEN last_analyzed >= SYSDATE-7   THEN '2–7 days'
         WHEN last_analyzed >= SYSDATE-30  THEN '8–30 days'
         WHEN last_analyzed IS NULL         THEN 'Never'
         ELSE '30+ days'
       END
ORDER  BY 1;


Read this like a cockpit:

If preferences show INCREMENTAL=TRUE and sensible METHOD_OPT/ESTIMATE_PERCENT, you’re set.

If missing/stale counts are high, start with recent partitions first; tables with high pct_changed are your first targets.

If locked stats > 0, make sure those are intentional.

If unusable indexes > 0, fix those before blaming the CBO.


Once you’ve got the snapshot, you can decide whether to run a targeted gather or wire up a nightly GATHER AUTO to keep it green.

