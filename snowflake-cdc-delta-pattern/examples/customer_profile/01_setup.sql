-- Worked example, step 1 of 4: a simulated upstream table and the curated view that is the contract.
-- Everything is created in a throwaway CDC_DEMO database. No account or organisation identifiers
-- are used anywhere; run it as any role that can create a database and a warehouse.

CREATE DATABASE IF NOT EXISTS CDC_DEMO;
CREATE SCHEMA IF NOT EXISTS CDC_DEMO.UPSTREAM;        -- stands in for the source system's landing area
CREATE SCHEMA IF NOT EXISTS CDC_DEMO.CUSTOMER_FEED;   -- this use case's CDC objects
CREATE SCHEMA IF NOT EXISTS CDC_DEMO.CDC_AUDIT;       -- shared run log

CREATE WAREHOUSE IF NOT EXISTS CDC_DEMO_WH
  WAREHOUSE_SIZE = XSMALL AUTO_SUSPEND = 60 AUTO_RESUME = TRUE INITIALLY_SUSPENDED = TRUE;
USE WAREHOUSE CDC_DEMO_WH;

-- Upstream data, with upstream's own column names.
CREATE OR REPLACE TABLE CDC_DEMO.UPSTREAM.CRM_CUSTOMER (
  cust_no      VARCHAR,
  cust_name    VARCHAR,
  email_addr   VARCHAR,
  cust_tier    VARCHAR,
  city         VARCHAR,
  credit_limit NUMBER(12,2)
);

INSERT INTO CDC_DEMO.UPSTREAM.CRM_CUSTOMER VALUES
  ('C001', 'Ava Thompson',  'ava@example.com',   'Gold',   'Brisbane',  5000),
  ('C002', 'Ben Carter',    'ben@example.com',   'Silver', 'Sydney',    2500),
  ('C003', 'Chloe Nguyen',  'chloe@example.com', 'Bronze', 'Melbourne', 1000),
  ('C004', 'Dev Patel',     'dev@example.com',   'Silver', 'Perth',     2500),
  ('C005', 'Ella Morris',   NULL,                'Bronze', 'Adelaide',  NULL);

-- The contract: curated names the destination expects. Renames upstream are absorbed here, once.
CREATE OR REPLACE VIEW CDC_DEMO.CUSTOMER_FEED.V_CUSTOMER_PROFILE AS
SELECT cust_no      AS CUSTOMER_ID,
       cust_name    AS FULL_NAME,
       email_addr   AS EMAIL,
       cust_tier    AS TIER,
       city         AS CITY,
       credit_limit AS CREDIT_LIMIT
FROM CDC_DEMO.UPSTREAM.CRM_CUSTOMER;
