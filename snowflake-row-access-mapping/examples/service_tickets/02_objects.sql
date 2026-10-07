-- Worked example, step 2 of 4: the object set the skill generates.
-- Source (owned by another team): RAP_DEMO.SOURCE.SERVICE_TICKETS, record ID TICKET_ID.
-- Governed copy (owned here, protected): RAP_DEMO.SHARED.SERVICE_TICKETS, mapping key MAPPING_KEY.
-- Optional bypass role: RAP_DEMO_AUDITOR (sees every row, assigned or not).

USE ROLE RAP_DEMO_ADMIN;
USE SECONDARY ROLES NONE;
USE WAREHOUSE RAP_DEMO_WH;

---------------------------------------------------------------------------------------------------
-- The governed copy. The source's columns, plus the mapping key, which only the access procedures
-- ever set. The pipeline team can rebuild their table freely: this copy, its assignments and its
-- policy are owned here and are never replaced, only merged into. The source is only ever read.
-- Records that leave the source are soft-deleted (REMOVED_AT), never physically deleted, so their
-- assignment survives a partial rebuild and is restored if the record comes back.
---------------------------------------------------------------------------------------------------

CREATE OR REPLACE TABLE RAP_DEMO.SHARED.SERVICE_TICKETS (
  TICKET_ID    VARCHAR NOT NULL,
  OPENED_ON    DATE,
  CATEGORY     VARCHAR,
  STATUS       VARCHAR,
  MAPPING_KEY  VARCHAR,          -- NULL until assigned: unassigned rows are visible to no one
  ASSIGNED_AT  TIMESTAMP_TZ,
  REFRESHED_AT TIMESTAMP_TZ,
  REMOVED_AT   TIMESTAMP_TZ      -- soft delete: set when the record leaves the source, cleared if it returns
);

---------------------------------------------------------------------------------------------------
-- Governance tables.
---------------------------------------------------------------------------------------------------

CREATE OR REPLACE TABLE RAP_DEMO.GOVERNANCE.ACCESS_MAPPING (
  MAPPING_KEY VARCHAR NOT NULL,
  ROLE_NAME   VARCHAR NOT NULL,
  GRANTED_AT  TIMESTAMP_TZ,
  GRANTED_BY  VARCHAR,
  SOURCE_FILE VARCHAR
);

CREATE OR REPLACE TABLE RAP_DEMO.GOVERNANCE.ACCESS_AUDIT (
  EVENT_AT    TIMESTAMP_TZ,
  ACTION      VARCHAR,       -- ASSIGN, GRANT, REVOKE, ROLE_CREATED, ROLE_DROPPED, REFRESH, FILE_REJECTED
  MAPPING_KEY VARCHAR,
  ROLE_NAME   VARCHAR,
  ACTOR       VARCHAR,
  DETAIL      VARCHAR
);

CREATE OR REPLACE TABLE RAP_DEMO.GOVERNANCE.ACCESS_REJECTIONS (
  REJECTED_AT TIMESTAMP_TZ,
  SOURCE_FILE VARCHAR,
  FILE_ROW    INTEGER,
  RECORD_ID   VARCHAR,
  MAPPING_KEY VARCHAR,
  ROLE_NAME   VARCHAR,
  REASON      VARCHAR,
  ACTOR       VARCHAR
);

-- Validation rules, set when the pattern is instantiated. Both are regular expressions.
CREATE OR REPLACE TABLE RAP_DEMO.GOVERNANCE.ACCESS_CONFIG (SETTING VARCHAR, VALUE VARCHAR);
INSERT INTO RAP_DEMO.GOVERNANCE.ACCESS_CONFIG VALUES
  ('KEY_PATTERN',  '^[A-Z0-9]+(_[A-Z0-9]+)*$'),
  ('ROLE_PATTERN', '^RAP_DEMO_[A-Z0-9]+(_[A-Z0-9]+)*_TEAM$');

---------------------------------------------------------------------------------------------------
-- The row access policy. IS_ROLE_IN_SESSION (not CURRENT_ROLE) so role inheritance is respected.
-- Default deny: no mapping, no rows. The argument is deliberately not called MAPPING_KEY: inside
-- the subquery that name would resolve to the mapping table's own column, and the comparison would
-- always be true. Soft-deleted rows (REMOVED) are hidden from every viewer.
-- The access admin role is exempt on purpose: a row access policy also filters UPDATE and MERGE,
-- so without it the procedures could neither refresh nor assign rows they cannot see.
---------------------------------------------------------------------------------------------------

