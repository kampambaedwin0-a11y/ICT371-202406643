-- ICT371 Advanced Database | Question 5: Hostel Room Allocation
-- Student: Edwin Kampamba (202406643) | PostgreSQL 14+ with pg_cron
DROP SCHEMA IF EXISTS q5 CASCADE;
CREATE SCHEMA q5;
SET search_path TO q5, public;

-- (a) TABLES --------------------------------------------------------------
CREATE TABLE students (
    student_id     INT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    student_number VARCHAR(20) NOT NULL UNIQUE,
    full_name      VARCHAR(100) NOT NULL
);
CREATE TABLE rooms (
    room_id     INT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    room_number VARCHAR(10) NOT NULL UNIQUE,
    capacity    INT NOT NULL CHECK (capacity > 0)
);
CREATE TABLE allocations (
    allocation_id INT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    student_id    INT NOT NULL REFERENCES students(student_id),
    room_id       INT NOT NULL REFERENCES rooms(room_id),
    allocated_on  DATE NOT NULL,
    released_on   DATE NULL,
    status        VARCHAR(10) NOT NULL,
    CONSTRAINT ck_alloc_status CHECK (status IN ('ACTIVE','ENDED')),
    CONSTRAINT ck_alloc_release CHECK (
        (status = 'ACTIVE' AND released_on IS NULL) OR
        (status = 'ENDED'  AND released_on IS NOT NULL AND released_on >= allocated_on))
);
-- Concurrency safety net for "one ACTIVE allocation per student"
CREATE UNIQUE INDEX uq_one_active_per_student ON allocations (student_id) WHERE status = 'ACTIVE';

CREATE TABLE occupancy_snapshot (
    snapshot_date DATE NOT NULL,
    room_id       INT  NOT NULL REFERENCES rooms(room_id),
    occupied_beds INT  NOT NULL,
    free_beds     INT  NOT NULL,
    PRIMARY KEY (snapshot_date, room_id)
);

-- (b) FUNCTION ------------------------------------------------------------
CREATE OR REPLACE FUNCTION fn_free_beds(p_room_id INT)
RETURNS INT LANGUAGE plpgsql STABLE AS $$
DECLARE v_cap INT; v_active INT;
BEGIN
    SELECT capacity INTO v_cap FROM rooms WHERE room_id = p_room_id;
    IF NOT FOUND THEN
        RAISE EXCEPTION 'Unknown room_id: %', p_room_id;
    END IF;
    SELECT COUNT(*) INTO v_active FROM allocations
     WHERE room_id = p_room_id AND status = 'ACTIVE';     -- ENDED rows ignored
    RETURN v_cap - v_active;
END $$;

-- (d) TRIGGER (installed before any allocation is loaded) -----------------
CREATE OR REPLACE FUNCTION trg_allocation_rules() RETURNS TRIGGER LANGUAGE plpgsql AS $$
DECLARE v_cap INT; v_others INT;
BEGIN
    IF NEW.status = 'ACTIVE' THEN
        PERFORM 1 FROM rooms WHERE room_id = NEW.room_id FOR UPDATE;   -- serialise per room

        IF EXISTS (SELECT 1 FROM allocations a
                    WHERE a.student_id = NEW.student_id AND a.status = 'ACTIVE'
                      AND a.allocation_id <> COALESCE(NEW.allocation_id, -1)) THEN
            RAISE EXCEPTION 'Student % already has an ACTIVE allocation', NEW.student_id;
        END IF;

        SELECT capacity INTO v_cap FROM rooms WHERE room_id = NEW.room_id;
        SELECT COUNT(*) INTO v_others FROM allocations a
         WHERE a.room_id = NEW.room_id AND a.status = 'ACTIVE'
           AND a.allocation_id <> COALESCE(NEW.allocation_id, -1);   -- exclude row being updated
        IF v_others >= v_cap THEN
            RAISE EXCEPTION 'Room % is full (capacity %)', NEW.room_id, v_cap;
        END IF;
    END IF;
    RETURN NEW;
END $$;

CREATE TRIGGER trg_allocations_rules
BEFORE INSERT OR UPDATE ON allocations
FOR EACH ROW EXECUTE FUNCTION trg_allocation_rules();

-- (c) PROCEDURE -----------------------------------------------------------
CREATE OR REPLACE PROCEDURE pr_allocate_room(p_student_id INT, p_room_id INT, p_allocated_on DATE)
LANGUAGE plpgsql AS $$
BEGIN
    IF p_allocated_on IS NULL THEN
        RAISE EXCEPTION 'Allocation date is required';
    END IF;
    IF NOT EXISTS (SELECT 1 FROM students WHERE student_id = p_student_id) THEN
        RAISE EXCEPTION 'Unknown student_id: %', p_student_id;
    END IF;
    PERFORM 1 FROM rooms WHERE room_id = p_room_id FOR UPDATE;
    IF NOT FOUND THEN
        RAISE EXCEPTION 'Unknown room_id: %', p_room_id;
    END IF;
    IF EXISTS (SELECT 1 FROM allocations WHERE student_id = p_student_id AND status = 'ACTIVE') THEN
        RAISE EXCEPTION 'Student % already has an ACTIVE allocation', p_student_id;
    END IF;
    IF fn_free_beds(p_room_id) <= 0 THEN
        RAISE EXCEPTION 'Room % has no free beds', p_room_id;
    END IF;
    INSERT INTO allocations (student_id, room_id, allocated_on, released_on, status)
    VALUES (p_student_id, p_room_id, p_allocated_on, NULL, 'ACTIVE');
