-- Worked example, step 4 of 4: one result set, one row per claim, PASS or FAIL.
-- Run after 03_walkthrough.sql. Every row should say PASS.

WITH
ch AS (SELECT * FROM CDC_DEMO.CUSTOMER_FEED.CUSTOMER_PROFILE_CHANGE_HISTORY),
dl AS (SELECT * FROM CDC_DEMO.CUSTOMER_FEED.CUSTOMER_PROFILE_DELTA),
bs AS (SELECT * FROM CDC_DEMO.CUSTOMER_FEED.CUSTOMER_PROFILE_BASE),
lg AS (SELECT * FROM CDC_DEMO.CDC_AUDIT.CDC_RUN_LOG WHERE USE_CASE = 'CUSTOMER_PROFILE'),
checks AS (
  SELECT 1 AS n, 'Initial load seeded 5 UPSERT rows' AS claim, '5' AS expected,
         (SELECT COUNT(*) FROM dl WHERE INSERT_DATE::DATE = '2026-01-05' AND ACTION = 'UPSERT')::VARCHAR AS actual
  UNION ALL SELECT 2, 'Day 1: one field-level UPDATE row, on TIER', 'TIER',
         (SELECT LISTAGG(FIELD_NAME, ',') FROM ch WHERE CHANGE_DATE::DATE = '2026-01-06' AND CHANGE_TYPE = 'UPDATE')
  UNION ALL SELECT 3, 'Day 1: new customer logged as 5 INSERT rows (one per field)', '5',
         (SELECT COUNT(*) FROM ch WHERE CHANGE_DATE::DATE = '2026-01-06' AND CHANGE_TYPE = 'INSERT')::VARCHAR
  UNION ALL SELECT 4, 'Day 1: 2 UPSERT rows delivered', '2',
         (SELECT COUNT(*) FROM dl WHERE INSERT_DATE::DATE = '2026-01-06' AND ACTION = 'UPSERT')::VARCHAR
  UNION ALL SELECT 5, 'Day 2: upstream rename produced no changes', '0',
         (SELECT COUNT(*) FROM ch WHERE CHANGE_DATE::DATE = '2026-01-07')::VARCHAR
  UNION ALL SELECT 6, 'Day 2: upsert still logged SUCCESS', 'SUCCESS',
         (SELECT MAX(STATUS) FROM lg WHERE PROCEDURE_NAME = 'SP_CUSTOMER_PROFILE_UPSERT' AND RUN_TIMESTAMP::DATE = '2026-01-07')
  UNION ALL SELECT 7, 'Day 3: 2 DELETE rows delivered', '2',
         (SELECT COUNT(*) FROM dl WHERE INSERT_DATE::DATE = '2026-01-08' AND ACTION = 'DELETE')::VARCHAR
  UNION ALL SELECT 8, 'Day 3: DELETE row carries last-known values', 'Chloe Nguyen|Melbourne',
         (SELECT FULL_NAME || '|' || CITY FROM dl WHERE CUSTOMER_ID = 'C003' AND ACTION = 'DELETE')
  UNION ALL SELECT 9, 'Day 3: NULL email delivered as literal null', 'null',
         (SELECT EMAIL FROM dl WHERE CUSTOMER_ID = 'C004' AND INSERT_DATE::DATE = '2026-01-08')
  UNION ALL SELECT 10, 'Day 3: history records the old email and a NULL new value', 'dev@example.com|<NULL>',
         (SELECT OLD_VALUE || '|' || COALESCE(NEW_VALUE, '<NULL>') FROM ch
          WHERE CUSTOMER_ID = 'C004' AND FIELD_NAME = 'EMAIL' AND CHANGE_TYPE = 'UPDATE')
  UNION ALL SELECT 11, 'Day 3 re-run: one successful upsert and one delta, not two', '1|1',
         (SELECT COUNT_IF(PROCEDURE_NAME = 'SP_CUSTOMER_PROFILE_UPSERT') || '|' || COUNT_IF(PROCEDURE_NAME = 'SP_CUSTOMER_PROFILE_DELTA')
          FROM lg WHERE STATUS = 'SUCCESS' AND RUN_TIMESTAMP::DATE = '2026-01-08')
  UNION ALL SELECT 12, 'No customer delivered twice in one day', '0',
         (SELECT COUNT(*) FROM (SELECT CUSTOMER_ID, INSERT_DATE FROM dl GROUP BY 1, 2 HAVING COUNT(*) > 1))::VARCHAR
  UNION ALL SELECT 13, 'Day 4: returning customer logged as INSERT and live again', '5|false',
         (SELECT (SELECT COUNT(*) FROM ch WHERE CUSTOMER_ID = 'C006' AND CHANGE_DATE::DATE = '2026-01-09' AND CHANGE_TYPE = 'INSERT')
                 || '|' || (SELECT IS_DELETED::VARCHAR FROM bs WHERE CUSTOMER_ID = 'C006'))
  UNION ALL SELECT 14, 'Day 4: numeric change delivered as a number', '7500.00',
         (SELECT CREDIT_LIMIT::VARCHAR FROM dl WHERE CUSTOMER_ID = 'C001' AND INSERT_DATE::DATE = '2026-01-09')
  UNION ALL SELECT 15, 'Numeric NULL left as NULL, not coerced', '<NULL>',
         (SELECT COALESCE(CREDIT_LIMIT::VARCHAR, '<NULL>') FROM dl WHERE CUSTOMER_ID = 'C005' AND INSERT_DATE::DATE = '2026-01-05')
  UNION ALL SELECT 16, 'Housekeeping hard-purged the delivered delete past grace', '1|0',
         (SELECT (SELECT MAX(ROWS_PURGED) FROM lg WHERE PROCEDURE_NAME = 'SP_CUSTOMER_PROFILE_HOUSEKEEPING')::VARCHAR
                 || '|' || (SELECT COUNT(*) FROM bs WHERE CUSTOMER_ID = 'C003')::VARCHAR)
  UNION ALL SELECT 17, 'Delivered DELETE rows survive the BASE purge', '2',
         (SELECT COUNT(*) FROM dl WHERE ACTION = 'DELETE')::VARCHAR
  UNION ALL SELECT 18, 'Total delta rows: 5 + 2 + 0 + 3 + 2', '12',
         (SELECT COUNT(*) FROM dl)::VARCHAR
  UNION ALL SELECT 19, 'No FAILED runs logged', '0',
         (SELECT COUNT(*) FROM lg WHERE STATUS = 'FAILED')::VARCHAR
)
SELECT n, claim, expected, actual, IFF(EQUAL_NULL(expected, actual), 'PASS', 'FAIL') AS result
FROM checks
ORDER BY n;
