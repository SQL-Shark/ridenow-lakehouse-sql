-- ============================================================
-- 07_incremental.sql : Add a month without a full reload.
--
-- Usage:  duckdb data/ridenow.duckdb -c "set variable target_month='2024-04';" ...
-- or edit the literal below. Kept simple deliberately.
--
-- Strategy: delete-then-insert scoped to one source_month.
-- Idempotent -- rerunning the same month yields identical row counts.
-- ============================================================

set variable target_month = '2024-04';

begin transaction;

-- 1. Land the new month into raw, replacing any prior attempt.
delete from raw_yellow_trips where source_month = getvariable('target_month');

insert into raw_yellow_trips
select
    regexp_extract(filename, '(\d{4}-\d{2})', 1),
    VendorID, tpep_pickup_datetime, tpep_dropoff_datetime,
    passenger_count, trip_distance, PULocationID, DOLocationID,
    payment_type, fare_amount, tip_amount, total_amount
from read_parquet('data/raw/yellow_tripdata_' || getvariable('target_month') || '.parquet',
                  filename = true);

-- 2. Rebuild only that month's slice of silver and fact.
delete from silver_trips where source_month = getvariable('target_month');
delete from fact_trip    where source_month = getvariable('target_month');

-- ... same cleaning/dedupe CTE as 03, filtered to the target month ...
-- ... then insert into fact_trip from the new silver rows ...

commit;