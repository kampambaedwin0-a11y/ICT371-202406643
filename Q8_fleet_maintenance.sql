-- ICT371 Advanced Database | Question 8: Transport Fleet Maintenance
-- Student: Edwin Kampamba (202406643) | PostgreSQL 14+ with pg_cron
DROP SCHEMA IF EXISTS q8 CASCADE;
CREATE SCHEMA q8;
SET search_path TO q8, public;

-- (a) TABLES --------------------------------------------------------------
CREATE TABLE vehicles (
    vehicle_id            INT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    registration          VARCHAR(15) NOT NULL UNIQUE,
    current_odometer      INT NOT NULL CHECK (current_odometer >= 0),
    last_service_odometer INT NOT NULL CHECK (last_service_odometer >= 0),
    CONSTRAINT ck_service_le_current CHECK (last_service_odometer <= current_odometer)
);
CREATE TABLE trips (
    trip_id        INT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    vehicle_id     INT NOT NULL REFERENCES vehicles(vehicle_id),
    trip_on        DATE NOT NULL,
    start_odometer INT NOT NULL CHECK (start_odometer >= 0),
    end_odometer   INT NOT NULL CHECK (end_odometer   >= 0)
);
CREATE TABLE service_alerts (
    vehicle_id       INT PRIMARY KEY REFERENCES vehicles(vehicle_id),
    km_since_service INT NOT NULL,
    flagged_on       DATE NOT NULL DEFAULT CURRENT_DATE
);

-- (b) FUNCTION ------------------------------------------------------------
CREATE OR REPLACE FUNCTION fn_service_due(p_vehicle_id INT)
RETURNS BOOLEAN LANGUAGE plpgsql STABLE AS $$
DECLARE v_cur INT; v_last INT;
BEGIN
    SELECT current_odometer, last_service_odometer INTO v_cur, v_last
      FROM vehicles WHERE vehicle_id = p_vehicle_id;
    IF NOT FOUND THEN
        RAISE EXCEPTION 'Unknown vehicle_id: %', p_vehicle_id;
    END IF;
    RETURN (v_cur - v_last) >= 5000;
END $$;

-- (d) TRIGGER (installed before trips are loaded) -------------------------
-- The only place current_odometer is advanced, and it happens once per trip.
CREATE OR REPLACE FUNCTION trg_trip_odometer() RETURNS TRIGGER LANGUAGE plpgsql AS $$
DECLARE v_cur INT;
BEGIN
    IF NEW.start_odometer IS NULL OR NEW.end_odometer IS NULL OR NEW.start_odometer < 0 THEN
        RAISE EXCEPTION 'Odometer readings are required and must be non-negative';
    END IF;
    IF NEW.end_odometer <= NEW.start_odometer THEN
        RAISE EXCEPTION 'end_odometer (%) must be greater than start_odometer (%)',
                        NEW.end_odometer, NEW.start_odometer;
    END IF;
    SELECT current_odometer INTO v_cur FROM vehicles
     WHERE vehicle_id = NEW.vehicle_id FOR UPDATE;      -- lock: trips on one vehicle are serial
    IF NOT FOUND THEN
        RAISE EXCEPTION 'Unknown vehicle_id: %', NEW.vehicle_id;
    END IF;
    IF NEW.start_odometer <> v_cur THEN
        RAISE EXCEPTION 'Trip must start at the current odometer % (got %)', v_cur, NEW.start_odometer;
    END IF;
    UPDATE vehicles SET current_odometer = NEW.end_odometer WHERE vehicle_id = NEW.vehicle_id;
    RETURN NEW;
END $$;

CREATE TRIGGER trg_trips_odometer
BEFORE INSERT ON trips
FOR EACH ROW EXECUTE FUNCTION trg_trip_odometer();

-- (c) PROCEDURE -----------------------------------------------------------
-- Does NOT touch vehicles; the trigger does that.
CREATE OR REPLACE PROCEDURE pr_record_trip(p_vehicle_id INT, p_trip_on DATE, p_start INT, p_end INT)
LANGUAGE plpgsql AS $$
BEGIN
    IF NOT EXISTS (SELECT 1 FROM vehicles WHERE vehicle_id = p_vehicle_id) THEN
        RAISE EXCEPTION 'Unknown vehicle_id: %', p_vehicle_id;
    END IF;
    IF p_trip_on IS NULL OR p_start IS NULL OR p_end IS NULL THEN
        RAISE EXCEPTION 'Trip date and odometer values are required';
    END IF;
    IF p_end <= p_start THEN
        RAISE EXCEPTION 'end_odometer (%) must be greater than start_odometer (%)', p_end, p_start;
    END IF;
    INSERT INTO trips (vehicle_id, trip_on, start_odometer, end_odometer)
    VALUES (p_vehicle_id, p_trip_on, p_start, p_end);
