-- ICT371 Advanced Database | Question 4: Clinic Appointment Scheduling
-- Student: Edwin Kampamba (202406643) | PostgreSQL 14+ with pg_cron
DROP SCHEMA IF EXISTS q4 CASCADE;
CREATE SCHEMA q4;
SET search_path TO q4, public;

-- (a) TABLES --------------------------------------------------------------
CREATE TABLE patients (
    patient_id INT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    full_name  VARCHAR(100) NOT NULL
);
CREATE TABLE doctors (
    doctor_id INT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    full_name VARCHAR(100) NOT NULL
);
CREATE TABLE appointments (
    appointment_id  INT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    patient_id      INT NOT NULL REFERENCES patients(patient_id),
    doctor_id       INT NOT NULL REFERENCES doctors(doctor_id),
    appointment_day DATE NOT NULL,
    slot_time       TIME NOT NULL,
    status          VARCHAR(10) NOT NULL DEFAULT 'BOOKED',
    CONSTRAINT ck_status CHECK (status IN ('BOOKED','ATTENDED','CANCELLED')),
    CONSTRAINT ck_slot   CHECK (slot_time IN ('09:00','10:00','11:00','12:00'))
);
-- Safety net for concurrent sessions (a row trigger alone cannot see
-- uncommitted rows of another transaction). The trigger below gives the
-- friendly error message; this partial unique index guarantees the rule.
CREATE UNIQUE INDEX uq_active_slot ON appointments (doctor_id, appointment_day, slot_time)
WHERE status <> 'CANCELLED';

CREATE TABLE clinic_summary (
    summary_date    DATE PRIMARY KEY,
    booked_count    INT NOT NULL,
    attended_count  INT NOT NULL,
    cancelled_count INT NOT NULL
);

-- (d) TRIGGER (created before seed data so every insert is checked) -------
CREATE OR REPLACE FUNCTION trg_appointment_clash() RETURNS TRIGGER LANGUAGE plpgsql AS $$
BEGIN
    IF NEW.status <> 'CANCELLED' AND EXISTS (
        SELECT 1 FROM appointments a
         WHERE a.doctor_id       = NEW.doctor_id
           AND a.appointment_day = NEW.appointment_day
           AND a.slot_time       = NEW.slot_time
           AND a.status         <> 'CANCELLED'
           AND a.appointment_id <> COALESCE(NEW.appointment_id, -1)  -- exclude the row being changed
    ) THEN
        RAISE EXCEPTION 'Doctor % already has an appointment on % at %',
                        NEW.doctor_id, NEW.appointment_day, NEW.slot_time;
    END IF;
    RETURN NEW;
END $$;

CREATE TRIGGER trg_appointments_clash
BEFORE INSERT OR UPDATE ON appointments
FOR EACH ROW EXECUTE FUNCTION trg_appointment_clash();

-- (b) FUNCTION ------------------------------------------------------------
CREATE OR REPLACE FUNCTION fn_daily_load(p_doctor_id INT, p_day DATE)
RETURNS INT LANGUAGE plpgsql STABLE AS $$
DECLARE v_count INT;
BEGIN
    IF NOT EXISTS (SELECT 1 FROM doctors WHERE doctor_id = p_doctor_id) THEN
        RAISE EXCEPTION 'Unknown doctor_id: %', p_doctor_id;
    END IF;
    SELECT COUNT(*) INTO v_count FROM appointments
     WHERE doctor_id = p_doctor_id AND appointment_day = p_day AND status <> 'CANCELLED';
    RETURN v_count;                                   -- 0 when no bookings
END $$;

-- (c) PROCEDURE -----------------------------------------------------------
CREATE OR REPLACE PROCEDURE pr_book_appointment(p_patient_id INT, p_doctor_id INT, p_day DATE, p_slot TIME)
LANGUAGE plpgsql AS $$
BEGIN
    IF NOT EXISTS (SELECT 1 FROM patients WHERE patient_id = p_patient_id) THEN
        RAISE EXCEPTION 'Unknown patient_id: %', p_patient_id;
    END IF;
    IF NOT EXISTS (SELECT 1 FROM doctors WHERE doctor_id = p_doctor_id) THEN
        RAISE EXCEPTION 'Unknown doctor_id: %', p_doctor_id;
    END IF;
    IF p_day IS NULL OR p_day < CURRENT_DATE THEN
        RAISE EXCEPTION 'Appointment date % is in the past or missing', p_day;
    END IF;
    IF p_slot IS NULL OR p_slot NOT IN ('09:00','10:00','11:00','12:00') THEN
        RAISE EXCEPTION 'Unsupported slot: % (use 09:00, 10:00, 11:00 or 12:00)', p_slot;
    END IF;
    INSERT INTO appointments (patient_id, doctor_id, appointment_day, slot_time, status)
    VALUES (p_patient_id, p_doctor_id, p_day, p_slot, 'BOOKED');   -- trigger checks the clash
END $$;

-- (e) VIEW ----------------------------------------------------------------
-- Only name and slot columns are exposed; no IDs or other patient data.
CREATE OR REPLACE VIEW v_today_appointments AS
SELECT p.full_name AS patient_name, d.full_name AS doctor_name, a.slot_time
FROM appointments a
JOIN patients p ON p.patient_id = a.patient_id
JOIN doctors  d ON d.doctor_id  = a.doctor_id
WHERE a.appointment_day = CURRENT_DATE AND a.status = 'BOOKED'
ORDER BY a.slot_time;

