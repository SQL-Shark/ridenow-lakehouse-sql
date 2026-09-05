-- ============================================================
-- 04_gold.sql : Star schema. fact_trip at trip grain, partitioned
-- logically by source_month; conformed dimensions from 02.
--
-- The fact holds foreign keys and measures only -- descriptive
-- attributes live in the dimensions, so a borough rename is a
-- one-row update rather than a fact rewrite.
-- ============================================================


-- fact_trip now carries surrogate keys for payment type and vendor rather
-- than raw codes. Column renames: payment_type -> payment_type_key,
-- vendor_id -> vendor_key. Values are unchanged; the codes ARE the keys.
create or replace table fact_trip as
select
    trip_sk,
    source_month,                             -- load partition, not a FK
    pickup_date         as pickup_date_key,   -- FK -> dim_date
    pickup_location_id  as pickup_zone_key,   -- FK -> dim_zone
    dropoff_location_id as dropoff_zone_key,  -- FK -> dim_zone (role-playing)
    payment_type        as payment_type_key,  -- FK -> dim_payment_type
    vendor_id           as vendor_key,        -- FK -> dim_vendor
    pickup_hour,
    -- Measures
    passenger_count,
    trip_distance,
    trip_minutes,
    fare_amount,
    tip_amount,
    total_amount
from silver_trips;
