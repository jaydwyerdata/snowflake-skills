-- Worked example, step 4 of 4: one row per claim, PASS or FAIL. Run straight after step 3, in the
-- same session (the results live in session variables). Every row should say PASS.

USE ROLE RAP_DEMO_ADMIN;
USE SECONDARY ROLES NONE;

WITH checks AS (
  SELECT 1 AS n, 'Clean file: 10 records assigned, 4 mappings, 3 roles' AS claim,
         'Assigned 10 records, onboarded 4 mappings, created 3 roles from request_01.csv' AS expected, $ONBOARD_1 AS actual
  UNION ALL SELECT 2, 'Re-running the same file changes nothing',
         'Assigned 0 records, onboarded 0 mappings, created 0 roles from request_01.csv', $ONBOARD_RERUN
  UNION ALL SELECT 3, 'North team sees only NORTH', 'NORTH', $NORTH_KEYS
  UNION ALL SELECT 4, 'North team sees all 4 NORTH rows', '4', $NORTH_ROWS::VARCHAR
  UNION ALL SELECT 5, 'One role, many keys: south team sees EAST and SOUTH', 'EAST,SOUTH', $SOUTH_KEYS
  UNION ALL SELECT 6, 'South team sees 6 rows (3 + 3)', '6', $SOUTH_ROWS::VARCHAR
  UNION ALL SELECT 7, 'One key, many roles: east team sees EAST (3 rows)', 'EAST|3', $EAST_KEYS || '|' || $EAST_ROWS
  UNION ALL SELECT 8, 'SELECT granted but no mapping: zero rows', '0', $NOMAP_ROWS::VARCHAR
  UNION ALL SELECT 9, 'Access admin is exempt from the policy: sees all 12 rows', '12', $ADMIN_ROWS::VARCHAR
  UNION ALL SELECT 10, 'Auditor exemption sees all 12 rows, unassigned included', '12', $AUDITOR_ROWS::VARCHAR
  UNION ALL SELECT 11, 'A viewer cannot write to the mapping table', 'DENIED', $VIEWER_WRITE
  UNION ALL SELECT 12, 'Non-compliant file rejected whole, nothing applied',
         'Rejected request_02.csv: 6 of 7 rows failed validation, nothing applied', $ONBOARD_2
  UNION ALL SELECT 13, 'Rejected file left no trace: no WEST role, T-1001 still NORTH, 2 rows still unassigned',
         '0|NORTH|2', $WEST_ROLE_CREATED::VARCHAR || '|' || $STATE_AFTER_REJECT
  UNION ALL SELECT 14, 'Each failing row logged with its reason',
         'Mapping key breaks the key format|Record ID not found in the data|Record listed with more than one key|Record listed with more than one key|Role name breaks the naming convention|Role name breaks the naming convention',
         (SELECT LISTAGG(REASON, '|') WITHIN GROUP (ORDER BY REASON) FROM RAP_DEMO.GOVERNANCE.ACCESS_REJECTIONS
          WHERE SOURCE_FILE = 'request_02.csv')
  UNION ALL SELECT 15, 'Consumers cannot read the pipeline team''s table directly', 'DENIED', $NOMAP_SOURCE
  UNION ALL SELECT 16, 'SYSADMIN inherits viewer roles: sees mapped keys, not unassigned rows', 'EAST,NORTH,SOUTH', $SYSADMIN_KEYS
  UNION ALL SELECT 17, 'Empty source (half-built rebuild): refresh refused',
         'Refused: source is empty, governed copy left unchanged', $REFUSED
  UNION ALL SELECT 18, 'Governed copy intact after the refused refresh', '12', $COPY_AFTER_REFUSE::VARCHAR
  UNION ALL SELECT 19, 'Pipeline CREATE OR REPLACE did not touch assignments or the policy', '4', $NORTH_ROWS_BEFORE_REFRESH::VARCHAR
  UNION ALL SELECT 20, 'Refresh merges the rebuilt source', 'Refreshed: 1 new, 1 changed, 1 removed, 0 restored', $REFRESH_2
  UNION ALL SELECT 21, 'After refresh: assignments kept, changed data applied, new row invisible until assigned',
         '4|Reopened', $NORTH_ROWS_REFRESHED::VARCHAR || '|' || $NORTH_T1001
  UNION ALL SELECT 22, 'A row removed from the source is hidden from viewers (south 6 to 5)', '5', $SOUTH_ROWS_REFRESHED::VARCHAR
  UNION ALL SELECT 23, 'New row assigned from CSV, visible to north',
         'Assigned 1 records, onboarded 0 mappings, created 0 roles from request_03.csv|5',
         $ONBOARD_3 || '|' || $NORTH_ROWS_ASSIGNED
  UNION ALL SELECT 24, 'Soft delete: the removed row is kept with its key, only hidden', 'SOUTH|removed', $REMOVED_STATE
  UNION ALL SELECT 25, 'Record returns to the source: restored with its key, no CSV needed',
         'Refreshed: 0 new, 0 changed, 0 removed, 1 restored|6', $REFRESH_3 || '|' || $SOUTH_ROWS_RESTORED
  UNION ALL SELECT 26, 'Bulk offboard applied', 'Offboarded 1 mappings from offboard_01.csv', $OFFBOARD_1
  UNION ALL SELECT 27, 'Offboard file naming a non-existent mapping rejected whole',
         'Rejected offboard_02.csv: 1 of 2 rows failed validation, nothing removed', $OFFBOARD_2
  UNION ALL SELECT 28, 'Rejected offboard file left the valid mapping in place', '1',
         (SELECT COUNT(*) FROM RAP_DEMO.GOVERNANCE.ACCESS_MAPPING WHERE MAPPING_KEY = 'EAST' AND ROLE_NAME = 'RAP_DEMO_EAST_TEAM')::VARCHAR
  UNION ALL SELECT 29, 'Offboarding EAST from south team takes effect immediately', 'SOUTH', $SOUTH_KEYS_AFTER
  UNION ALL SELECT 30, 'The other role sharing EAST keeps it', 'EAST', $EAST_KEYS_AFTER
  UNION ALL SELECT 31, 'Single offboard dropped the unused north role', 'Removed 1 mapping; role dropped|0',
         $OFFBOARD_SINGLE || '|' || $NORTH_ROLE_LEFT::VARCHAR
  UNION ALL SELECT 32, 'Offboarding never deletes data: the 5 NORTH rows remain', '5', $NORTH_ROWS_KEPT::VARCHAR
  UNION ALL SELECT 33, 'Every grant, revoke, assignment and refresh is audited', '4|2|11|4',
         (SELECT COUNT_IF(ACTION = 'GRANT') || '|' || COUNT_IF(ACTION = 'REVOKE') || '|' ||
                 COUNT_IF(ACTION = 'ASSIGN') || '|' || COUNT_IF(ACTION = 'REFRESH')
          FROM RAP_DEMO.GOVERNANCE.ACCESS_AUDIT)
  UNION ALL SELECT 34, 'Injection attempt only logged; source table intact', '1|13',
         (SELECT COUNT(*) FROM RAP_DEMO.GOVERNANCE.ACCESS_REJECTIONS WHERE ROLE_NAME LIKE 'X;%')::VARCHAR
         || '|' || (SELECT COUNT(*) FROM RAP_DEMO.SOURCE.SERVICE_TICKETS)::VARCHAR
)
SELECT n, claim, expected, actual, IFF(EQUAL_NULL(expected, actual), 'PASS', 'FAIL') AS result
FROM checks
ORDER BY n;
