-- ICT371 Q7: Water Meter Readings and Billing  (PostgreSQL 14+, pg_cron)
CREATE EXTENSION IF NOT EXISTS pg_cron;

DROP TABLE IF EXISTS receivable_snapshot, bills, readings, customers CASCADE;

-- (a) Tables
CREATE TABLE customers (
  customer_id INT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  full_name   VARCHAR(100) NOT NULL
);
CREATE TABLE readings (
  reading_id       INT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  customer_id      INT NOT NULL REFERENCES customers(customer_id),
  reading_month    DATE NOT NULL,
  previous_reading NUMERIC(10,2) NOT NULL CHECK (previous_reading >= 0),
  current_reading  NUMERIC(10,2) NOT NULL CHECK (current_reading >= 0),
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

-- (d) Trigger: rejected rows are never stored
CREATE OR REPLACE FUNCTION trg_check_reading() RETURNS TRIGGER AS $$
BEGIN
  IF NEW.current_reading < NEW.previous_reading THEN
    RAISE EXCEPTION 'current_reading (%) is below previous_reading (%)',
      NEW.current_reading, NEW.previous_reading;
  END IF;
  RETURN NEW;
END;
$$ LANGUAGE plpgsql;

CREATE TRIGGER trg_readings_check
BEFORE INSERT OR UPDATE ON readings
FOR EACH ROW EXECUTE FUNCTION trg_check_reading();

INSERT INTO customers (full_name) VALUES ('Alice Mulenga'), ('Brian Tembo'), ('Chola Mumba');

-- Six readings: units = 0, 10 (exactly), 15, 25, 4, 10
INSERT INTO readings (customer_id, reading_month, previous_reading, current_reading) VALUES
  (1, DATE '2026-09-01', 100, 100),   -- 0 units
  (1, DATE '2026-10-01', 100, 110),   -- 10 units
  (2, DATE '2026-09-01',  50,  65),   -- 15 units
  (2, DATE '2026-10-01',  65,  90),   -- 25 units
  (3, DATE '2026-09-01',  20,  24),   -- 4 units
  (3, DATE '2026-10-01',  24,  34);   -- 10 units
-- Test (rejected, nothing stored):
-- INSERT INTO readings (customer_id, reading_month, previous_reading, current_reading)
-- VALUES (3, DATE '2026-11-01', 34, 30);

-- (b) Function: first 10 units K5, above 10 K8
CREATE OR REPLACE FUNCTION fn_water_charge(p_units NUMERIC) RETURNS NUMERIC(12,2) AS $$
BEGIN
  IF p_units IS NULL OR p_units < 0 THEN
    RAISE EXCEPTION 'Invalid consumption: %', p_units;
  END IF;
  RETURN ROUND(LEAST(p_units, 10) * 5 + GREATEST(p_units - 10, 0) * 8, 2)::NUMERIC(12,2);
END;
$$ LANGUAGE plpgsql IMMUTABLE;
-- SELECT fn_water_charge(0), fn_water_charge(10), fn_water_charge(15);  -- 0.00, 50.00, 90.00

-- (c) Procedure
CREATE OR REPLACE PROCEDURE pr_generate_bill(p_reading_id INT, p_due_on DATE)
LANGUAGE plpgsql AS $$
DECLARE v_units NUMERIC;
BEGIN
  IF p_due_on IS NULL THEN
    RAISE EXCEPTION 'Due date must not be NULL';
  END IF;
  SELECT current_reading - previous_reading INTO v_units
  FROM readings WHERE reading_id = p_reading_id;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'Unknown reading_id %', p_reading_id;
  END IF;
  IF EXISTS (SELECT 1 FROM bills WHERE reading_id = p_reading_id) THEN
    RAISE EXCEPTION 'Reading % already has a bill', p_reading_id;
  END IF;
  INSERT INTO bills (reading_id, charge, amount_paid, due_on)
  VALUES (p_reading_id, fn_water_charge(v_units), 0, p_due_on);
END;
$$;

-- Bills: some overdue, some not
CALL pr_generate_bill(1, CURRENT_DATE - 40);
CALL pr_generate_bill(2, CURRENT_DATE - 10);
CALL pr_generate_bill(3, CURRENT_DATE - 20);
CALL pr_generate_bill(4, CURRENT_DATE + 10);
CALL pr_generate_bill(5, CURRENT_DATE - 5);
CALL pr_generate_bill(6, CURRENT_DATE + 15);
UPDATE bills SET amount_paid = charge WHERE reading_id = 5;      -- fully paid
UPDATE bills SET amount_paid = 40     WHERE reading_id = 3;      -- partly paid
-- Tests: CALL pr_generate_bill(1, CURRENT_DATE);  CALL pr_generate_bill(99, CURRENT_DATE);  -- errors

-- (e) View
CREATE OR REPLACE VIEW v_overdue_bills AS
SELECT c.full_name AS customer_name, b.due_on, b.charge - b.amount_paid AS outstanding_amount
FROM bills b
JOIN readings r  ON r.reading_id  = b.reading_id
JOIN customers c ON c.customer_id = r.customer_id
WHERE b.due_on < CURRENT_DATE AND b.amount_paid < b.charge;

SELECT * FROM v_overdue_bills;

-- (f) Partial index on due_on for unpaid bills only
CREATE INDEX idx_bills_unpaid_due ON bills (due_on) WHERE amount_paid < charge;
-- Justification: overdue searches only need unpaid bills, sorted/ranged by due date.
-- Paid bills (the majority over time) are left out, keeping the index small and fast.
ANALYZE bills;
SET enable_seqscan = off;
EXPLAIN SELECT * FROM bills WHERE due_on < CURRENT_DATE AND amount_paid < charge;
RESET enable_seqscan;

-- (g) Snapshot procedure
CREATE OR REPLACE PROCEDURE pr_refresh_receivables()
LANGUAGE plpgsql AS $$
BEGIN
  INSERT INTO receivable_snapshot (snapshot_date, total_due)
  SELECT CURRENT_DATE, COALESCE(SUM(charge - amount_paid), 0)
  FROM bills WHERE amount_paid < charge
  ON CONFLICT (snapshot_date) DO UPDATE SET total_due = EXCLUDED.total_due;
END;
$$;

SELECT cron.schedule('refresh_receivables_daily', '30 0 * * *',
  $cron$CALL pr_refresh_receivables()$cron$);

CALL pr_refresh_receivables();
CALL pr_refresh_receivables();   -- same-date rerun replaces the total
SELECT * FROM receivable_snapshot;
