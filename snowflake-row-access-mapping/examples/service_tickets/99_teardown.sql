-- Removes everything the worked example created. Run as ACCOUNTADMIN. Safe to run when nothing
-- exists. The database and warehouse are owned by RAP_DEMO_ADMIN, so ownership is taken back
-- first: dropping needs ownership, and ACCOUNTADMIN does not have it by default.
USE ROLE ACCOUNTADMIN;

EXECUTE IMMEDIATE $$
BEGIN
  BEGIN
    GRANT OWNERSHIP ON DATABASE RAP_DEMO TO ROLE ACCOUNTADMIN REVOKE CURRENT GRANTS;
  EXCEPTION WHEN OTHER THEN NULL;   -- database does not exist yet
  END;
  BEGIN
    GRANT OWNERSHIP ON WAREHOUSE RAP_DEMO_WH TO ROLE ACCOUNTADMIN REVOKE CURRENT GRANTS;
  EXCEPTION WHEN OTHER THEN NULL;   -- warehouse does not exist yet
  END;
  RETURN 'ownership reclaimed';
END;
$$;

DROP DATABASE IF EXISTS RAP_DEMO;
DROP WAREHOUSE IF EXISTS RAP_DEMO_WH;

-- Roles: created by RAP_DEMO_ADMIN, and dropping a role needs ownership of it. MANAGE GRANTS (held
-- by SECURITYADMIN) lets SECURITYADMIN take ownership first. Viewer roles go first, then pipeline
-- and admin. A role that does not exist is skipped.
USE ROLE SECURITYADMIN;
EXECUTE IMMEDIATE $$
DECLARE
  roles ARRAY DEFAULT ARRAY_CONSTRUCT('RAP_DEMO_NORTH_TEAM', 'RAP_DEMO_SOUTH_TEAM', 'RAP_DEMO_EAST_TEAM',
    'RAP_DEMO_WEST_TEAM', 'RAP_DEMO_NO_MAPPING', 'RAP_DEMO_AUDITOR', 'RAP_DEMO_PIPELINE', 'RAP_DEMO_ADMIN');
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
SHOW ROLES LIKE 'RAP_DEMO%';