CREATE OR REPLACE ROW ACCESS POLICY RAP_DEMO.GOVERNANCE.RAP_SERVICE_TICKETS
AS (KEY_VALUE VARCHAR, REMOVED TIMESTAMP_TZ) RETURNS BOOLEAN ->
  IS_ROLE_IN_SESSION('RAP_DEMO_ADMIN')
  OR IS_ROLE_IN_SESSION('RAP_DEMO_AUDITOR')
  OR (REMOVED IS NULL AND EXISTS (
    SELECT 1 FROM RAP_DEMO.GOVERNANCE.ACCESS_MAPPING m
    WHERE m.MAPPING_KEY = KEY_VALUE
      AND IS_ROLE_IN_SESSION(m.ROLE_NAME)
  ));

ALTER TABLE RAP_DEMO.SHARED.SERVICE_TICKETS
  ADD ROW ACCESS POLICY RAP_DEMO.GOVERNANCE.RAP_SERVICE_TICKETS ON (MAPPING_KEY, REMOVED_AT);

---------------------------------------------------------------------------------------------------
-- SP_REFRESH_FROM_SOURCE(): merge the pipeline team's latest table into the governed copy on the
-- record ID. New rows arrive unassigned; changed rows get their data updated but never their key;
-- rows gone from the source are soft-deleted (key kept); rows that return are restored with their key
-- intact. The source table is only read, never changed. Refuses to run against an empty source, so a half-built
-- rebuild cannot wipe the copy.
---------------------------------------------------------------------------------------------------

CREATE OR REPLACE PROCEDURE RAP_DEMO.GOVERNANCE.SP_REFRESH_FROM_SOURCE()
RETURNS VARCHAR
LANGUAGE SQL
EXECUTE AS OWNER
AS
$$
DECLARE
  n_source  INTEGER DEFAULT 0;
  n_new     INTEGER DEFAULT 0;
  n_changed INTEGER DEFAULT 0;
  n_removed INTEGER DEFAULT 0;
  n_restored INTEGER DEFAULT 0;
  msg VARCHAR;
