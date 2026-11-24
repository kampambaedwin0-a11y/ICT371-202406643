-- ICT371 Advanced Database | Question 6: Monthly Payroll Processing
-- Student: Edwin Kampamba (202406643) | PostgreSQL 14+ with pg_cron
DROP SCHEMA IF EXISTS q6 CASCADE;
CREATE SCHEMA q6;
SET search_path TO q6, public;

-- (a) TABLES --------------------------------------------------------------
CREATE TABLE employees (
    employee_id  INT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    full_name    VARCHAR(100) NOT NULL,
    basic_salary NUMERIC(12,2) NOT NULL CHECK (basic_salary >= 0),
    allowance    NUMERIC(12,2) NOT NULL CHECK (allowance  >= 0),
    deduction    NUMERIC(12,2) NOT NULL CHECK (deduction  >= 0),
    active       BOOLEAN NOT NULL DEFAULT TRUE
);
CREATE TABLE payroll (
    payroll_id  INT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    employee_id INT NOT NULL REFERENCES employees(employee_id),
    pay_month   DATE NOT NULL,
    gross_pay   NUMERIC(12,2) NOT NULL CHECK (gross_pay >= 0),
    net_pay     NUMERIC(12,2) NOT NULL CHECK (net_pay >= 0),
    CONSTRAINT ck_month_start CHECK (pay_month = date_trunc('month', pay_month)::date),
    CONSTRAINT uq_emp_month UNIQUE (employee_id, pay_month)
);
CREATE TABLE salary_audit (
    audit_id    INT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    employee_id INT NOT NULL REFERENCES employees(employee_id),
    old_salary  NUMERIC(12,2) NOT NULL,
    new_salary  NUMERIC(12,2) NOT NULL,
    changed_at  TIMESTAMP NOT NULL DEFAULT now()
);

-- (b) FUNCTION ------------------------------------------------------------
CREATE OR REPLACE FUNCTION fn_net_pay(p_employee_id INT)
RETURNS NUMERIC LANGUAGE plpgsql STABLE AS $$
DECLARE v_net NUMERIC;
BEGIN
    SELECT basic_salary + allowance - deduction INTO v_net
      FROM employees WHERE employee_id = p_employee_id;
    IF NOT FOUND THEN
        RAISE EXCEPTION 'Unknown employee_id: %', p_employee_id;
    END IF;
    IF v_net < 0 THEN
        RAISE EXCEPTION 'Negative net pay (%) for employee %', v_net, p_employee_id;
    END IF;
    RETURN v_net;
END $$;

-- (c) PROCEDURE -----------------------------------------------------------
-- Any exception inside the loop aborts the whole call (single transaction).
CREATE OR REPLACE PROCEDURE pr_process_payroll(p_month DATE)
LANGUAGE plpgsql AS $$
DECLARE r RECORD; v_net NUMERIC;
BEGIN
    IF p_month IS NULL OR p_month <> date_trunc('month', p_month)::date THEN
        RAISE EXCEPTION 'p_month must be the first day of a month (got %)', p_month;
    END IF;
    FOR r IN SELECT employee_id, basic_salary, allowance
               FROM employees WHERE active ORDER BY employee_id
    LOOP
        v_net := fn_net_pay(r.employee_id);           -- raises on an invalid calculation
        INSERT INTO payroll (employee_id, pay_month, gross_pay, net_pay)
        VALUES (r.employee_id, p_month, r.basic_salary + r.allowance, v_net)
        ON CONFLICT (employee_id, pay_month) DO NOTHING;   -- existing rows stay unchanged
    END LOOP;
END $$;

-- (d) TRIGGER -------------------------------------------------------------
CREATE OR REPLACE FUNCTION trg_salary_audit() RETURNS TRIGGER LANGUAGE plpgsql AS $$
BEGIN
    INSERT INTO salary_audit (employee_id, old_salary, new_salary)
    VALUES (NEW.employee_id, OLD.basic_salary, NEW.basic_salary);
    RETURN NULL;
END $$;

CREATE TRIGGER trg_employees_salary_audit
AFTER UPDATE ON employees
FOR EACH ROW
WHEN (OLD.basic_salary IS DISTINCT FROM NEW.basic_salary)
EXECUTE FUNCTION trg_salary_audit();

