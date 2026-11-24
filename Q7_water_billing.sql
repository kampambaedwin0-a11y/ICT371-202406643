-- ICT371 Advanced Database | Question 7: Water Meter Readings and Billing
-- Student: Edwin Kampamba (202406643) | PostgreSQL 14+ with pg_cron
DROP SCHEMA IF EXISTS q7 CASCADE;
CREATE SCHEMA q7;
SET search_path TO q7, public;

-- (a) TABLES --------------------------------------------------------------
CREATE TABLE customers (
    customer_id INT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    full_name   VARCHAR(100) NOT NULL
);
CREATE TABLE readings (
    reading_id       INT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    customer_id      INT NOT NULL REFERENCES customers(customer_id),
    reading_month    DATE NOT NULL,
    previous_reading NUMERIC(10,2) NOT NULL CHECK (previous_reading >= 0),
    current_reading  NUMERIC(10,2) NOT NULL CHECK (current_reading  >= 0),
    CONSTRAINT ck_reading_month_start CHECK (reading_month = date_trunc('month', reading_month)::date),
    CONSTRAINT uq_customer_month UNIQUE (customer_id, reading_month)
);
CREATE TABLE bills (
    bill_id     INT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    reading_id  INT NOT NULL UNIQUE REFERENCES readings(reading_id),
    charge      NUMERIC(12,2) NOT NULL CHECK (charge >= 0),
    amount_paid NUMERIC(12,2) NOT NULL DEFAULT 0,
    due_on      DATE NOT NULL,
    CONSTRAINT ck_paid_range CHECK (amount_paid >= 0 AND amount_paid <= charge)
);
CREATE TABLE receivable_snapshot (
    snapshot_date DATE PRIMARY KEY,
    total_due     NUMERIC(14,2) NOT NULL
);

-- (b) FUNCTION ------------------------------------------------------------
-- First 10 units at K5, units above 10 at K8.
CREATE OR REPLACE FUNCTION fn_water_charge(p_units NUMERIC)
RETURNS NUMERIC(12,2) LANGUAGE plpgsql IMMUTABLE AS $$
BEGIN
    IF p_units IS NULL OR p_units < 0 THEN
        RAISE EXCEPTION 'Invalid consumption: % (must be non-negative)', p_units;
    END IF;
    RETURN ROUND(LEAST(p_units, 10) * 5 + GREATEST(p_units - 10, 0) * 8, 2);
END $$;

-- (d) TRIGGER (installed before readings are loaded) ----------------------
CREATE OR REPLACE FUNCTION trg_reading_check() RETURNS TRIGGER LANGUAGE plpgsql AS $$
BEGIN
    IF NEW.current_reading < NEW.previous_reading THEN
        RAISE EXCEPTION 'current_reading (%) is below previous_reading (%)',
                        NEW.current_reading, NEW.previous_reading;
    END IF;
    RETURN NEW;      -- exception aborts the statement, so nothing is stored
END $$;

CREATE TRIGGER trg_readings_check
BEFORE INSERT OR UPDATE ON readings
FOR EACH ROW EXECUTE FUNCTION trg_reading_check();

-- (c) PROCEDURE -----------------------------------------------------------
CREATE OR REPLACE PROCEDURE pr_generate_bill(p_reading_id INT, p_due_on DATE)
LANGUAGE plpgsql AS $$
DECLARE v_prev NUMERIC; v_curr NUMERIC; v_charge NUMERIC;
BEGIN
    IF p_due_on IS NULL THEN
        RAISE EXCEPTION 'Due date is required';
    END IF;
    SELECT previous_reading, current_reading INTO v_prev, v_curr
      FROM readings WHERE reading_id = p_reading_id;
    IF NOT FOUND THEN
        RAISE EXCEPTION 'Unknown reading_id: %', p_reading_id;
    END IF;
    IF EXISTS (SELECT 1 FROM bills WHERE reading_id = p_reading_id) THEN
        RAISE EXCEPTION 'Reading % already has a bill', p_reading_id;
    END IF;
    v_charge := fn_water_charge(v_curr - v_prev);
    INSERT INTO bills (reading_id, charge, amount_paid, due_on)
    VALUES (p_reading_id, v_charge, 0, p_due_on);
END $$;

-- (e) VIEW ----------------------------------------------------------------
CREATE OR REPLACE VIEW v_overdue_bills AS
SELECT c.full_name AS customer_name, b.due_on, b.charge - b.amount_paid AS outstanding_amount
FROM bills b
JOIN readings r  ON r.reading_id  = b.reading_id
JOIN customers c ON c.customer_id = r.customer_id
WHERE b.due_on < CURRENT_DATE AND b.amount_paid < b.charge;

