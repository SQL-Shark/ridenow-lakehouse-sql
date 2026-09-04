-- ============================================================
-- 04_gold.sql : Star schema. fact_trip at trip grain, partitioned
-- logically by source_month; conformed dimensions from 02.
--
-- The fact holds foreign keys and measures only -- descriptive
-- attributes live in the dimensions, so a borough rename is a
-- one-row update rather than a fact rewrite.
-- ============================================================

create or replace table fact_trip as
select
    trip_sk,
    source_month,                     -- partition / load key
    pickup_date        as pickup_date_key,   -- FK -> dim_date
    pickup_location_id as pickup_zone_key,   -- FK -> dim_zone
    dropoff_location_id as dropoff_zone_key, -- FK -> dim_zone
    pickup_hour,
    vendor_id,
    payment_type,
    -- Measures
    passenger_count,
    trip_distance,
    trip_minutes,
    fare_amount,
    tip_amount,
    total_amount
from silver_trips;