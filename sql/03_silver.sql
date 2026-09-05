-- ============================================================
-- 03_silver.sql : Cleaned, deduplicated, referentially valid trips.
--
-- Cleaning rules (from the brief):
--   fare_amount > 0
--   trip_distance 0-100        (observed max 312,722 mi -- meter fault)
--   dropoff > pickup
--   duration 0-300 minutes, inclusive
--
-- Invalid zone references are QUARANTINED, not dropped, so the volume
-- of bad references is measurable rather than invisible.
-- ============================================================

create or replace table silver_trips as
with cleaned as (
    select
        *,
        date_diff('minute', pickup_datetime, dropoff_datetime) as trip_minutes,
        cast(pickup_datetime as date)                          as pickup_date,
        extract(hour from pickup_datetime)                     as pickup_hour -- this is duckdb specific; other engines may require a different syntax
    from raw_yellow_trips
    where fare_amount  > 0
      and trip_distance between 0 and 100
      and dropoff_datetime > pickup_datetime
      and date_diff('minute', pickup_datetime, dropoff_datetime) between 0 and 300
),
keyed as (
    select
        *,
        -- Deterministic surrogate key. Same input always hashes the same,
        -- so a reload matches existing rows rather than duplicating them.
        -- coalesce guards concat_ws's null-skipping, which would otherwise
        -- make ('a', null, 'b') and ('a','b') collide.
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
    select * exclude (rn) -- drop the row_number column after filtering to the first row per trip_sk
    from (select *, row_number() over (partition by trip_sk order by pickup_datetime) as rn
          from keyed)
    where rn = 1
)
-- Referential integrity is enforced by the join, not asserted afterwards: a row
-- that cannot resolve every foreign key never reaches silver in the first place.
--
-- dim_date is joined for the same reason as dim_zone. A handful of source rows
-- carry junk pickup timestamps (2002, 2008, 2009 in the 2024 files) that pass
-- every cleaning rule above -- a 2002 trip can still have a positive fare and a
-- plausible duration -- and would otherwise land in the fact with no matching
-- calendar row. v_daily_metrics inner-joins dim_date, so they would silently
-- vanish from daily reporting while still inflating fact_trip's row count.
select d.*
from deduped d
inner join dim_zone pu on d.pickup_location_id  = pu.location_id
inner join dim_zone dz on d.dropoff_location_id = dz.location_id
inner join dim_date dd on d.pickup_date         = dd.date_key;


-- Rows failing referential integrity, retained for investigation.
-- Built from raw rather than from `cleaned`, so this measures the true volume of
-- unresolvable references in the source regardless of what the cleaning rules
-- would also have removed.
create or replace table quarantine_trips as
select
    r.*,
    case when pu.location_id is null then 'unknown_pickup_zone'          end as pickup_issue,
    case when dz.location_id is null then 'unknown_dropoff_zone'         end as dropoff_issue,
    case when dd.date_key    is null then 'pickup_date_outside_calendar' end as date_issue
from raw_yellow_trips r
left join dim_zone pu on r.pickup_location_id  = pu.location_id
left join dim_zone dz on r.dropoff_location_id = dz.location_id
left join dim_date dd on cast(r.pickup_datetime as date) = dd.date_key
where pu.location_id is null
   or dz.location_id is null
   or dd.date_key    is null;