-- (f) INDEX ---------------------------------------------------------------
-- Non-unique (a day can hold up to four appointments per doctor, and cancelled
-- rows share slots). Day first, then doctor: serves day-only and day+doctor searches.
CREATE INDEX idx_appointments_day_doctor ON appointments (appointment_day, doctor_id);

-- (g) SCHEDULED JOB -------------------------------------------------------
CREATE OR REPLACE PROCEDURE pr_refresh_clinic_summary(p_day DATE)
LANGUAGE plpgsql AS $$
BEGIN
    INSERT INTO clinic_summary (summary_date, booked_count, attended_count, cancelled_count)
    SELECT p_day,
           COUNT(*) FILTER (WHERE status = 'BOOKED'),
           COUNT(*) FILTER (WHERE status = 'ATTENDED'),
           COUNT(*) FILTER (WHERE status = 'CANCELLED')
      FROM appointments WHERE appointment_day = p_day
    ON CONFLICT (summary_date) DO UPDATE
       SET booked_count    = EXCLUDED.booked_count,
           attended_count  = EXCLUDED.attended_count,
           cancelled_count = EXCLUDED.cancelled_count;
END $$;

CREATE EXTENSION IF NOT EXISTS pg_cron;
SELECT cron.schedule('q4_refresh_clinic_summary', '0 1 * * *',
                     $$CALL q4.pr_refresh_clinic_summary(CURRENT_DATE - 1)$$);

-- SEED DATA ---------------------------------------------------------------
INSERT INTO patients (full_name) VALUES ('Alice Mwila'), ('Brian Kasonde'), ('Cynthia Nkole');
INSERT INTO doctors  (full_name) VALUES ('Dr. Banda'), ('Dr. Chileshe'), ('Dr. Daka');

-- past / today rows inserted directly (the procedure rejects past dates)
INSERT INTO appointments (patient_id, doctor_id, appointment_day, slot_time, status) VALUES
 (1, 1, CURRENT_DATE - 1, '09:00', 'ATTENDED'),
 (2, 1, CURRENT_DATE - 1, '10:00', 'CANCELLED'),
 (3, 1, CURRENT_DATE - 1, '10:00', 'ATTENDED'),   -- reuses a cancelled slot: allowed
 (1, 2, CURRENT_DATE,     '09:00', 'BOOKED');
-- future rows go through the procedure
CALL pr_book_appointment(2, 2, CURRENT_DATE + 1, '10:00');
CALL pr_book_appointment(3, 3, CURRENT_DATE + 1, '11:00');

-- DEMONSTRATIONS ----------------------------------------------------------
SELECT * FROM appointments ORDER BY 1;
SELECT fn_daily_load(1, CURRENT_DATE - 1) AS load_dr1_yesterday,   -- 2 (cancelled ignored)
       fn_daily_load(3, CURRENT_DATE + 5) AS load_no_bookings;     -- 0

DO $$ BEGIN CALL pr_book_appointment(1, 2, CURRENT_DATE + 1, '10:00');   -- clash
EXCEPTION WHEN OTHERS THEN RAISE NOTICE 'Rejected: %', SQLERRM; END $$;
DO $$ BEGIN CALL pr_book_appointment(1, 2, CURRENT_DATE - 1, '10:00');   -- past
EXCEPTION WHEN OTHERS THEN RAISE NOTICE 'Rejected: %', SQLERRM; END $$;
DO $$ BEGIN CALL pr_book_appointment(1, 2, CURRENT_DATE + 2, '13:00');   -- bad slot
EXCEPTION WHEN OTHERS THEN RAISE NOTICE 'Rejected: %', SQLERRM; END $$;
DO $$ BEGIN CALL pr_book_appointment(99, 2, CURRENT_DATE + 2, '09:00');  -- unknown patient
EXCEPTION WHEN OTHERS THEN RAISE NOTICE 'Rejected: %', SQLERRM; END $$;

-- UPDATE: moving appointment 4 onto its own slot is fine (excluded from search)...
UPDATE appointments SET status = 'BOOKED' WHERE appointment_id = 4;
-- ...but moving it onto another booked slot is rejected
DO $$ BEGIN UPDATE appointments SET doctor_id = 2, appointment_day = CURRENT_DATE + 1,
                                    slot_time = '10:00' WHERE appointment_id = 4;
EXCEPTION WHEN OTHERS THEN RAISE NOTICE 'Rejected: %', SQLERRM; END $$;

SELECT * FROM v_today_appointments;

ANALYZE appointments;
SET enable_seqscan = off;
EXPLAIN SELECT * FROM appointments WHERE appointment_day = CURRENT_DATE AND doctor_id = 2;
RESET enable_seqscan;

CALL pr_refresh_clinic_summary(CURRENT_DATE - 1);
CALL pr_refresh_clinic_summary(CURRENT_DATE - 1);          -- replaced, not duplicated
SELECT * FROM clinic_summary;
SELECT jobid, jobname, schedule, command FROM cron.job WHERE jobname = 'q4_refresh_clinic_summary';
