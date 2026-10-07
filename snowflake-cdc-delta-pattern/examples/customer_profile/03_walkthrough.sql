-- Worked example, step 3 of 4: replay five days of upstream change through the pattern.
-- Each day changes the upstream table, then runs the daily chain for that date, exactly as the
-- task graph would (upsert, delta, snapshot). Run top to bottom.

USE WAREHOUSE CDC_DEMO_WH;

-- Day 0 (5 Jan): initial load. Expect 5 rows in BASE, SNAPSHOT and DELTA.
CALL CDC_DEMO.CUSTOMER_FEED.SP_CUSTOMER_PROFILE_INITIAL_LOAD('2026-01-05'::DATE);

-- Day 1 (6 Jan): Ben moves Silver to Gold, and a new customer arrives.
-- Expect: 1 UPDATE history row (TIER), 5 INSERT history rows (one per field), 2 UPSERT delta rows.
UPDATE CDC_DEMO.UPSTREAM.SHOP_CUSTOMER SET cust_tier = 'Gold' WHERE cust_no = 'C002';
INSERT INTO CDC_DEMO.UPSTREAM.SHOP_CUSTOMER VALUES ('C006', 'Finn Walsh', 'finn@example.com', 'Bronze', 'Hobart', 450);
CALL CDC_DEMO.CUSTOMER_FEED.SP_CUSTOMER_PROFILE_UPSERT('2026-01-06'::DATE);
CALL CDC_DEMO.CUSTOMER_FEED.SP_CUSTOMER_PROFILE_DELTA('2026-01-06'::DATE);
CALL CDC_DEMO.CUSTOMER_FEED.SP_CUSTOMER_PROFILE_SNAPSHOT('2026-01-06'::DATE);

-- Day 2 (7 Jan): upstream renames a column. The view absorbs it; the CDC objects never notice.
-- Expect: upsert succeeds with 0 changes, 0 delta rows.
ALTER TABLE CDC_DEMO.UPSTREAM.SHOP_CUSTOMER RENAME COLUMN cust_tier TO loyalty_tier;
CREATE OR REPLACE VIEW CDC_DEMO.CUSTOMER_FEED.V_CUSTOMER_PROFILE AS
SELECT cust_no      AS CUSTOMER_ID,
       cust_name    AS FULL_NAME,
       email_addr   AS EMAIL,
       loyalty_tier AS TIER,          -- the only line that changed
       city         AS CITY,
       reward_points AS REWARD_POINTS
FROM CDC_DEMO.UPSTREAM.SHOP_CUSTOMER;
CALL CDC_DEMO.CUSTOMER_FEED.SP_CUSTOMER_PROFILE_UPSERT('2026-01-07'::DATE);
CALL CDC_DEMO.CUSTOMER_FEED.SP_CUSTOMER_PROFILE_DELTA('2026-01-07'::DATE);
CALL CDC_DEMO.CUSTOMER_FEED.SP_CUSTOMER_PROFILE_SNAPSHOT('2026-01-07'::DATE);

-- Day 3 (8 Jan): Chloe and Finn are removed upstream; Dev's email is cleared.
-- Expect: 2 DELETE delta rows carrying last-known values, and Dev's UPSERT row with EMAIL = 'null'.
DELETE FROM CDC_DEMO.UPSTREAM.SHOP_CUSTOMER WHERE cust_no IN ('C003', 'C006');
UPDATE CDC_DEMO.UPSTREAM.SHOP_CUSTOMER SET email_addr = NULL WHERE cust_no = 'C004';
CALL CDC_DEMO.CUSTOMER_FEED.SP_CUSTOMER_PROFILE_UPSERT('2026-01-08'::DATE);
CALL CDC_DEMO.CUSTOMER_FEED.SP_CUSTOMER_PROFILE_DELTA('2026-01-08'::DATE);
CALL CDC_DEMO.CUSTOMER_FEED.SP_CUSTOMER_PROFILE_SNAPSHOT('2026-01-08'::DATE);

-- Re-run day 3 (a retry after a scare). Expect both calls to return "Skipped", and nothing duplicated.
CALL CDC_DEMO.CUSTOMER_FEED.SP_CUSTOMER_PROFILE_UPSERT('2026-01-08'::DATE);
CALL CDC_DEMO.CUSTOMER_FEED.SP_CUSTOMER_PROFILE_DELTA('2026-01-08'::DATE);

-- Day 4 (9 Jan): Finn comes back, and Ava's reward points rise.
-- Expect: Finn revived as an INSERT (5 history rows, IS_DELETED back to FALSE), Ava 1 UPDATE row,
-- 2 UPSERT delta rows, REWARD_POINTS delivered as a number (no 'null' coercion on numerics).
INSERT INTO CDC_DEMO.UPSTREAM.SHOP_CUSTOMER VALUES ('C006', 'Finn Walsh', 'finn@example.com', 'Bronze', 'Hobart', 450);
UPDATE CDC_DEMO.UPSTREAM.SHOP_CUSTOMER SET reward_points = 2000 WHERE cust_no = 'C001';
CALL CDC_DEMO.CUSTOMER_FEED.SP_CUSTOMER_PROFILE_UPSERT('2026-01-09'::DATE);
CALL CDC_DEMO.CUSTOMER_FEED.SP_CUSTOMER_PROFILE_DELTA('2026-01-09'::DATE);
CALL CDC_DEMO.CUSTOMER_FEED.SP_CUSTOMER_PROFILE_SNAPSHOT('2026-01-09'::DATE);

-- Housekeeping six weeks later (20 Feb). Chloe was soft-deleted on 8 Jan (past the 30-day grace
-- period) and her DELETE was delivered, so she is hard-purged. Nothing is old enough to leave DELTA
-- or CHANGE_HISTORY yet. Expect: 1 row purged.
CALL CDC_DEMO.CUSTOMER_FEED.SP_CUSTOMER_PROFILE_HOUSEKEEPING('2026-02-20'::DATE);

-- What the downstream consumer sees, in delivery order.
SELECT INSERT_DATE::DATE AS DELIVERED, ACTION, CUSTOMER_ID, FULL_NAME, EMAIL, TIER, CITY, REWARD_POINTS
FROM CDC_DEMO.CUSTOMER_FEED.CUSTOMER_PROFILE_DELTA
ORDER BY INSERT_DATE, CUSTOMER_ID;