END $$;

-- (e) VIEW ----------------------------------------------------------------
CREATE OR REPLACE VIEW v_service_due AS
SELECT registration, current_odometer - last_service_odometer AS km_since_service
FROM vehicles
WHERE current_odometer - last_service_odometer >= 5000;

-- (f) INDEX ---------------------------------------------------------------
-- vehicle_id (equality) then trip_on (range): one vehicle's trips for a date
-- range are contiguous and already ordered in the index.
CREATE INDEX idx_trips_vehicle_trip_on ON trips (vehicle_id, trip_on);

-- (g) SCHEDULED JOB -------------------------------------------------------
CREATE OR REPLACE PROCEDURE pr_refresh_service_alerts()
LANGUAGE plpgsql AS $$
BEGIN
    -- insert new alerts / refresh km on existing ones (original flagged_on kept)
    INSERT INTO service_alerts (vehicle_id, km_since_service, flagged_on)
    SELECT vehicle_id, current_odometer - last_service_odometer, CURRENT_DATE
      FROM vehicles
     WHERE current_odometer - last_service_odometer >= 5000
    ON CONFLICT (vehicle_id) DO UPDATE SET km_since_service = EXCLUDED.km_since_service;

    -- remove alerts for vehicles that are no longer due (e.g. after service)
    DELETE FROM service_alerts sa
     WHERE NOT EXISTS (SELECT 1 FROM vehicles v
                        WHERE v.vehicle_id = sa.vehicle_id
                          AND v.current_odometer - v.last_service_odometer >= 5000);
END $$;

CREATE EXTENSION IF NOT EXISTS pg_cron;
SELECT cron.schedule('q8_refresh_service_alerts', '0 6 * * 1', $$CALL q8.pr_refresh_service_alerts()$$);

-- SEED DATA ---------------------------------------------------------------
INSERT INTO vehicles (registration, current_odometer, last_service_odometer) VALUES
 ('ABC 1234', 10000,  4000),    -- already overdue for service
 ('BCD 5678', 20000, 18000),    -- recently serviced
 ('CDE 9012',  4000,     0);    -- will end exactly on the 5,000 km boundary

CALL pr_record_trip(1, CURRENT_DATE - 6, 10000, 10300);
CALL pr_record_trip(1, CURRENT_DATE - 3, 10300, 10800);
CALL pr_record_trip(2, CURRENT_DATE - 5, 20000, 20400);
CALL pr_record_trip(2, CURRENT_DATE - 2, 20400, 21000);
CALL pr_record_trip(3, CURRENT_DATE - 4,  4000,  4600);
CALL pr_record_trip(3, CURRENT_DATE - 1,  4600,  5000);

-- DEMONSTRATIONS ----------------------------------------------------------
SELECT * FROM vehicles ORDER BY 1;                      -- 10800, 21000, 5000
SELECT vehicle_id, fn_service_due(vehicle_id) FROM vehicles ORDER BY 1;   -- true, false, true
SELECT * FROM v_service_due;                            -- vehicles 1 and 3

DO $$ BEGIN CALL pr_record_trip(1, CURRENT_DATE, 9999, 10500);   -- wrong start
EXCEPTION WHEN OTHERS THEN RAISE NOTICE 'Rejected by trigger: %', SQLERRM; END $$;
DO $$ BEGIN CALL pr_record_trip(1, CURRENT_DATE, 10800, 10800);  -- end not > start
EXCEPTION WHEN OTHERS THEN RAISE NOTICE 'Rejected: %', SQLERRM; END $$;
DO $$ BEGIN CALL pr_record_trip(99, CURRENT_DATE, 0, 10);        -- unknown vehicle
EXCEPTION WHEN OTHERS THEN RAISE NOTICE 'Rejected: %', SQLERRM; END $$;
DO $$ BEGIN PERFORM fn_service_due(99);
EXCEPTION WHEN OTHERS THEN RAISE NOTICE 'Rejected: %', SQLERRM; END $$;

CALL pr_refresh_service_alerts();
SELECT * FROM service_alerts ORDER BY 1;                -- vehicles 1 and 3

-- vehicle 1 is serviced -> alert must disappear on the next run
UPDATE vehicles SET last_service_odometer = current_odometer WHERE vehicle_id = 1;
CALL pr_refresh_service_alerts();
SELECT * FROM service_alerts ORDER BY 1;                -- only vehicle 3

ANALYZE trips;
SET enable_seqscan = off;
EXPLAIN SELECT * FROM trips
WHERE vehicle_id = 1 AND trip_on BETWEEN CURRENT_DATE - 30 AND CURRENT_DATE;
RESET enable_seqscan;

SELECT jobid, jobname, schedule, command FROM cron.job WHERE jobname = 'q8_refresh_service_alerts';