BEGIN
  SELECT COUNT(*) INTO :n_source FROM RAP_DEMO.SOURCE.SERVICE_TICKETS;
  IF (n_source = 0) THEN
    INSERT INTO RAP_DEMO.GOVERNANCE.ACCESS_AUDIT
    SELECT CURRENT_TIMESTAMP(), 'REFRESH', NULL, NULL, CURRENT_USER(), 'Refused: source is empty';
    RETURN 'Refused: source is empty, governed copy left unchanged';
  END IF;

  SELECT COUNT(*) INTO :n_new FROM RAP_DEMO.SOURCE.SERVICE_TICKETS s
  WHERE NOT EXISTS (SELECT 1 FROM RAP_DEMO.SHARED.SERVICE_TICKETS t WHERE t.TICKET_ID = s.TICKET_ID);
  SELECT COUNT(*) INTO :n_changed FROM RAP_DEMO.SOURCE.SERVICE_TICKETS s
  JOIN RAP_DEMO.SHARED.SERVICE_TICKETS t ON t.TICKET_ID = s.TICKET_ID
  WHERE NOT (EQUAL_NULL(t.OPENED_ON, s.OPENED_ON) AND EQUAL_NULL(t.CATEGORY, s.CATEGORY) AND EQUAL_NULL(t.STATUS, s.STATUS));
  SELECT COUNT(*) INTO :n_removed FROM RAP_DEMO.SHARED.SERVICE_TICKETS t
  WHERE t.REMOVED_AT IS NULL
    AND NOT EXISTS (SELECT 1 FROM RAP_DEMO.SOURCE.SERVICE_TICKETS s WHERE s.TICKET_ID = t.TICKET_ID);
  SELECT COUNT(*) INTO :n_restored FROM RAP_DEMO.SOURCE.SERVICE_TICKETS s
  JOIN RAP_DEMO.SHARED.SERVICE_TICKETS t ON t.TICKET_ID = s.TICKET_ID
  WHERE t.REMOVED_AT IS NOT NULL;

  BEGIN TRANSACTION;

  MERGE INTO RAP_DEMO.SHARED.SERVICE_TICKETS t
  USING RAP_DEMO.SOURCE.SERVICE_TICKETS s ON t.TICKET_ID = s.TICKET_ID
  WHEN MATCHED AND (t.REMOVED_AT IS NOT NULL
                    OR NOT (EQUAL_NULL(t.OPENED_ON, s.OPENED_ON) AND EQUAL_NULL(t.CATEGORY, s.CATEGORY)
                            AND EQUAL_NULL(t.STATUS, s.STATUS))) THEN UPDATE SET
    OPENED_ON = s.OPENED_ON, CATEGORY = s.CATEGORY, STATUS = s.STATUS, REFRESHED_AT = CURRENT_TIMESTAMP(),
    REMOVED_AT = NULL
  WHEN NOT MATCHED THEN INSERT (TICKET_ID, OPENED_ON, CATEGORY, STATUS, MAPPING_KEY, ASSIGNED_AT, REFRESHED_AT)
    VALUES (s.TICKET_ID, s.OPENED_ON, s.CATEGORY, s.STATUS, NULL, NULL, CURRENT_TIMESTAMP());

  -- Soft delete: keep the row and its key, stamp it, and the policy hides it.
  UPDATE RAP_DEMO.SHARED.SERVICE_TICKETS t
  SET REMOVED_AT = CURRENT_TIMESTAMP(), REFRESHED_AT = CURRENT_TIMESTAMP()
  WHERE t.REMOVED_AT IS NULL
    AND NOT EXISTS (SELECT 1 FROM RAP_DEMO.SOURCE.SERVICE_TICKETS s WHERE s.TICKET_ID = t.TICKET_ID);

  msg := 'Refreshed: ' || n_new || ' new, ' || n_changed || ' changed, ' || n_removed || ' removed, '
         || n_restored || ' restored';
  INSERT INTO RAP_DEMO.GOVERNANCE.ACCESS_AUDIT
  SELECT CURRENT_TIMESTAMP(), 'REFRESH', NULL, NULL, CURRENT_USER(), :msg;

  COMMIT;
  RETURN msg;
EXCEPTION
  WHEN OTHER THEN
    ROLLBACK;
    RAISE;
END;
$$;

-- Scheduled refresh, owned by the access team. Created suspended in the example; in production,
-- resume it, schedule it after the pipeline team's load, and run it on demand when urgent:
--   EXECUTE TASK RAP_DEMO.GOVERNANCE.TSK_REFRESH_SERVICE_TICKETS;
CREATE OR REPLACE TASK RAP_DEMO.GOVERNANCE.TSK_REFRESH_SERVICE_TICKETS
  WAREHOUSE = RAP_DEMO_WH
  SCHEDULE = 'USING CRON 0 6 * * * Australia/Sydney'
AS CALL RAP_DEMO.GOVERNANCE.SP_REFRESH_FROM_SOURCE();

---------------------------------------------------------------------------------------------------
-- Onboarding input: a three-column CSV (RECORD_ID, MAPPING_KEY, ROLE_NAME) uploaded to this stage.
-- RECORD_ID may be blank to grant a role an existing key without assigning any rows.
---------------------------------------------------------------------------------------------------

CREATE OR REPLACE FILE FORMAT RAP_DEMO.GOVERNANCE.FF_ACCESS_CSV
  TYPE = CSV SKIP_HEADER = 1 FIELD_OPTIONALLY_ENCLOSED_BY = '"' TRIM_SPACE = TRUE;

CREATE OR REPLACE STAGE RAP_DEMO.GOVERNANCE.ACCESS_REQUESTS
  FILE_FORMAT = RAP_DEMO.GOVERNANCE.FF_ACCESS_CSV;

---------------------------------------------------------------------------------------------------
-- SP_ONBOARD_ACCESS(file): validate the whole file first. If any row breaks a rule, reject the
-- file, log each failing row to ACCESS_REJECTIONS and apply nothing. Otherwise: assign each listed
-- record its mapping key in the governed copy, then for each distinct (key, role) create the role if
-- needed, grant it read access to the governed copy, and add the mapping. Assigning roles to users
-- is deliberately out of scope.
---------------------------------------------------------------------------------------------------

