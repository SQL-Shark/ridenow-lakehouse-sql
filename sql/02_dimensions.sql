-- ============================================================
-- 02_dimensions.sql : Conformed dimensions for the star schema.
-- Built before the fact so referential integrity can be enforced.
-- ============================================================

create or replace table dim_zone (
    location_id   integer primary key,
    borough       varchar not null,
    zone          varchar,
    service_zone  varchar
);

insert into dim_zone
select LocationID
, Borough
, Zone
, service_zone
from read_csv_auto('data/raw/taxi_zone_lookup.csv');

-- Date dimension at day grain, generated rather than derived from the facts.
-- Generating it means the calendar is complete even for days with no trips,
-- so time-series reports don't silently skip gaps.
create or replace table dim_date (
    date_key      date primary key,
    year          smallint,
    quarter       tinyint,
    month         tinyint,
    month_name    varchar,
    day_of_month  tinyint,
    iso_week      tinyint,
    day_of_week   tinyint,
    day_name      varchar,
    is_weekend    boolean
);

insert into dim_date
select
    d::date
    , extract(year    from d)
    , extract(quarter from d)
    , extract(month   from d)
    , strftime(d, '%B')
    , extract(day     from d)
    , extract(week    from d)
    , extract(dow     from d)
    , strftime(d, '%A')
    , extract(dow from d) in (0, 6)
from generate_series(date '2023-12-01', date '2024-12-31', interval 1 day) as t(d);