-- (f) INDEX ---------------------------------------------------------------
-- Partial index on due_on for unpaid bills only. Fully paid bills (the large
-- majority over time) are excluded, so date-based overdue searches read a
-- small, ordered index. Queries must repeat the predicate amount_paid < charge.
CREATE INDEX idx_bills_unpaid_due_on ON bills (due_on) WHERE amount_paid < charge;

-- (g) SCHEDULED JOB -------------------------------------------------------
CREATE OR REPLACE PROCEDURE pr_refresh_receivables()
LANGUAGE plpgsql AS $$
BEGIN
    INSERT INTO receivable_snapshot (snapshot_date, total_due)
    SELECT CURRENT_DATE, COALESCE(SUM(charge - amount_paid), 0)
      FROM bills WHERE amount_paid < charge
    ON CONFLICT (snapshot_date) DO UPDATE SET total_due = EXCLUDED.total_due;
END $$;

CREATE EXTENSION IF NOT EXISTS pg_cron;
SELECT cron.schedule('q7_refresh_receivables', '30 0 * * *', $$CALL q7.pr_refresh_receivables()$$);

-- SEED DATA ---------------------------------------------------------------
INSERT INTO customers (full_name) VALUES ('Moses Lubinda'), ('Faith Mutemwa'), ('Isaac Zimba');

INSERT INTO readings (customer_id, reading_month, previous_reading, current_reading) VALUES
 (1, '2026-09-01', 100,  100),   -- 0 units
 (1, '2026-10-01', 100,  110),   -- exactly 10 units
 (2, '2026-09-01',  50,   65),   -- 15 units
 (2, '2026-10-01',  65,   70),   -- 5 units
 (3, '2026-09-01',   0,   25),   -- 25 units
 (3, '2026-10-01',  25,   35);   -- 10 units

-- September bills were due mid-October, October bills mid-November (both past)
CALL pr_generate_bill(1, DATE '2026-10-15');
CALL pr_generate_bill(2, DATE '2026-11-15');
CALL pr_generate_bill(3, DATE '2026-10-15');
CALL pr_generate_bill(4, DATE '2026-11-15');
CALL pr_generate_bill(5, DATE '2026-10-15');
CALL pr_generate_bill(6, DATE '2026-11-15');

UPDATE bills SET amount_paid = charge WHERE bill_id = 2;        -- fully paid
UPDATE bills SET amount_paid = 40     WHERE bill_id = 3;        -- part paid (charge 90)
UPDATE bills SET amount_paid = 20     WHERE bill_id = 6;        -- part paid (charge 50)

-- DEMONSTRATIONS ----------------------------------------------------------
SELECT fn_water_charge(0) AS zero, fn_water_charge(10) AS ten,
       fn_water_charge(15) AS fifteen, fn_water_charge(25.5) AS decimal_units;   -- 0, 50, 90, 172.00
SELECT * FROM bills ORDER BY 1;

DO $$ BEGIN PERFORM fn_water_charge(-1);
EXCEPTION WHEN OTHERS THEN RAISE NOTICE 'Rejected: %', SQLERRM; END $$;
DO $$ BEGIN PERFORM fn_water_charge(NULL);
EXCEPTION WHEN OTHERS THEN RAISE NOTICE 'Rejected: %', SQLERRM; END $$;
DO $$ BEGIN CALL pr_generate_bill(1, CURRENT_DATE);             -- already billed
EXCEPTION WHEN OTHERS THEN RAISE NOTICE 'Rejected: %', SQLERRM; END $$;
DO $$ BEGIN CALL pr_generate_bill(99, CURRENT_DATE);            -- unknown
EXCEPTION WHEN OTHERS THEN RAISE NOTICE 'Rejected: %', SQLERRM; END $$;

-- trigger: direct SQL with a lower current reading is rejected and not stored
DO $$ BEGIN INSERT INTO readings (customer_id, reading_month, previous_reading, current_reading)
            VALUES (1, '2026-11-01', 110, 105);
EXCEPTION WHEN OTHERS THEN RAISE NOTICE 'Rejected by trigger: %', SQLERRM; END $$;
SELECT COUNT(*) AS readings_still_6 FROM readings;

SELECT * FROM v_overdue_bills ORDER BY due_on;

ANALYZE bills;
SET enable_seqscan = off;
EXPLAIN SELECT * FROM bills
WHERE due_on < CURRENT_DATE AND amount_paid < charge ORDER BY due_on;
RESET enable_seqscan;

CALL pr_refresh_receivables();
CALL pr_refresh_receivables();                                  -- replaces today's row
SELECT * FROM receivable_snapshot;
SELECT jobid, jobname, schedule, command FROM cron.job WHERE jobname = 'q7_refresh_receivables';