CREATE OR REPLACE PROCEDURE RAP_DEMO.GOVERNANCE.SP_ONBOARD_ACCESS(P_FILE VARCHAR)
RETURNS VARCHAR
LANGUAGE SQL
EXECUTE AS OWNER
AS
$$
DECLARE
  key_pattern  VARCHAR;
  role_pattern VARCHAR;
  n_rows     INTEGER DEFAULT 0;
  n_bad      INTEGER DEFAULT 0;
  n_assigned INTEGER DEFAULT 0;
  n_granted  INTEGER DEFAULT 0;
  n_roles    INTEGER DEFAULT 0;
  k VARCHAR;
  r VARCHAR;
  role_seen INTEGER;
  already   INTEGER;
  c1 CURSOR FOR SELECT DISTINCT MAPPING_KEY, ROLE_NAME FROM RAP_DEMO.GOVERNANCE.TMP_ACCESS_REQUEST;
BEGIN
  SELECT MAX(IFF(SETTING = 'KEY_PATTERN', VALUE, NULL)), MAX(IFF(SETTING = 'ROLE_PATTERN', VALUE, NULL))
    INTO :key_pattern, :role_pattern
  FROM RAP_DEMO.GOVERNANCE.ACCESS_CONFIG;

  -- Read the file exactly as given: no upper-casing, so a format breach is caught, not hidden.
  EXECUTE IMMEDIATE
    'CREATE OR REPLACE TEMPORARY TABLE RAP_DEMO.GOVERNANCE.TMP_ACCESS_REQUEST AS ' ||
    'SELECT METADATA$FILE_ROW_NUMBER AS FILE_ROW, NULLIF(TRIM($1::VARCHAR), '''') AS RECORD_ID, ' ||
    'TRIM($2::VARCHAR) AS MAPPING_KEY, TRIM($3::VARCHAR) AS ROLE_NAME, $4::VARCHAR AS EXTRA_COLUMN ' ||
    'FROM @RAP_DEMO.GOVERNANCE.ACCESS_REQUESTS/' || P_FILE ||
    ' (FILE_FORMAT => ''RAP_DEMO.GOVERNANCE.FF_ACCESS_CSV'')';

  SELECT COUNT(*) INTO :n_rows FROM RAP_DEMO.GOVERNANCE.TMP_ACCESS_REQUEST;
  IF (n_rows = 0) THEN
    INSERT INTO RAP_DEMO.GOVERNANCE.ACCESS_REJECTIONS
    SELECT CURRENT_TIMESTAMP(), :P_FILE, NULL, NULL, NULL, NULL, 'File has no data rows', CURRENT_USER();
    INSERT INTO RAP_DEMO.GOVERNANCE.ACCESS_AUDIT
    SELECT CURRENT_TIMESTAMP(), 'FILE_REJECTED', NULL, NULL, CURRENT_USER(), :P_FILE || ': empty';
    RETURN 'Rejected ' || P_FILE || ': no data rows, nothing applied';
  END IF;

  -- Facts each rule needs, computed once per row.
  CREATE OR REPLACE TEMPORARY TABLE RAP_DEMO.GOVERNANCE.TMP_ACCESS_CHECK AS
  SELECT t.*,
         (t.RECORD_ID IS NOT NULL AND d.TICKET_ID IS NULL) AS RECORD_MISSING,
         (t.RECORD_ID IS NOT NULL AND kc.N_KEYS > 1)       AS RECORD_CONFLICT,
         (t.RECORD_ID IS NULL AND ek.MAPPING_KEY IS NULL AND fk.MAPPING_KEY IS NULL) AS KEY_UNUSED
  FROM RAP_DEMO.GOVERNANCE.TMP_ACCESS_REQUEST t
  LEFT JOIN (SELECT TICKET_ID FROM RAP_DEMO.SHARED.SERVICE_TICKETS WHERE REMOVED_AT IS NULL) d ON d.TICKET_ID = t.RECORD_ID
  LEFT JOIN (SELECT RECORD_ID, COUNT(DISTINCT MAPPING_KEY) AS N_KEYS
             FROM RAP_DEMO.GOVERNANCE.TMP_ACCESS_REQUEST WHERE RECORD_ID IS NOT NULL GROUP BY RECORD_ID) kc
         ON kc.RECORD_ID = t.RECORD_ID
  LEFT JOIN (SELECT DISTINCT MAPPING_KEY FROM RAP_DEMO.SHARED.SERVICE_TICKETS WHERE MAPPING_KEY IS NOT NULL AND REMOVED_AT IS NULL) ek
         ON ek.MAPPING_KEY = t.MAPPING_KEY
  LEFT JOIN (SELECT DISTINCT MAPPING_KEY FROM RAP_DEMO.GOVERNANCE.TMP_ACCESS_REQUEST WHERE RECORD_ID IS NOT NULL) fk
         ON fk.MAPPING_KEY = t.MAPPING_KEY;

  -- Every rule, first failure per row reported.
  INSERT INTO RAP_DEMO.GOVERNANCE.ACCESS_REJECTIONS
  SELECT CURRENT_TIMESTAMP(), :P_FILE, c.FILE_ROW, c.RECORD_ID, c.MAPPING_KEY, c.ROLE_NAME,
         CASE
           WHEN c.EXTRA_COLUMN IS NOT NULL THEN 'More than three columns'
           WHEN c.MAPPING_KEY IS NULL OR c.MAPPING_KEY = '' THEN 'Missing mapping key'
           WHEN NOT REGEXP_LIKE(c.MAPPING_KEY, :key_pattern) THEN 'Mapping key breaks the key format'
           WHEN c.ROLE_NAME IS NULL OR c.ROLE_NAME = '' THEN 'Missing role name'
           WHEN NOT REGEXP_LIKE(c.ROLE_NAME, :role_pattern) THEN 'Role name breaks the naming convention'
           WHEN c.RECORD_MISSING THEN 'Record ID not found in the data'
           WHEN c.RECORD_CONFLICT THEN 'Record listed with more than one key'
           ELSE 'Key granted without records, but no record has that key'
         END,
         CURRENT_USER()
  FROM RAP_DEMO.GOVERNANCE.TMP_ACCESS_CHECK c
  WHERE c.EXTRA_COLUMN IS NOT NULL
     OR c.MAPPING_KEY IS NULL OR c.MAPPING_KEY = '' OR NOT REGEXP_LIKE(c.MAPPING_KEY, :key_pattern)
     OR c.ROLE_NAME IS NULL OR c.ROLE_NAME = '' OR NOT REGEXP_LIKE(c.ROLE_NAME, :role_pattern)
     OR c.RECORD_MISSING OR c.RECORD_CONFLICT OR c.KEY_UNUSED;
  n_bad := SQLROWCOUNT;

  IF (n_bad > 0) THEN
    INSERT INTO RAP_DEMO.GOVERNANCE.ACCESS_AUDIT
    SELECT CURRENT_TIMESTAMP(), 'FILE_REJECTED', NULL, NULL, CURRENT_USER(),
           :P_FILE || ': ' || :n_bad || ' of ' || :n_rows || ' rows failed validation';
    RETURN 'Rejected ' || P_FILE || ': ' || n_bad || ' of ' || n_rows || ' rows failed validation, nothing applied';
  END IF;

  BEGIN TRANSACTION;

  -- 1. Assign records their key. Only rows whose key actually changes are touched and counted.
  CREATE OR REPLACE TEMPORARY TABLE RAP_DEMO.GOVERNANCE.TMP_ACCESS_ASSIGN AS
  SELECT a.RECORD_ID, a.MAPPING_KEY, d.MAPPING_KEY AS OLD_KEY
  FROM (SELECT DISTINCT RECORD_ID, MAPPING_KEY FROM RAP_DEMO.GOVERNANCE.TMP_ACCESS_REQUEST WHERE RECORD_ID IS NOT NULL) a
  JOIN RAP_DEMO.SHARED.SERVICE_TICKETS d ON d.TICKET_ID = a.RECORD_ID AND d.REMOVED_AT IS NULL
  WHERE NOT EQUAL_NULL(d.MAPPING_KEY, a.MAPPING_KEY);

  SELECT COUNT(*) INTO :n_assigned FROM RAP_DEMO.GOVERNANCE.TMP_ACCESS_ASSIGN;

  INSERT INTO RAP_DEMO.GOVERNANCE.ACCESS_AUDIT
  SELECT CURRENT_TIMESTAMP(), 'ASSIGN', MAPPING_KEY, NULL, CURRENT_USER(),
         RECORD_ID || ' from ' || COALESCE(OLD_KEY, 'unassigned') || ' (' || :P_FILE || ')'
  FROM RAP_DEMO.GOVERNANCE.TMP_ACCESS_ASSIGN;

  MERGE INTO RAP_DEMO.SHARED.SERVICE_TICKETS d
  USING RAP_DEMO.GOVERNANCE.TMP_ACCESS_ASSIGN a ON d.TICKET_ID = a.RECORD_ID
  WHEN MATCHED THEN UPDATE SET MAPPING_KEY = a.MAPPING_KEY, ASSIGNED_AT = CURRENT_TIMESTAMP();

  -- 2. Grant each (key, role). Role names are safe in dynamic SQL: they matched the convention.
  FOR rec IN c1 DO
    k := rec.MAPPING_KEY;
    r := rec.ROLE_NAME;

    SELECT COUNT(*) INTO :role_seen FROM RAP_DEMO.GOVERNANCE.ACCESS_AUDIT
    WHERE ACTION = 'ROLE_CREATED' AND ROLE_NAME = :r
      AND EVENT_AT > COALESCE((SELECT MAX(EVENT_AT) FROM RAP_DEMO.GOVERNANCE.ACCESS_AUDIT
                               WHERE ACTION = 'ROLE_DROPPED' AND ROLE_NAME = :r), '1900-01-01'::TIMESTAMP_TZ);
    EXECUTE IMMEDIATE 'CREATE ROLE IF NOT EXISTS ' || r;
    EXECUTE IMMEDIATE 'GRANT USAGE ON DATABASE RAP_DEMO TO ROLE ' || r;
    EXECUTE IMMEDIATE 'GRANT USAGE ON SCHEMA RAP_DEMO.SHARED TO ROLE ' || r;
    EXECUTE IMMEDIATE 'GRANT SELECT ON TABLE RAP_DEMO.SHARED.SERVICE_TICKETS TO ROLE ' || r;
    -- Standard practice: custom roles roll up to SYSADMIN. Consequence, by design and tested:
    -- anyone using SYSADMIN (or ACCOUNTADMIN) inherits every viewer role and sees all mapped rows.
    EXECUTE IMMEDIATE 'GRANT ROLE ' || r || ' TO ROLE SYSADMIN';
    IF (role_seen = 0) THEN
      INSERT INTO RAP_DEMO.GOVERNANCE.ACCESS_AUDIT
      SELECT CURRENT_TIMESTAMP(), 'ROLE_CREATED', NULL, :r, CURRENT_USER(), 'Created if absent, granted read on the governed copy';
      n_roles := n_roles + 1;
    END IF;

    SELECT COUNT(*) INTO :already FROM RAP_DEMO.GOVERNANCE.ACCESS_MAPPING
    WHERE MAPPING_KEY = :k AND ROLE_NAME = :r;
    IF (already = 0) THEN
      INSERT INTO RAP_DEMO.GOVERNANCE.ACCESS_MAPPING
      SELECT :k, :r, CURRENT_TIMESTAMP(), CURRENT_USER(), :P_FILE;
      INSERT INTO RAP_DEMO.GOVERNANCE.ACCESS_AUDIT
      SELECT CURRENT_TIMESTAMP(), 'GRANT', :k, :r, CURRENT_USER(), 'From ' || :P_FILE;
      n_granted := n_granted + 1;
    END IF;
  END FOR;

  COMMIT;
  RETURN 'Assigned ' || n_assigned || ' records, onboarded ' || n_granted || ' mappings, created '
         || n_roles || ' roles from ' || P_FILE;
EXCEPTION
  WHEN OTHER THEN
    ROLLBACK;
    RAISE;
END;
$$;

---------------------------------------------------------------------------------------------------
-- SP_OFFBOARD_ACCESS(key, role, drop_role_if_unused): remove one mapping; access ends immediately.
-- If the role maps to nothing afterwards, revoke its read grant, and optionally drop it.
-- Assignments are kept: rows stay labelled with their key, just visible to fewer roles.
---------------------------------------------------------------------------------------------------

CREATE OR REPLACE PROCEDURE RAP_DEMO.GOVERNANCE.SP_OFFBOARD_ACCESS(
  P_KEY VARCHAR, P_ROLE VARCHAR, P_DROP_ROLE_IF_UNUSED BOOLEAN)
RETURNS VARCHAR
LANGUAGE SQL
EXECUTE AS OWNER
AS
$$
DECLARE
  k VARCHAR;
  r VARCHAR;
  role_pattern VARCHAR;
  removed   INTEGER DEFAULT 0;
  remaining INTEGER DEFAULT 0;
  outcome   VARCHAR;
BEGIN
  k := TRIM(P_KEY);
  r := TRIM(P_ROLE);
  SELECT MAX(VALUE) INTO :role_pattern FROM RAP_DEMO.GOVERNANCE.ACCESS_CONFIG WHERE SETTING = 'ROLE_PATTERN';
  IF (r IS NULL OR NOT REGEXP_LIKE(r, role_pattern)) THEN
    RETURN 'Rejected: role name breaks the naming convention';
  END IF;

  DELETE FROM RAP_DEMO.GOVERNANCE.ACCESS_MAPPING WHERE MAPPING_KEY = :k AND ROLE_NAME = :r;
  removed := SQLROWCOUNT;
  IF (removed > 0) THEN
    INSERT INTO RAP_DEMO.GOVERNANCE.ACCESS_AUDIT
    SELECT CURRENT_TIMESTAMP(), 'REVOKE', :k, :r, CURRENT_USER(), 'Mapping removed';
  END IF;
  outcome := 'Removed ' || removed || ' mapping';

  SELECT COUNT(*) INTO :remaining FROM RAP_DEMO.GOVERNANCE.ACCESS_MAPPING WHERE ROLE_NAME = :r;
  IF (remaining = 0) THEN
    IF (P_DROP_ROLE_IF_UNUSED) THEN
      EXECUTE IMMEDIATE 'DROP ROLE IF EXISTS ' || r;
      INSERT INTO RAP_DEMO.GOVERNANCE.ACCESS_AUDIT
      SELECT CURRENT_TIMESTAMP(), 'ROLE_DROPPED', NULL, :r, CURRENT_USER(), 'No mappings left';
      outcome := outcome || '; role dropped';
    ELSE
      EXECUTE IMMEDIATE 'REVOKE SELECT ON TABLE RAP_DEMO.SHARED.SERVICE_TICKETS FROM ROLE ' || r;
      outcome := outcome || '; role kept, read grant revoked';
    END IF;
  END IF;

  RETURN outcome;
END;
$$;

---------------------------------------------------------------------------------------------------
-- SP_OFFBOARD_ACCESS_FILE(file, drop_unused_roles): bulk offboarding from a two-column CSV
-- (MAPPING_KEY, ROLE_NAME). Same rules: validate the whole file, reject it whole if any row fails
-- (including a mapping that does not exist), log failures. Otherwise remove each mapping through
-- SP_OFFBOARD_ACCESS, so single and bulk behave identically. Data is never deleted here.
---------------------------------------------------------------------------------------------------

CREATE OR REPLACE PROCEDURE RAP_DEMO.GOVERNANCE.SP_OFFBOARD_ACCESS_FILE(P_FILE VARCHAR, P_DROP_UNUSED_ROLES BOOLEAN)
RETURNS VARCHAR
LANGUAGE SQL
EXECUTE AS OWNER
AS
$$
DECLARE
  key_pattern  VARCHAR;
  role_pattern VARCHAR;
  n_rows    INTEGER DEFAULT 0;
  n_bad     INTEGER DEFAULT 0;
  n_removed INTEGER DEFAULT 0;
  k VARCHAR;
  r VARCHAR;
  c1 CURSOR FOR SELECT DISTINCT MAPPING_KEY, ROLE_NAME FROM RAP_DEMO.GOVERNANCE.TMP_ACCESS_REVOKE;
BEGIN
  SELECT MAX(IFF(SETTING = 'KEY_PATTERN', VALUE, NULL)), MAX(IFF(SETTING = 'ROLE_PATTERN', VALUE, NULL))
    INTO :key_pattern, :role_pattern
  FROM RAP_DEMO.GOVERNANCE.ACCESS_CONFIG;

  EXECUTE IMMEDIATE
    'CREATE OR REPLACE TEMPORARY TABLE RAP_DEMO.GOVERNANCE.TMP_ACCESS_REVOKE AS ' ||
    'SELECT METADATA$FILE_ROW_NUMBER AS FILE_ROW, TRIM($1::VARCHAR) AS MAPPING_KEY, ' ||
    'TRIM($2::VARCHAR) AS ROLE_NAME, $3::VARCHAR AS EXTRA_COLUMN ' ||
    'FROM @RAP_DEMO.GOVERNANCE.ACCESS_REQUESTS/' || P_FILE ||
    ' (FILE_FORMAT => ''RAP_DEMO.GOVERNANCE.FF_ACCESS_CSV'')';

  SELECT COUNT(*) INTO :n_rows FROM RAP_DEMO.GOVERNANCE.TMP_ACCESS_REVOKE;
  IF (n_rows = 0) THEN
    INSERT INTO RAP_DEMO.GOVERNANCE.ACCESS_REJECTIONS
    SELECT CURRENT_TIMESTAMP(), :P_FILE, NULL, NULL, NULL, NULL, 'File has no data rows', CURRENT_USER();
    INSERT INTO RAP_DEMO.GOVERNANCE.ACCESS_AUDIT
    SELECT CURRENT_TIMESTAMP(), 'FILE_REJECTED', NULL, NULL, CURRENT_USER(), :P_FILE || ': empty';
    RETURN 'Rejected ' || P_FILE || ': no data rows, nothing removed';
  END IF;

  INSERT INTO RAP_DEMO.GOVERNANCE.ACCESS_REJECTIONS
  SELECT CURRENT_TIMESTAMP(), :P_FILE, t.FILE_ROW, NULL, t.MAPPING_KEY, t.ROLE_NAME,
         CASE
           WHEN t.EXTRA_COLUMN IS NOT NULL THEN 'More than two columns'
           WHEN t.MAPPING_KEY IS NULL OR t.MAPPING_KEY = '' THEN 'Missing mapping key'
           WHEN NOT REGEXP_LIKE(t.MAPPING_KEY, :key_pattern) THEN 'Mapping key breaks the key format'
           WHEN t.ROLE_NAME IS NULL OR t.ROLE_NAME = '' THEN 'Missing role name'
           WHEN NOT REGEXP_LIKE(t.ROLE_NAME, :role_pattern) THEN 'Role name breaks the naming convention'
           ELSE 'No such mapping to remove'
         END,
         CURRENT_USER()
  FROM RAP_DEMO.GOVERNANCE.TMP_ACCESS_REVOKE t
  LEFT JOIN RAP_DEMO.GOVERNANCE.ACCESS_MAPPING m
         ON m.MAPPING_KEY = t.MAPPING_KEY AND m.ROLE_NAME = t.ROLE_NAME
  WHERE t.EXTRA_COLUMN IS NOT NULL
     OR t.MAPPING_KEY IS NULL OR t.MAPPING_KEY = '' OR NOT REGEXP_LIKE(t.MAPPING_KEY, :key_pattern)
     OR t.ROLE_NAME IS NULL OR t.ROLE_NAME = '' OR NOT REGEXP_LIKE(t.ROLE_NAME, :role_pattern)
     OR m.MAPPING_KEY IS NULL;
  n_bad := SQLROWCOUNT;

  IF (n_bad > 0) THEN
    INSERT INTO RAP_DEMO.GOVERNANCE.ACCESS_AUDIT
    SELECT CURRENT_TIMESTAMP(), 'FILE_REJECTED', NULL, NULL, CURRENT_USER(),
           :P_FILE || ': ' || :n_bad || ' of ' || :n_rows || ' rows failed validation';
    RETURN 'Rejected ' || P_FILE || ': ' || n_bad || ' of ' || n_rows || ' rows failed validation, nothing removed';
  END IF;

  FOR rec IN c1 DO
    k := rec.MAPPING_KEY;
    r := rec.ROLE_NAME;
    CALL RAP_DEMO.GOVERNANCE.SP_OFFBOARD_ACCESS(:k, :r, :P_DROP_UNUSED_ROLES);
    n_removed := n_removed + 1;
  END FOR;

  RETURN 'Offboarded ' || n_removed || ' mappings from ' || P_FILE;
END;
$$;

-- First load of the governed copy: every row arrives unassigned.
CALL RAP_DEMO.GOVERNANCE.SP_REFRESH_FROM_SOURCE();
