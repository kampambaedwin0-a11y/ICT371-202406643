-- ICT371 Advanced Database | Question 9: Farmer Cooperative Maize Deliveries
-- Student: Edwin Kampamba (202406643) | PostgreSQL 14+ with pg_cron
DROP SCHEMA IF EXISTS q9 CASCADE;
CREATE SCHEMA q9;
SET search_path TO q9, public;

-- (a) TABLES --------------------------------------------------------------
CREATE TABLE farmers (
    farmer_id     INT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    farmer_number VARCHAR(20) NOT NULL UNIQUE,
    full_name     VARCHAR(100) NOT NULL
);
CREATE TABLE deliveries (
    delivery_id  INT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    farmer_id    INT NOT NULL REFERENCES farmers(farmer_id),
    grade        CHAR(1) NOT NULL CHECK (grade IN ('A','B','C')),
    weight_kg    NUMERIC(10,2) NOT NULL CHECK (weight_kg > 0),
    unit_rate    NUMERIC(10,2) NOT NULL,      -- filled by trigger
    total_value  NUMERIC(14,2) NOT NULL,      -- filled by trigger
    delivered_on DATE NOT NULL,
    is_paid      BOOLEAN NOT NULL DEFAULT FALSE
);
CREATE TABLE daily_purchases (
    purchase_date DATE PRIMARY KEY,
    total_weight  NUMERIC(14,2) NOT NULL,
    total_value   NUMERIC(14,2) NOT NULL
);

-- (b) FUNCTION ------------------------------------------------------------
CREATE OR REPLACE FUNCTION fn_maize_rate(p_grade CHAR)
RETURNS NUMERIC LANGUAGE plpgsql IMMUTABLE AS $$
DECLARE v_rate NUMERIC;
BEGIN
    IF p_grade IS NULL THEN
        RAISE EXCEPTION 'Grade is required';
    END IF;
    v_rate := CASE p_grade WHEN 'A' THEN 5 WHEN 'B' THEN 4 WHEN 'C' THEN 3 END;
    IF v_rate IS NULL THEN
        RAISE EXCEPTION 'Unsupported grade: % (use A, B or C)', p_grade;
    END IF;
    RETURN v_rate;
END $$;

-- (d) TRIGGER (installed before deliveries are loaded) --------------------
CREATE OR REPLACE FUNCTION trg_delivery_pricing() RETURNS TRIGGER LANGUAGE plpgsql AS $$
BEGIN
    IF NEW.weight_kg IS NULL OR NEW.weight_kg <= 0 THEN
        RAISE EXCEPTION 'Weight must be positive (got %)', NEW.weight_kg;
    END IF;
    NEW.unit_rate   := fn_maize_rate(NEW.grade);
    NEW.total_value := ROUND(NEW.weight_kg * NEW.unit_rate, 2);   -- same rule for every route in
    RETURN NEW;
END $$;

CREATE TRIGGER trg_deliveries_pricing
BEFORE INSERT OR UPDATE ON deliveries
FOR EACH ROW EXECUTE FUNCTION trg_delivery_pricing();

-- (c) PROCEDURE -----------------------------------------------------------
-- Supplies only basic fields; the trigger fills unit_rate and total_value.
-- (unit_rate / total_value are NOT NULL, but NOT NULL is checked after BEFORE
--  triggers, so the omitted columns are legal here.)
CREATE OR REPLACE PROCEDURE pr_receive_delivery(p_farmer_id INT, p_grade CHAR, p_weight NUMERIC, p_date DATE)
LANGUAGE plpgsql AS $$
BEGIN
    IF NOT EXISTS (SELECT 1 FROM farmers WHERE farmer_id = p_farmer_id) THEN
        RAISE EXCEPTION 'Unknown farmer_id: %', p_farmer_id;
    END IF;
    IF p_grade IS NULL OR p_weight IS NULL OR p_date IS NULL THEN
        RAISE EXCEPTION 'Grade, weight and date are required';
    END IF;
    IF p_weight <= 0 THEN
        RAISE EXCEPTION 'Weight must be positive (got %)', p_weight;
    END IF;
    INSERT INTO deliveries (farmer_id, grade, weight_kg, delivered_on, is_paid)
    VALUES (p_farmer_id, p_grade, p_weight, p_date, FALSE);
END $$;

-- (e) VIEW ----------------------------------------------------------------
-- Condition on is_paid is in the JOIN (not WHERE) so farmers with no unpaid
-- deliveries still appear, with COALESCE turning NULL into 0.
CREATE OR REPLACE VIEW v_farmer_amount_due AS
SELECT f.farmer_number, f.full_name, COALESCE(SUM(d.total_value), 0) AS amount_due
FROM farmers f
LEFT JOIN deliveries d ON d.farmer_id = f.farmer_id AND d.is_paid = FALSE
GROUP BY f.farmer_id, f.farmer_number, f.full_name;

