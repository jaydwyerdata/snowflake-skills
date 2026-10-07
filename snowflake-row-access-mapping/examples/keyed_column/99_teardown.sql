-- Removes everything the worked example created. Run as ACCOUNTADMIN. Safe to run when nothing
-- exists. The database and warehouse are owned by RAP_KEYED_ADMIN, so ownership is taken back
-- first: dropping needs ownership, and ACCOUNTADMIN does not have it by default.
USE ROLE ACCOUNTADMIN;

EXECUTE IMMEDIATE $$
BEGIN
  BEGIN
    GRANT OWNERSHIP ON DATABASE RAP_KEYED TO ROLE ACCOUNTADMIN REVOKE CURRENT GRANTS;
  EXCEPTION WHEN OTHER THEN NULL;   -- database does not exist yet
  END;
  BEGIN
    GRANT OWNERSHIP ON WAREHOUSE RAP_KEYED_WH TO ROLE ACCOUNTADMIN REVOKE CURRENT GRANTS;
  EXCEPTION WHEN OTHER THEN NULL;   -- warehouse does not exist yet
  END;
  RETURN 'ownership reclaimed';
END;
$$;

DROP DATABASE IF EXISTS RAP_KEYED;
DROP WAREHOUSE IF EXISTS RAP_KEYED_WH;

-- Roles: created by RAP_KEYED_ADMIN, and dropping a role needs ownership of it. MANAGE GRANTS (held
-- by SECURITYADMIN) lets SECURITYADMIN take ownership first. Viewer roles go first, then pipeline
-- and admin. A role that does not exist is skipped.
USE ROLE SECURITYADMIN;
EXECUTE IMMEDIATE $$
DECLARE
  roles ARRAY DEFAULT ARRAY_CONSTRUCT('RAP_KEYED_NORTH_TEAM', 'RAP_KEYED_SOUTH_TEAM', 'RAP_KEYED_EAST_TEAM',
    'RAP_KEYED_WEST_TEAM', 'RAP_KEYED_NO_MAPPING', 'RAP_KEYED_AUDITOR', 'RAP_KEYED_PIPELINE', 'RAP_KEYED_ADMIN');
  r VARCHAR;
BEGIN
  FOR i IN 0 TO ARRAY_SIZE(roles) - 1 DO
    r := GET(roles, i)::VARCHAR;
    BEGIN
      EXECUTE IMMEDIATE 'GRANT OWNERSHIP ON ROLE ' || r || ' TO ROLE SECURITYADMIN REVOKE CURRENT GRANTS';
      EXECUTE IMMEDIATE 'DROP ROLE ' || r;
    EXCEPTION
      WHEN OTHER THEN NULL;
    END;
  END FOR;
  RETURN 'roles processed';
END;
$$;
USE ROLE ACCOUNTADMIN;

-- Should return no rows.
SHOW ROLES LIKE 'RAP_KEYED%';
