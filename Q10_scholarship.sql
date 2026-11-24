-- ICT371 Advanced Database | Question 10: Scholarship Application Assessment
-- Student: Edwin Kampamba (202406643) | PostgreSQL 14+ with pg_cron
DROP SCHEMA IF EXISTS q10 CASCADE;
CREATE SCHEMA q10;
SET search_path TO q10, public;

-- (a) TABLES --------------------------------------------------------------
CREATE TABLE students (
    student_id     INT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    student_number VARCHAR(20) NOT NULL UNIQUE,
    full_name      VARCHAR(100) NOT NULL
);
CREATE TABLE applications (
    application_id     INT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    student_id         INT NOT NULL REFERENCES students(student_id),
    age_at_application INT NOT NULL CHECK (age_at_application > 0),
    monthly_income     NUMERIC(10,2) NOT NULL CHECK (monthly_income >= 0),
    average_mark       NUMERIC(5,2)  NOT NULL CHECK (average_mark BETWEEN 0 AND 100),
    submitted_on       DATE NOT NULL,
    status             VARCHAR(10) NOT NULL DEFAULT 'PENDING',
    CONSTRAINT ck_app_status CHECK (status IN ('PENDING','APPROVED','REJECTED'))
);
CREATE TABLE decision_audit (
    audit_id       INT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    application_id INT NOT NULL REFERENCES applications(application_id),
    old_status     VARCHAR(10) NOT NULL,
    new_status     VARCHAR(10) NOT NULL,
    changed_at     TIMESTAMP NOT NULL DEFAULT now()
);

-- (b) FUNCTION ------------------------------------------------------------
-- Eligible: age 18..25 inclusive, income <= 3000, mark >= 70.
CREATE OR REPLACE FUNCTION fn_scholarship_eligible(p_age INT, p_income NUMERIC, p_mark NUMERIC)
RETURNS BOOLEAN LANGUAGE plpgsql IMMUTABLE AS $$
BEGIN
    IF p_age IS NULL OR p_income IS NULL OR p_mark IS NULL THEN
        RAISE EXCEPTION 'Age, income and mark are all required';
    END IF;
    IF p_age <= 0 THEN
        RAISE EXCEPTION 'Age must be positive (got %)', p_age;
    END IF;
    IF p_income < 0 THEN
        RAISE EXCEPTION 'Income cannot be negative (got %)', p_income;
    END IF;
    IF p_mark < 0 OR p_mark > 100 THEN
        RAISE EXCEPTION 'Mark must be between 0 and 100 (got %)', p_mark;
    END IF;
    RETURN p_age BETWEEN 18 AND 25 AND p_income <= 3000 AND p_mark >= 70;
END $$;

-- (c) PROCEDURE -----------------------------------------------------------
CREATE OR REPLACE PROCEDURE pr_assess_application(p_application_id INT)
LANGUAGE plpgsql AS $$
DECLARE v_status VARCHAR; v_age INT; v_income NUMERIC; v_mark NUMERIC;
BEGIN
    SELECT status, age_at_application, monthly_income, average_mark
      INTO v_status, v_age, v_income, v_mark
      FROM applications WHERE application_id = p_application_id FOR UPDATE;
    IF NOT FOUND THEN
        RAISE EXCEPTION 'Application % does not exist', p_application_id;
    END IF;
    IF v_status <> 'PENDING' THEN
        RAISE EXCEPTION 'Application % has already been assessed (status %)', p_application_id, v_status;
    END IF;
    UPDATE applications
       SET status = CASE WHEN fn_scholarship_eligible(v_age, v_income, v_mark)
                         THEN 'APPROVED' ELSE 'REJECTED' END
     WHERE application_id = p_application_id;
END $$;

-- (d) TRIGGER -------------------------------------------------------------
CREATE OR REPLACE FUNCTION trg_decision_audit() RETURNS TRIGGER LANGUAGE plpgsql AS $$
BEGIN
    INSERT INTO decision_audit (application_id, old_status, new_status, changed_at)
    VALUES (NEW.application_id, OLD.status, NEW.status, now());
    RETURN NULL;
END $$;

CREATE TRIGGER trg_applications_decision_audit
AFTER UPDATE ON applications
FOR EACH ROW
WHEN (OLD.status IS DISTINCT FROM NEW.status)
EXECUTE FUNCTION trg_decision_audit();

-- (e) VIEW ----------------------------------------------------------------
-- No monthly_income column is exposed.
CREATE OR REPLACE VIEW v_approved_applicants AS
SELECT s.student_number, s.full_name, a.average_mark, a.status
FROM applications a
JOIN students s ON s.student_id = a.student_id
WHERE a.status = 'APPROVED';

