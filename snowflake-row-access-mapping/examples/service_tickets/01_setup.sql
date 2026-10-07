-- Worked example, step 1 of 4: roles, and the source table another team owns.
-- Invented dataset: service tickets for a fictional field-service company. The source arrives
-- with no mapping at all; which rows each group may see is decided by the business, via CSV.
-- No account or organisation identifiers are used. Run as ACCOUNTADMIN.

USE ROLE ACCOUNTADMIN;
SET ME = CURRENT_USER();

-- The access admin role: owns the governed copy, the mapping, the policy and the procedures.
-- It gets CREATE ROLE (to create viewer roles it then owns), not MANAGE GRANTS.
CREATE ROLE IF NOT EXISTS RAP_DEMO_ADMIN;
GRANT CREATE ROLE ON ACCOUNT TO ROLE RAP_DEMO_ADMIN;
GRANT CREATE DATABASE ON ACCOUNT TO ROLE RAP_DEMO_ADMIN;
GRANT CREATE WAREHOUSE ON ACCOUNT TO ROLE RAP_DEMO_ADMIN;
GRANT ROLE RAP_DEMO_ADMIN TO USER IDENTIFIER($ME);

-- Stands in for the separate team that owns the source table and its pipeline.
CREATE ROLE IF NOT EXISTS RAP_DEMO_PIPELINE;
GRANT ROLE RAP_DEMO_PIPELINE TO USER IDENTIFIER($ME);

USE ROLE RAP_DEMO_ADMIN;
USE SECONDARY ROLES NONE;

CREATE WAREHOUSE IF NOT EXISTS RAP_DEMO_WH
  WAREHOUSE_SIZE = XSMALL AUTO_SUSPEND = 60 AUTO_RESUME = TRUE INITIALLY_SUSPENDED = TRUE;
USE WAREHOUSE RAP_DEMO_WH;

CREATE DATABASE IF NOT EXISTS RAP_DEMO;
CREATE SCHEMA IF NOT EXISTS RAP_DEMO.SHARED;       -- the governed copy consumers query
CREATE SCHEMA IF NOT EXISTS RAP_DEMO.GOVERNANCE;   -- mapping, policy, procedures, logs; consumers never get USAGE here

GRANT USAGE ON DATABASE RAP_DEMO TO ROLE RAP_DEMO_PIPELINE;
GRANT CREATE SCHEMA ON DATABASE RAP_DEMO TO ROLE RAP_DEMO_PIPELINE;
GRANT USAGE ON WAREHOUSE RAP_DEMO_WH TO ROLE RAP_DEMO_PIPELINE;

-- The pipeline team's table. It is theirs: they may rebuild it however and whenever they like.
USE ROLE RAP_DEMO_PIPELINE;
USE SECONDARY ROLES NONE;
CREATE SCHEMA IF NOT EXISTS RAP_DEMO.SOURCE;

CREATE OR REPLACE TABLE RAP_DEMO.SOURCE.SERVICE_TICKETS (
  TICKET_ID VARCHAR,          -- stable record ID: the same ticket keeps the same ID across rebuilds
  OPENED_ON DATE,
  CATEGORY  VARCHAR,
  STATUS    VARCHAR
);

INSERT INTO RAP_DEMO.SOURCE.SERVICE_TICKETS VALUES
  ('T-1001', '2026-01-05', 'Repair',       'Closed'),
  ('T-1002', '2026-01-08', 'Installation', 'Open'),
  ('T-1003', '2026-01-12', 'Inspection',   'Open'),
  ('T-1004', '2026-01-19', 'Repair',       'Closed'),
  ('T-2001', '2026-01-06', 'Repair',       'Open'),
  ('T-2002', '2026-01-14', 'Inspection',   'Closed'),
  ('T-2003', '2026-01-21', 'Installation', 'Open'),
  ('T-3001', '2026-01-07', 'Repair',       'Open'),
  ('T-3002', '2026-01-15', 'Repair',       'Closed'),
  ('T-3003', '2026-01-22', 'Inspection',   'Open'),
  ('T-4001', '2026-01-09', 'Installation', 'Open'),
  ('T-4002', '2026-01-16', 'Repair',       'Closed');

-- The pipeline team's one hand-over: let the access admin role read their table.
GRANT USAGE ON SCHEMA RAP_DEMO.SOURCE TO ROLE RAP_DEMO_ADMIN;
GRANT SELECT ON TABLE RAP_DEMO.SOURCE.SERVICE_TICKETS TO ROLE RAP_DEMO_ADMIN;

USE ROLE RAP_DEMO_ADMIN;
USE SECONDARY ROLES NONE;
