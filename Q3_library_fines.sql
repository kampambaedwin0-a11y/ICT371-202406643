-- ICT371 Advanced Database | Question 3: Library Returns and Overdue Fines
-- Student: Edwin Kampamba (202406643) | PostgreSQL 14+ with pg_cron
DROP SCHEMA IF EXISTS q3 CASCADE;
CREATE SCHEMA q3;
SET search_path TO q3, public;

-- (a) TABLES --------------------------------------------------------------
CREATE TABLE books (
    book_id INT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    title   VARCHAR(150) NOT NULL
);
CREATE TABLE loans (
    loan_id       INT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    book_id       INT NOT NULL REFERENCES books(book_id),
    borrower_name VARCHAR(100) NOT NULL,
    borrowed_on   DATE NOT NULL,
    due_on        DATE NOT NULL,
    returned_on   DATE NULL,
    fine_amount   NUMERIC(10,2) NOT NULL DEFAULT 0 CHECK (fine_amount >= 0),
    CONSTRAINT ck_due_after_borrow CHECK (due_on >= borrowed_on)
);
CREATE TABLE loan_audit (
    audit_id        INT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    loan_id         INT NOT NULL REFERENCES loans(loan_id),
    old_returned_on DATE NULL,
    new_returned_on DATE NULL,
    changed_at      TIMESTAMP NOT NULL DEFAULT now()
);
CREATE TABLE overdue_summary (
    snapshot_date DATE PRIMARY KEY,
    overdue_count INT NOT NULL,
    total_fine    NUMERIC(12,2) NOT NULL
);

-- (b) FUNCTION ------------------------------------------------------------
-- Fine = K2 x days after due date; same-day return = 0; stops at return date.
CREATE OR REPLACE FUNCTION fn_loan_fine(p_loan_id INT, p_as_of DATE)
RETURNS NUMERIC LANGUAGE plpgsql STABLE AS $$
DECLARE v_due DATE; v_ret DATE; v_end DATE;
BEGIN
    IF p_as_of IS NULL THEN
        RAISE EXCEPTION 'p_as_of is required';
    END IF;
    SELECT due_on, returned_on INTO v_due, v_ret FROM loans WHERE loan_id = p_loan_id;
    IF NOT FOUND THEN
        RAISE EXCEPTION 'Unknown loan_id: %', p_loan_id;
    END IF;
    v_end := LEAST(p_as_of, COALESCE(v_ret, p_as_of));
    RETURN 2 * GREATEST(v_end - v_due, 0);
END $$;

-- (c) PROCEDURE -----------------------------------------------------------
CREATE OR REPLACE PROCEDURE pr_return_loan(p_loan_id INT, p_returned_on DATE)
LANGUAGE plpgsql AS $$
DECLARE v_borrowed DATE; v_ret DATE; v_fine NUMERIC;
BEGIN
    IF p_returned_on IS NULL THEN
        RAISE EXCEPTION 'Return date is required';
    END IF;
    SELECT borrowed_on, returned_on INTO v_borrowed, v_ret
      FROM loans WHERE loan_id = p_loan_id FOR UPDATE;
    IF NOT FOUND THEN
        RAISE EXCEPTION 'Unknown loan_id: %', p_loan_id;
    END IF;
    IF v_ret IS NOT NULL THEN
        RAISE EXCEPTION 'Loan % was already returned on %', p_loan_id, v_ret;
    END IF;
    IF p_returned_on < v_borrowed THEN
        RAISE EXCEPTION 'Return date % is before borrow date %', p_returned_on, v_borrowed;
    END IF;
    v_fine := fn_loan_fine(p_loan_id, p_returned_on);   -- loan still open, so as_of = return date
    UPDATE loans SET returned_on = p_returned_on, fine_amount = v_fine   -- one statement: together
     WHERE loan_id = p_loan_id;
END $$;

-- (d) TRIGGER -------------------------------------------------------------
CREATE OR REPLACE FUNCTION trg_loan_audit() RETURNS TRIGGER LANGUAGE plpgsql AS $$
BEGIN
    INSERT INTO loan_audit (loan_id, old_returned_on, new_returned_on)
    VALUES (NEW.loan_id, OLD.returned_on, NEW.returned_on);
    RETURN NULL;
END $$;

CREATE TRIGGER trg_loans_returned_audit
AFTER UPDATE ON loans
FOR EACH ROW
WHEN (OLD.returned_on IS DISTINCT FROM NEW.returned_on)
EXECUTE FUNCTION trg_loan_audit();

-- (e) VIEW ----------------------------------------------------------------
CREATE OR REPLACE VIEW v_overdue_loans AS
SELECT l.loan_id, b.title, l.borrower_name, l.due_on,
       fn_loan_fine(l.loan_id, CURRENT_DATE) AS fine_as_of_today
