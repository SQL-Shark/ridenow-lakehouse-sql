-- ============================================================
-- 05_assertions.sql : Fail-fast data quality gates.
--
-- DuckDB has no RAISE, so the abort mechanism is error(), which throws an
-- Invalid Input Error and exits non-zero. run.ps1 propagates that and stops
-- the pipeline before the marts are built on bad data.
--
-- NOT 1/0. The obvious divide-by-zero trick does not work here: DuckDB's `/`
-- is floating-point, so 1/0 returns `inf` and exits 0, and integer division
-- 1//0 returns NULL and also exits 0. Both look like a passing gate. error()
-- is the only form that actually aborts, and it carries a readable message.
--
-- Each gate returns a short 'ok' string when it passes, so a clean run prints
-- a visible pass line per gate rather than a wall of zeroes.
-- ============================================================

-- 1. Not-null keys and timestamps
select case when count(*) > 0
            then error('assert_not_null_keys FAILED: ' || count(*) || ' fact rows with a null key')
            else 'assert_not_null_keys ok' end as assert_not_null_keys
from fact_trip
where trip_sk is null
   or pickup_date_key is null
   or pickup_zone_key is null
   or dropoff_zone_key is null;

-- 2. Uniqueness of the surrogate key
select case when count(*) > 0
            then error('assert_trip_sk_unique FAILED: ' || count(*) || ' duplicated trip_sk values')
            else 'assert_trip_sk_unique ok' end as assert_trip_sk_unique
from (select trip_sk from fact_trip group by 1 having count(*) > 1);

-- 3. Accepted values. 0 is UNDOCUMENTED in the TLC data dictionary but
--    represents ~4.7% of trips -- see README. It is seeded in
--    dim_payment_type as 'Flex Fare', so the accepted set is 0-6, not 1-6.
--    NB: the column is payment_type_key in the fact, not payment_type --
--    04_gold renames the raw code when it becomes a foreign key.
select case when count(*) > 0
            then error('assert_payment_type FAILED: ' || count(*) || ' rows outside payment_type 0-6')
            else 'assert_payment_type ok' end as assert_payment_type
from fact_trip where payment_type_key not in (0,1,2,3,4,5,6);

-- 4. Ranges
select case when count(*) > 0
            then error('assert_ranges FAILED: ' || count(*) || ' rows outside duration 0-300 or distance 0-100')
            else 'assert_ranges ok' end as assert_ranges
from fact_trip
where trip_minutes  not between 0 and 300
   or trip_distance not between 0 and 100;

-- 5. Referential integrity to every dimension.
--
-- These are belt-and-braces: 03_silver enforces each of them with an inner
-- join, so a violation here means the fact was built from something other
-- than silver, or a dimension was rebuilt narrower after the fact was loaded.
-- Cheap to run and they pin the star schema's central invariant.
select case when count(*) > 0
            then error('assert_zone_fk FAILED: ' || count(*) || ' fact rows with no matching pickup zone')
            else 'assert_zone_fk ok' end as assert_zone_fk
from fact_trip f
left join dim_zone z on f.pickup_zone_key = z.location_id
where z.location_id is null;

select case when count(*) > 0
            then error('assert_date_fk FAILED: ' || count(*) || ' fact rows with a pickup_date outside dim_date')
            else 'assert_date_fk ok' end as assert_date_fk
from fact_trip f
left join dim_date d on f.pickup_date_key = d.date_key
where d.date_key is null;

select case when count(*) > 0
            then error('assert_payment_type_fk FAILED: ' || count(*) || ' fact rows with an unseeded payment type')
            else 'assert_payment_type_fk ok' end as assert_payment_type_fk
from fact_trip f
left join dim_payment_type p on f.payment_type_key = p.payment_type_key
where p.payment_type_key is null;

select case when count(*) > 0
            then error('assert_vendor_fk FAILED: ' || count(*) || ' fact rows with an unseeded vendor')
            else 'assert_vendor_fk ok' end as assert_vendor_fk
from fact_trip f
left join dim_vendor v on f.vendor_key = v.vendor_key
where v.vendor_key is null;

-- 6. Dimension completeness. Cheap, and it catches a half-applied seed --
-- the failure mode where the create ran but the insert did not.
select case when count(*) <> 7
            then error('assert_dim_payment_type_seeded FAILED: expected 7 rows, found ' || count(*))
            else 'assert_dim_payment_type_seeded ok' end as assert_dim_payment_type_seeded
from dim_payment_type;

select case when count(*) <> 4
            then error('assert_dim_vendor_seeded FAILED: expected 4 rows, found ' || count(*))
            else 'assert_dim_vendor_seeded ok' end as assert_dim_vendor_seeded
from dim_vendor;
