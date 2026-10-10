--------------------------------------------------------------------------------
-- 99_teardown.sql
-- RAM V2 Example: drops only what 01_setup.sql and 02_objects.sql created
-- Run as ACCOUNTADMIN
--------------------------------------------------------------------------------
USE ROLE ACCOUNTADMIN;

-- Drop viewer roles created by onboarding
DROP ROLE IF EXISTS RAM_V2_GROUP_ALPHA_VIEWER;
DROP ROLE IF EXISTS RAM_V2_GROUP_BETA_VIEWER;
DROP ROLE IF EXISTS RAM_V2_GROUP_GAMMA_VIEWER;
DROP ROLE IF EXISTS RAM_V2_GROUP_X_VIEWER;
DROP ROLE IF EXISTS RAM_V2_GROUP_Y_VIEWER;

-- Drop admin role
DROP ROLE IF EXISTS RAM_V2_ADMIN;

-- Drop database (removes all schemas, tables, procedures, task, stage, format, policy)
DROP DATABASE IF EXISTS RAM_V2_EXAMPLE;

SELECT 'Teardown complete' AS STATUS;