FROM loans l
JOIN books b ON b.book_id = l.book_id
WHERE l.returned_on IS NULL AND l.due_on < CURRENT_DATE;

-- (f) INDEX ---------------------------------------------------------------
-- Partial index: only unreturned loans are indexed (small), keyed by book_id.
CREATE INDEX idx_loans_open_by_book ON loans (book_id) WHERE returned_on IS NULL;

-- (g) SCHEDULED JOB -------------------------------------------------------
-- Counts loans unreturned as of p_as_of (taken literally from the brief) and
-- sums their fines as of that date. Fines of not-yet-due loans are 0.
-- To count only overdue ones, add: AND due_on < p_as_of
CREATE OR REPLACE PROCEDURE pr_refresh_overdue(p_as_of DATE)
LANGUAGE plpgsql AS $$
BEGIN
    INSERT INTO overdue_summary (snapshot_date, overdue_count, total_fine)
    SELECT p_as_of, COUNT(*), COALESCE(SUM(fn_loan_fine(loan_id, p_as_of)), 0)
      FROM loans
     WHERE borrowed_on <= p_as_of
       AND (returned_on IS NULL OR returned_on > p_as_of)
    ON CONFLICT (snapshot_date) DO UPDATE
       SET overdue_count = EXCLUDED.overdue_count,
           total_fine    = EXCLUDED.total_fine;
END $$;

CREATE EXTENSION IF NOT EXISTS pg_cron;
SELECT cron.schedule('q3_refresh_overdue', '10 0 * * *',
                     $$CALL q3.pr_refresh_overdue(CURRENT_DATE)$$);

-- SEED DATA ---------------------------------------------------------------
INSERT INTO books (title) VALUES
 ('Database System Concepts'), ('Introduction to Algorithms'), ('Clean Code');

-- all six loans are created open; returned ones are closed via the procedure
INSERT INTO loans (book_id, borrower_name, borrowed_on, due_on) VALUES
 (1, 'Mulenga Chola',  CURRENT_DATE - 20, CURRENT_DATE - 6),   -- 1 open, overdue
 (2, 'Natasha Mumba',  CURRENT_DATE - 3,  CURRENT_DATE + 11),  -- 2 open, on time
 (3, 'Joseph Tembo',   CURRENT_DATE - 30, CURRENT_DATE - 16),  -- 3 returned late
 (1, 'Grace Lungu',    CURRENT_DATE - 25, CURRENT_DATE - 11),  -- 4 returned on due date
 (2, 'Peter Sakala',   CURRENT_DATE - 15, CURRENT_DATE - 5),   -- 5 open, overdue
 (3, 'Ruth Kabwe',     CURRENT_DATE - 10, CURRENT_DATE + 4);   -- 6 returned early

CALL pr_return_loan(3, CURRENT_DATE - 10);   -- 6 days late -> K12
CALL pr_return_loan(4, CURRENT_DATE - 11);   -- on due date -> K0
CALL pr_return_loan(6, CURRENT_DATE - 8);    -- early       -> K0

-- DEMONSTRATIONS ----------------------------------------------------------
SELECT loan_id, due_on, returned_on, fine_amount FROM loans ORDER BY 1;
SELECT loan_id, fn_loan_fine(loan_id, CURRENT_DATE) AS fine_today FROM loans ORDER BY 1;
SELECT * FROM loan_audit ORDER BY 1;                      -- 3 rows

DO $$ BEGIN CALL pr_return_loan(3, CURRENT_DATE);         -- already returned
EXCEPTION WHEN OTHERS THEN RAISE NOTICE 'Rejected: %', SQLERRM; END $$;
DO $$ BEGIN CALL pr_return_loan(1, CURRENT_DATE - 100);   -- before borrowed_on
EXCEPTION WHEN OTHERS THEN RAISE NOTICE 'Rejected: %', SQLERRM; END $$;
DO $$ BEGIN CALL pr_return_loan(999, CURRENT_DATE);       -- unknown
EXCEPTION WHEN OTHERS THEN RAISE NOTICE 'Rejected: %', SQLERRM; END $$;

-- no-change update creates no audit row
UPDATE loans SET returned_on = returned_on WHERE loan_id = 3;
SELECT COUNT(*) AS audit_rows_still_3 FROM loan_audit;

SELECT * FROM v_overdue_loans;                            -- loans 1 and 5

ANALYZE loans;
SET enable_seqscan = off;
EXPLAIN SELECT * FROM loans WHERE book_id = 1 AND returned_on IS NULL;
RESET enable_seqscan;

CALL pr_refresh_overdue(CURRENT_DATE);
CALL pr_refresh_overdue(CURRENT_DATE);                    -- replaces same snapshot_date
SELECT * FROM overdue_summary;
SELECT jobid, jobname, schedule, command FROM cron.job WHERE jobname = 'q3_refresh_overdue';