-- (f) INDEX ---------------------------------------------------------------
-- status is tested by equality, submitted_on by range, so status goes first.
CREATE INDEX idx_applications_status_submitted ON applications (status, submitted_on);

-- (g) SCHEDULED JOB -------------------------------------------------------
-- Only PENDING rows are selected, so a rerun finds nothing to do: no
-- reassessment and no duplicate audit rows.
CREATE OR REPLACE PROCEDURE pr_assess_pending()
LANGUAGE plpgsql AS $$
DECLARE r RECORD;
BEGIN
    FOR r IN SELECT application_id FROM applications
              WHERE status = 'PENDING' ORDER BY application_id
    LOOP
        CALL pr_assess_application(r.application_id);
    END LOOP;
END $$;

CREATE EXTENSION IF NOT EXISTS pg_cron;
SELECT cron.schedule('q10_assess_pending', '0 8 * * 1', $$CALL q10.pr_assess_pending()$$);

-- SEED DATA: six PENDING applications, three students --------------------
INSERT INTO students (student_number, full_name) VALUES
 ('2024201', 'Mapalo Chisenga'), ('2024202', 'Tadala Phiri'), ('2024203', 'Wezi Banda');

INSERT INTO applications (student_id, age_at_application, monthly_income, average_mark, submitted_on) VALUES
 (1, 20, 2000.00, 85.00, CURRENT_DATE - 10),   -- 1 clearly qualifies
 (1, 18, 3000.00, 70.00, CURRENT_DATE -  9),   -- 2 every lower/upper boundary: qualifies
 (2, 25, 1500.00, 72.00, CURRENT_DATE -  8),   -- 3 age upper boundary: qualifies
 (2, 17, 1000.00, 90.00, CURRENT_DATE -  7),   -- 4 too young: fails
 (3, 22, 3000.01, 80.00, CURRENT_DATE -  6),   -- 5 income just over: fails
 (3, 21, 2500.00, 69.99, CURRENT_DATE -  5);   -- 6 mark just under: fails

-- DEMONSTRATIONS ----------------------------------------------------------
SELECT fn_scholarship_eligible(18, 3000, 70) AS all_boundaries_pass,     -- true
       fn_scholarship_eligible(26, 1000, 90) AS too_old;                 -- false
DO $$ BEGIN PERFORM fn_scholarship_eligible(NULL, 1000, 90);
EXCEPTION WHEN OTHERS THEN RAISE NOTICE 'Rejected: %', SQLERRM; END $$;
DO $$ BEGIN PERFORM fn_scholarship_eligible(20, -1, 90);
EXCEPTION WHEN OTHERS THEN RAISE NOTICE 'Rejected: %', SQLERRM; END $$;
DO $$ BEGIN PERFORM fn_scholarship_eligible(20, 1000, 101);
EXCEPTION WHEN OTHERS THEN RAISE NOTICE 'Rejected: %', SQLERRM; END $$;

CALL pr_assess_application(1);                           -- single assessment
SELECT application_id, status FROM applications ORDER BY 1;

DO $$ BEGIN CALL pr_assess_application(1);               -- already assessed
EXCEPTION WHEN OTHERS THEN RAISE NOTICE 'Rejected: %', SQLERRM; END $$;
DO $$ BEGIN CALL pr_assess_application(999);             -- unknown
EXCEPTION WHEN OTHERS THEN RAISE NOTICE 'Rejected: %', SQLERRM; END $$;

CALL pr_assess_pending();                                -- processes applications 2..6
SELECT application_id, status FROM applications ORDER BY 1;   -- 1,2,3 APPROVED; 4,5,6 REJECTED
SELECT COUNT(*) AS audit_rows FROM decision_audit;       -- 6

CALL pr_assess_pending();                                -- rerun: nothing changes
SELECT COUNT(*) AS audit_rows_still_6 FROM decision_audit;

UPDATE applications SET status = status WHERE application_id = 1;   -- unchanged: no audit row
SELECT COUNT(*) AS still_6 FROM decision_audit;

SELECT * FROM v_approved_applicants;

ANALYZE applications;
SET enable_seqscan = off;
EXPLAIN SELECT * FROM applications
WHERE status = 'PENDING' AND submitted_on BETWEEN CURRENT_DATE - 30 AND CURRENT_DATE;
RESET enable_seqscan;

SELECT jobid, jobname, schedule, command FROM cron.job WHERE jobname = 'q10_assess_pending';