-- (e) VIEW ----------------------------------------------------------------
-- INNER JOIN on employee_id with no filter on "active", so history of
-- employees who later became inactive is still reported.
CREATE OR REPLACE VIEW v_payroll_report AS
SELECT e.full_name, p.pay_month, p.gross_pay, p.net_pay
FROM payroll p
JOIN employees e ON e.employee_id = p.employee_id;

-- (f) INDEX ---------------------------------------------------------------
-- UNIQUE (employee_id, pay_month) leads with employee_id, so it cannot serve
-- "all employees for one month". An index on pay_month alone can; it does not
-- duplicate the unique index because the leading column is different.
CREATE INDEX idx_payroll_pay_month ON payroll (pay_month);

-- (g) SCHEDULED JOB -------------------------------------------------------
CREATE EXTENSION IF NOT EXISTS pg_cron;
SELECT cron.schedule(
    'q6_monthly_payroll', '0 2 1 * *',
    $$CALL q6.pr_process_payroll((date_trunc('month', CURRENT_DATE) - INTERVAL '1 month')::date)$$);

-- SEED DATA ---------------------------------------------------------------
INSERT INTO employees (full_name, basic_salary, allowance, deduction, active) VALUES
 ('Dr. Lweendo Hamoonga', 9000, 1500, 1200, TRUE),
 ('Mrs. Agnes Mulenga',   7000, 1000,  900, TRUE),
 ('Mr. Felix Sinkala',    6000,  800,  700, TRUE),
 ('Ms. Precious Daka',    5000,  500,  600, TRUE),
 ('Mr. Oscar Nyirenda',   4500,  400,  500, TRUE);

-- two payroll months, processed while everyone was active
CALL pr_process_payroll(DATE '2026-09-01');
CALL pr_process_payroll(DATE '2026-10-01');

-- employee 5 later leaves; history must remain in the report
UPDATE employees SET active = FALSE WHERE employee_id = 5;

-- DEMONSTRATIONS ----------------------------------------------------------
SELECT employee_id, fn_net_pay(employee_id) FROM employees ORDER BY 1;

-- reprocessing: nothing duplicated, nothing changed
CALL pr_process_payroll(DATE '2026-10-01');
SELECT pay_month, COUNT(*) AS rows FROM payroll GROUP BY pay_month ORDER BY 1;   -- 5 and 5

-- salary raise changes existing payroll? No: old rows stay unchanged
UPDATE employees SET basic_salary = 7500 WHERE employee_id = 2;     -- audited
UPDATE employees SET basic_salary = 7500 WHERE employee_id = 2;     -- unchanged: no audit
SELECT * FROM salary_audit;                                         -- exactly 1 row

CALL pr_process_payroll(DATE '2026-11-01');                         -- inactive employee 5 skipped
SELECT * FROM v_payroll_report ORDER BY pay_month, full_name;

DO $$ BEGIN CALL pr_process_payroll(DATE '2026-11-15');             -- not a month start
EXCEPTION WHEN OTHERS THEN RAISE NOTICE 'Rejected: %', SQLERRM; END $$;

-- whole call fails if one employee's net would be negative
BEGIN;
    UPDATE employees SET deduction = 99999 WHERE employee_id = 3;
    DO $$ BEGIN CALL pr_process_payroll(DATE '2026-12-01');
    EXCEPTION WHEN OTHERS THEN RAISE NOTICE 'Whole call failed: %', SQLERRM; END $$;
    SELECT COUNT(*) AS december_rows FROM payroll WHERE pay_month = DATE '2026-12-01';  -- 0
ROLLBACK;

ANALYZE payroll;
SET enable_seqscan = off;
EXPLAIN SELECT * FROM payroll WHERE pay_month = DATE '2026-10-01';
RESET enable_seqscan;

-- Inspect the job and its run history
SELECT jobid, jobname, schedule, command, active FROM cron.job WHERE jobname = 'q6_monthly_payroll';
SELECT jobid, runid, status, return_message, start_time, end_time
  FROM cron.job_run_details
 WHERE jobid = (SELECT jobid FROM cron.job WHERE jobname = 'q6_monthly_payroll')
 ORDER BY start_time DESC;