END $$;

-- (e) VIEW ----------------------------------------------------------------
CREATE OR REPLACE VIEW v_room_occupancy AS
SELECT r.room_id, r.room_number, r.capacity,
       COUNT(a.allocation_id)              AS occupied_beds,
       r.capacity - COUNT(a.allocation_id) AS free_beds
FROM rooms r
LEFT JOIN allocations a ON a.room_id = r.room_id AND a.status = 'ACTIVE'  -- condition in ON keeps empty rooms
GROUP BY r.room_id, r.room_number, r.capacity;

-- (f) INDEX ---------------------------------------------------------------
-- Partial index on room_id covering only ACTIVE rows: ENDED history (which grows
-- forever) is not indexed, so occupancy counts stay small and fast.
CREATE INDEX idx_alloc_active_room ON allocations (room_id) WHERE status = 'ACTIVE';

-- (g) SCHEDULED JOB -------------------------------------------------------
CREATE OR REPLACE PROCEDURE pr_refresh_occupancy()
LANGUAGE plpgsql AS $$
BEGIN
    INSERT INTO occupancy_snapshot (snapshot_date, room_id, occupied_beds, free_beds)
    SELECT CURRENT_DATE, room_id, occupied_beds, free_beds FROM v_room_occupancy
    ON CONFLICT (snapshot_date, room_id) DO UPDATE
       SET occupied_beds = EXCLUDED.occupied_beds,
           free_beds     = EXCLUDED.free_beds;
END $$;

CREATE EXTENSION IF NOT EXISTS pg_cron;
SELECT cron.schedule('q5_refresh_occupancy', '55 23 * * *', $$CALL q5.pr_refresh_occupancy()$$);

-- SEED DATA ---------------------------------------------------------------
INSERT INTO students (student_number, full_name) VALUES
 ('2024101','Mutale Kunda'), ('2024102','Bwalya Mubanga'), ('2024103','Esther Siame'),
 ('2024104','Kelvin Mwape'), ('2024105','Lombe Chanda');
INSERT INTO rooms (room_number, capacity) VALUES ('101',2), ('102',3), ('103',2);

CALL pr_allocate_room(1, 1, CURRENT_DATE - 60);   -- room 101 full
CALL pr_allocate_room(2, 1, CURRENT_DATE - 60);
CALL pr_allocate_room(3, 2, CURRENT_DATE - 30);   -- room 102 partly occupied
-- history: student 4 lived in room 103 and has left (room 103 is empty)
INSERT INTO allocations (student_id, room_id, allocated_on, released_on, status)
VALUES (4, 3, CURRENT_DATE - 200, CURRENT_DATE - 100, 'ENDED');

-- DEMONSTRATIONS ----------------------------------------------------------
SELECT fn_free_beds(1) AS full_room, fn_free_beds(2) AS partly, fn_free_beds(3) AS empty_room;  -- 0, 2, 2
SELECT * FROM v_room_occupancy ORDER BY room_id;

DO $$ BEGIN CALL pr_allocate_room(5, 1, CURRENT_DATE);        -- room full
EXCEPTION WHEN OTHERS THEN RAISE NOTICE 'Rejected: %', SQLERRM; END $$;
DO $$ BEGIN CALL pr_allocate_room(3, 3, CURRENT_DATE);        -- already ACTIVE elsewhere
EXCEPTION WHEN OTHERS THEN RAISE NOTICE 'Rejected: %', SQLERRM; END $$;
DO $$ BEGIN CALL pr_allocate_room(99, 3, CURRENT_DATE);       -- unknown student
EXCEPTION WHEN OTHERS THEN RAISE NOTICE 'Rejected: %', SQLERRM; END $$;
-- direct SQL is also protected by the trigger
DO $$ BEGIN INSERT INTO allocations (student_id, room_id, allocated_on, status)
            VALUES (5, 1, CURRENT_DATE, 'ACTIVE');
EXCEPTION WHEN OTHERS THEN RAISE NOTICE 'Rejected by trigger: %', SQLERRM; END $$;
DO $$ BEGIN INSERT INTO allocations (student_id, room_id, allocated_on, status)
            VALUES (1, 2, CURRENT_DATE, 'ACTIVE');
EXCEPTION WHEN OTHERS THEN RAISE NOTICE 'Rejected by trigger: %', SQLERRM; END $$;

CALL pr_allocate_room(5, 3, CURRENT_DATE);                    -- valid
SELECT * FROM v_room_occupancy ORDER BY room_id;

ANALYZE allocations;
SET enable_seqscan = off;
EXPLAIN SELECT * FROM allocations WHERE room_id = 1 AND status = 'ACTIVE';
RESET enable_seqscan;

CALL pr_refresh_occupancy();
CALL pr_refresh_occupancy();                                  -- same rows replaced
SELECT * FROM occupancy_snapshot ORDER BY snapshot_date, room_id;
SELECT jobid, jobname, schedule, command FROM cron.job WHERE jobname = 'q5_refresh_occupancy';
