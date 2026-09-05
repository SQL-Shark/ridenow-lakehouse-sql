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

-- 2. Rebuild only that month's slice of silver, fact and quarantine.
-- Quarantine is scoped and rebuilt alongside the others: leaving it untouched
-- would let a month's quarantine rows survive a reload that no longer produces
-- them, so the table would report referential failures that no longer exist.
delete from silver_trips     where source_month = getvariable('target_month');
delete from fact_trip        where source_month = getvariable('target_month');
delete from quarantine_trips where source_month = getvariable('target_month');

-- 3. Rebuild silver for the target month only, applying the same rules as 03.
insert into silver_trips
with cleaned as (
    select
        *,
        date_diff('minute', pickup_datetime, dropoff_datetime) as trip_minutes,
        cast(pickup_datetime as date)                          as pickup_date,
        extract(hour from pickup_datetime)                     as pickup_hour
    from raw_yellow_trips
    where source_month = getvariable('target_month')     -- scope to this load only
      and fare_amount  > 0
      and trip_distance between 0 and 100
      and dropoff_datetime > pickup_datetime
      and date_diff('minute', pickup_datetime, dropoff_datetime) between 0 and 300
),
keyed as (
    select
        *,
        md5(concat_ws('|',
            coalesce(pickup_datetime::varchar,     '_'),
            coalesce(dropoff_datetime::varchar,    '_'),
            coalesce(pickup_location_id::varchar,  '_'),
            coalesce(dropoff_location_id::varchar, '_'),
            coalesce(vendor_id::varchar,           '_'),
            coalesce(total_amount::varchar,        '_')
        )) as trip_sk
    from cleaned
),
deduped as (
    select * exclude (rn)
    from (select *, row_number() over (partition by trip_sk order by pickup_datetime) as rn
          from keyed)
    where rn = 1
)
-- Same three referential joins as 03_silver, including dim_date. If these ever
-- diverge from 03, an incrementally loaded month will differ from a fully
-- rebuilt one, which is the subtle failure this design is most exposed to.
select d.*
from deduped d
inner join dim_zone pu on d.pickup_location_id  = pu.location_id
inner join dim_zone dz on d.dropoff_location_id = dz.location_id
inner join dim_date dd on d.pickup_date         = dd.date_key;

-- 4. Project the new silver rows into the fact table.
insert into fact_trip
select
    trip_sk,
    source_month,
    pickup_date         as pickup_date_key,
    pickup_location_id  as pickup_zone_key,
    dropoff_location_id as dropoff_zone_key,
    payment_type        as payment_type_key,
    vendor_id           as vendor_key,
    pickup_hour,
    passenger_count,
    trip_distance,
    trip_minutes,
    fare_amount,
    tip_amount,
    total_amount
from silver_trips
where source_month = getvariable('target_month');

-- 5. Re-quarantine this month's unresolvable references, matching 03_silver's
-- definition. Built from raw so it measures the source, not the survivors.
insert into quarantine_trips
select
    r.*,
    case when pu.location_id is null then 'unknown_pickup_zone'          end,
    case when dz.location_id is null then 'unknown_dropoff_zone'         end,
    case when dd.date_key    is null then 'pickup_date_outside_calendar' end
from raw_yellow_trips r
left join dim_zone pu on r.pickup_location_id  = pu.location_id
left join dim_zone dz on r.dropoff_location_id = dz.location_id
left join dim_date dd on cast(r.pickup_datetime as date) = dd.date_key
where r.source_month = getvariable('target_month')
  and (pu.location_id is null or dz.location_id is null or dd.date_key is null);

commit;