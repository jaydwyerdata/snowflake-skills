-- Worked example B, step 4 of 4: one row per claim, PASS or FAIL. Run straight after step 3, in the
-- same session (the results live in session variables). Every row should say PASS.

USE ROLE RAP_KEYED_ADMIN;
USE SECONDARY ROLES NONE;

WITH checks AS (
  SELECT 1 AS n, 'Clean file onboarded: 4 mappings, 3 roles' AS claim,
         'Onboarded 4 mappings, created 3 roles from request_01.csv' AS expected, $ONBOARD_1 AS actual
  UNION ALL SELECT 2, 'Re-running the same file adds nothing',
         'Onboarded 0 mappings, created 0 roles from request_01.csv', $ONBOARD_RERUN
  UNION ALL SELECT 3, 'North team sees only NORTH, all 4 rows', 'NORTH|4', $NORTH_KEYS || '|' || $NORTH_ROWS
  UNION ALL SELECT 4, 'One role, many keys: south team sees EAST and SOUTH, 6 rows', 'EAST,SOUTH|6', $SOUTH_KEYS || '|' || $SOUTH_ROWS
  UNION ALL SELECT 5, 'One key, many roles: east team sees EAST (3 rows)', 'EAST|3', $EAST_KEYS || '|' || $EAST_ROWS
  UNION ALL SELECT 6, 'SELECT granted but no mapping: zero rows', '0', $NOMAP_ROWS::VARCHAR
  UNION ALL SELECT 7, 'Access admin is exempt from the policy: sees all 12 rows', '12', $ADMIN_ROWS::VARCHAR
  UNION ALL SELECT 8, 'Auditor exemption sees all 12 rows, unmapped WEST included', '12', $AUDITOR_ROWS::VARCHAR
  UNION ALL SELECT 9, 'A viewer cannot write to the mapping table', 'DENIED', $VIEWER_WRITE
  UNION ALL SELECT 10, 'Non-compliant file rejected whole, nothing applied',
         'Rejected request_02.csv: 4 of 5 rows failed validation, nothing applied', $ONBOARD_2
  UNION ALL SELECT 11, 'Rejected file left no trace: no WEST role, no WEST mapping', '0|0',
         $WEST_ROLE_CREATED::VARCHAR || '|' || $WEST_MAPPINGS::VARCHAR
  UNION ALL SELECT 12, 'Each failing row logged with its reason',
         'Mapping key breaks the key format|Mapping key not found in the data|Role name breaks the naming convention|Role name breaks the naming convention',
         (SELECT LISTAGG(REASON, '|') WITHIN GROUP (ORDER BY REASON) FROM RAP_KEYED.GOVERNANCE.ACCESS_REJECTIONS
          WHERE SOURCE_FILE = 'request_02.csv')
  UNION ALL SELECT 13, 'Consumers cannot read the pipeline team''s table directly', 'DENIED', $NOMAP_SOURCE
  UNION ALL SELECT 14, 'SYSADMIN inherits viewer roles: sees mapped keys, not WEST', 'EAST,NORTH,SOUTH', $SYSADMIN_KEYS
  UNION ALL SELECT 15, 'Empty source (half-built rebuild): refresh refused',
         'Refused: source is empty, governed copy left unchanged', $REFUSED
  UNION ALL SELECT 16, 'Governed copy intact after the refused refresh', '12', $COPY_AFTER_REFUSE::VARCHAR
  UNION ALL SELECT 17, 'Pipeline CREATE OR REPLACE did not touch the policy or the mapping', '4', $NORTH_ROWS_BEFORE_REFRESH::VARCHAR
  UNION ALL SELECT 18, 'Refresh follows the source, including a key change',
         'Refreshed: 1 new, 2 changed, 1 removed, 0 restored', $REFRESH_2
  UNION ALL SELECT 19, 'New row and moved row visible to north at once, no CSV; changed data applied',
         '6|Reopened', $NORTH_ROWS_REFRESHED::VARCHAR || '|' || $NORTH_T1001
  UNION ALL SELECT 20, 'A row removed from the source is hidden from viewers (south 6 to 5)', '5', $SOUTH_ROWS_REFRESHED::VARCHAR
  UNION ALL SELECT 21, 'Soft delete: the removed row is kept, only hidden', 'SOUTH|removed', $REMOVED_STATE
  UNION ALL SELECT 22, 'Record returns to the source: visible again, no CSV needed',
         'Refreshed: 0 new, 0 changed, 0 removed, 1 restored|6', $REFRESH_3 || '|' || $SOUTH_ROWS_RESTORED
  UNION ALL SELECT 23, 'Bulk offboard applied', 'Offboarded 1 mappings from offboard_01.csv', $OFFBOARD_1
  UNION ALL SELECT 24, 'Offboard file naming a non-existent mapping rejected whole',
         'Rejected offboard_02.csv: 1 of 2 rows failed validation, nothing removed', $OFFBOARD_2
  UNION ALL SELECT 25, 'Rejected offboard file left the valid mapping in place', '1',
         (SELECT COUNT(*) FROM RAP_KEYED.GOVERNANCE.ACCESS_MAPPING WHERE MAPPING_KEY = 'EAST' AND ROLE_NAME = 'RAP_KEYED_EAST_TEAM')::VARCHAR
  UNION ALL SELECT 26, 'Offboarding EAST from south team takes effect immediately', 'SOUTH', $SOUTH_KEYS_AFTER
  UNION ALL SELECT 27, 'The other role sharing EAST keeps it', 'EAST', $EAST_KEYS_AFTER
  UNION ALL SELECT 28, 'Single offboard dropped the unused north role', 'Removed 1 mapping; role dropped|0',
         $OFFBOARD_SINGLE || '|' || $NORTH_ROLE_LEFT::VARCHAR
  UNION ALL SELECT 29, 'Offboarding never deletes data: the 6 NORTH rows remain', '6', $NORTH_ROWS_KEPT::VARCHAR
  UNION ALL SELECT 30, 'Every grant, revoke and refresh is audited', '4|2|4',
         (SELECT COUNT_IF(ACTION = 'GRANT') || '|' || COUNT_IF(ACTION = 'REVOKE') || '|' || COUNT_IF(ACTION = 'REFRESH')
          FROM RAP_KEYED.GOVERNANCE.ACCESS_AUDIT)
  UNION ALL SELECT 31, 'Injection attempt only logged; source table intact', '1|13',
         (SELECT COUNT(*) FROM RAP_KEYED.GOVERNANCE.ACCESS_REJECTIONS WHERE ROLE_NAME LIKE 'X;%')::VARCHAR
         || '|' || (SELECT COUNT(*) FROM RAP_KEYED.SOURCE.SERVICE_TICKETS)::VARCHAR
)
SELECT n, claim, expected, actual, IFF(EQUAL_NULL(expected, actual), 'PASS', 'FAIL') AS result
FROM checks
ORDER BY n;