-- (f) INDEX ---------------------------------------------------------------
-- Equality on farmer_id, range on delivered_on: one contiguous index range.
CREATE INDEX idx_deliveries_farmer_date ON deliveries (farmer_id, delivered_on);

-- (g) SCHEDULED JOB -------------------------------------------------------
CREATE OR REPLACE PROCEDURE pr_refresh_purchases(p_day DATE)
LANGUAGE plpgsql AS $$
BEGIN
    INSERT INTO daily_purchases (purchase_date, total_weight, total_value)
    SELECT p_day, COALESCE(SUM(weight_kg), 0), COALESCE(SUM(total_value), 0)
      FROM deliveries WHERE delivered_on = p_day
    ON CONFLICT (purchase_date) DO UPDATE      -- SET to the new total; never "+="
       SET total_weight = EXCLUDED.total_weight,
           total_value  = EXCLUDED.total_value;
END $$;

CREATE EXTENSION IF NOT EXISTS pg_cron;
SELECT cron.schedule('q9_refresh_purchases', '30 1 * * *',
                     $$CALL q9.pr_refresh_purchases(CURRENT_DATE - 1)$$);

-- SEED DATA ---------------------------------------------------------------
INSERT INTO farmers (farmer_number, full_name) VALUES
 ('F001', 'Kapambwe Mulenga'), ('F002', 'Namukolo Hachibamba'), ('F003', 'Sikota Mwanza');

CALL pr_receive_delivery(1, 'A', 200.00, CURRENT_DATE - 2);
CALL pr_receive_delivery(1, 'B', 150.50, CURRENT_DATE - 1);
CALL pr_receive_delivery(2, 'C', 300.00, CURRENT_DATE - 1);
CALL pr_receive_delivery(2, 'A',  80.25, CURRENT_DATE - 1);
CALL pr_receive_delivery(3, 'B', 120.00, CURRENT_DATE - 2);
CALL pr_receive_delivery(3, 'C',  60.00, CURRENT_DATE);

-- both payment states; farmer 3 ends with only paid deliveries
UPDATE deliveries SET is_paid = TRUE WHERE delivery_id IN (1, 5, 6);

-- DEMONSTRATIONS ----------------------------------------------------------
SELECT fn_maize_rate('A'), fn_maize_rate('B'), fn_maize_rate('C');   -- 5, 4, 3
SELECT * FROM deliveries ORDER BY 1;

DO $$ BEGIN PERFORM fn_maize_rate('D');
EXCEPTION WHEN OTHERS THEN RAISE NOTICE 'Rejected: %', SQLERRM; END $$;
DO $$ BEGIN PERFORM fn_maize_rate(NULL);
EXCEPTION WHEN OTHERS THEN RAISE NOTICE 'Rejected: %', SQLERRM; END $$;
DO $$ BEGIN CALL pr_receive_delivery(99, 'A', 10, CURRENT_DATE);
EXCEPTION WHEN OTHERS THEN RAISE NOTICE 'Rejected: %', SQLERRM; END $$;
DO $$ BEGIN CALL pr_receive_delivery(1, 'A', -5, CURRENT_DATE);
EXCEPTION WHEN OTHERS THEN RAISE NOTICE 'Rejected: %', SQLERRM; END $$;

-- direct SQL follows the same pricing rule, even if wrong values are supplied
INSERT INTO deliveries (farmer_id, grade, weight_kg, unit_rate, total_value, delivered_on)
VALUES (1, 'C', 100, 999, 99999, CURRENT_DATE - 1);                -- stored as 3.00 and 300.00
SELECT delivery_id, grade, weight_kg, unit_rate, total_value FROM deliveries WHERE delivery_id = 7;
DO $$ BEGIN INSERT INTO deliveries (farmer_id, grade, weight_kg, unit_rate, total_value, delivered_on)
            VALUES (1, 'A', 0, 5, 0, CURRENT_DATE);
EXCEPTION WHEN OTHERS THEN RAISE NOTICE 'Rejected by trigger: %', SQLERRM; END $$;

SELECT * FROM v_farmer_amount_due ORDER BY farmer_number;           -- farmer 3 shows 0

ANALYZE deliveries;
SET enable_seqscan = off;
EXPLAIN SELECT * FROM deliveries
WHERE farmer_id = 1 AND delivered_on BETWEEN CURRENT_DATE - 7 AND CURRENT_DATE;
RESET enable_seqscan;

CALL pr_refresh_purchases(CURRENT_DATE - 1);
CALL pr_refresh_purchases(CURRENT_DATE - 1);                        -- replaced, not added again
SELECT * FROM daily_purchases;
SELECT jobid, jobname, schedule, command FROM cron.job WHERE jobname = 'q9_refresh_purchases';
