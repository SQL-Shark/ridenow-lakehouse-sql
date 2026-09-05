-- ============================================================
-- 01_raw.sql : Raw landing. No cleaning, no filtering.
-- Row counts here must match the source files exactly, so that
-- every row removed downstream can be attributed to a stated rule.
-- ============================================================

-- Explicit DDL rather than CTAS: declaring types is the point of the
-- SQL-first approach. Widen anything the source is inconsistent about.
create or replace table raw_yellow_trips (
    source_month          varchar   not null,   -- lineage: which file this came from
    vendor_id             bigint,
    pickup_datetime       timestamp,
    dropoff_datetime      timestamp,
    passenger_count       double,               -- nullable in source; double not int
    trip_distance         double,
    pickup_location_id    bigint,
    dropoff_location_id   bigint,
    payment_type          bigint,
    fare_amount           double,
    tip_amount            double,
    total_amount          double
);

insert into raw_yellow_trips
select
    -- Derived from the FILENAME, not the row timestamp. The January file
    -- contains trips that started on 31 Dec; partitioning on pickup_date
    -- would make the incremental load delete rows it shouldn't.
    regexp_extract(filename, '(\d{4}-\d{2})', 1)  as source_month,
    VendorID,
    tpep_pickup_datetime,
    tpep_dropoff_datetime,
    passenger_count,
    trip_distance,
    PULocationID,
    DOLocationID,
    payment_type,
    fare_amount,
    tip_amount,
    total_amount
from read_parquet('data/raw/yellow_tripdata_*.parquet',
                  union_by_name = true,   -- tolerate column drift between months
                  filename      = true);

-- Fail fast if the lineage extraction silently failed.
--
-- Two things to know here. regexp_extract returns an EMPTY STRING on no-match,
-- not null, so `is null` alone would never fire. And error() is what aborts:
-- 1/0 evaluates to inf in DuckDB and exits 0, so the obvious divide-by-zero
-- trick passes silently. See sql/05_assertions.sql for the same pattern.
select case when count(*) > 0
            then error('01_raw: source_month blank on ' || count(*)
                       || ' rows - filename lineage extraction failed')
            else 'ok' end as check_source_month_populated
from raw_yellow_trips
where source_month is null or source_month = '';