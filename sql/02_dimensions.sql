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


create or replace table dim_payment_type (
    payment_type_key   integer  primary key,
    payment_type_name  varchar  not null,
    is_metered         boolean  not null,   -- was the taximeter used?
    records_tip        boolean  not null    -- does a tip reach THIS feed?
);

insert into dim_payment_type values
    (0, 'Flex Fare',   false, false),  -- app-priced; tip paid in-app, not captured here
    (1, 'Credit card', true,  true ),  -- the only rail where the meter records the tip
    (2, 'Cash',        true,  false),  -- cash tips are never captured by the meter
    (3, 'No charge',   true,  false),
    (4, 'Dispute',     true,  false),
    (5, 'Unknown',     true,  false),
    (6, 'Voided trip', true,  false);


-- Vendor (TPEP provider) as a conformed dimension.
--
-- The value here is pinning down a name that has changed: code 2 reads as
-- "VeriFone Inc" in older published dictionaries and "Curb Mobility, LLC"
-- in the current one. Nothing in the data tells you that.
--
-- The full code domain is seeded, not just the codes observed in Jan-Apr
-- 2024. Seeding only what you have seen means the referential assertion
-- fails on perfectly valid data the first month a new vendor appears.
--
-- Observed in this dataset: 1 (3,180,948), 2 (9,677,360), 6 (798).
-- Code 7 is seeded but unused in this period.
create or replace table dim_vendor (
    vendor_key   integer  primary key,
    vendor_name  varchar  not null
);

insert into dim_vendor values
    (1, 'Creative Mobile Technologies, LLC'),
    (2, 'Curb Mobility, LLC'),
    (6, 'Myle Technologies Inc'),
    (7, 'Helix');