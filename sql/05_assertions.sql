-- ============================================================
-- 05_assertions.sql : Fail-fast data quality gates.
--
-- DuckDB has no RAISE, so the idiom is a deliberate 1/0 on violation.
-- Ugly, but it aborts the script with a non-zero exit code, which
-- run.ps1 propagates. This is precisely where a framework like dbt
-- earns its keep -- noted in the README comparison.
-- ============================================================

-- 1. Not-null keys and timestamps
select case when count(*) > 0 then 1/0 else 0 end as assert_not_null_keys
from fact_trip
where trip_sk is null
   or pickup_date_key is null
   or pickup_zone_key is null
   or dropoff_zone_key is null;

-- 2. Uniqueness of the surrogate key
select case when count(*) > 0 then 1/0 else 0 end as assert_trip_sk_unique
from (select trip_sk from fact_trip group by 1 having count(*) > 1);

-- 3. Accepted values. 0 is UNDOCUMENTED in the TLC data dictionary but
--    represents ~7.8% of Jan-Mar 2024 trips -- see README.
select case when count(*) > 0 then 1/0 else 0 end as assert_payment_type
from fact_trip where payment_type not in (0,1,2,3,4,5,6);

-- 4. Ranges
select case when count(*) > 0 then 1/0 else 0 end as assert_ranges
from fact_trip
where trip_minutes  not between 0 and 300
   or trip_distance not between 0 and 100;

-- 5. Referential integrity to both dimensions
select case when count(*) > 0 then 1/0 else 0 end as assert_zone_fk
from fact_trip f
left join dim_zone z on f.pickup_zone_key = z.location_id
where z.location_id is null;

select case when count(*) > 0 then 1/0 else 0 end as assert_date_fk
from fact_trip f
left join dim_date d on f.pickup_date_key = d.date_key
where d.date_key is null;