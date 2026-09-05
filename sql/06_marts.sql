-- ============================================================
-- 06_marts.sql : Business outputs.
-- ============================================================

-- Revenue = total_amount (fares, tips, tolls, surcharges), i.e. money
-- taken, not meter charge. Stated explicitly because the alternative
-- (fare_amount) gives a materially different number.
create or replace view v_daily_metrics as
select
    d.date_key,
    d.day_name,
    d.is_weekend,
    count(*)                        as trips,
    round(sum(f.total_amount), 2)   as revenue,
    -- Zero-distance trips excluded from the RATIO only, not the trip count.
    round(sum(f.fare_amount)  filter (where f.trip_distance > 0)
        / nullif(sum(f.trip_distance) filter (where f.trip_distance > 0), 0), 2)
                                    as avg_fare_per_mile
from fact_trip f
join dim_date d on f.pickup_date_key = d.date_key
group by 1,2,3
order by 1;

-- Card payments only (type 1). Cash tips aren't captured by the meter, and
-- type 0 -- flex fare tips, 7.8% of trips -- shows a tipping profile matching
-- neither (21% tipped, avg $0.94 vs 94.9% / $4.21 for card). Excluded.
-- Rate is sum(tips)/sum(fares), NOT avg of per-row ratios: the latter
-- over-weights cheap trips and answers a different question.
create or replace view v_tip_rate_by_borough_hour as
select
    z.borough,
    f.pickup_hour,
    count(*)                                                          as card_trips,
    round(100.0 * sum(f.tip_amount) / nullif(sum(f.fare_amount), 0), 2) as tip_rate_pct
from fact_trip f
join dim_zone z on f.pickup_zone_key = z.location_id
where f.payment_type = 1
group by 1,2
order by 1,2;

-- Top 10 O-D pairs per month.
create or replace view v_top_od_pairs as
select source_month, pickup_zone, dropoff_zone, trips
from (
    select
        f.source_month,
        pu.zone as pickup_zone,
        dz.zone as dropoff_zone,
        count(*) as trips,
        row_number() over (partition by f.source_month order by count(*) desc) as rk
    from fact_trip f
    join dim_zone pu on f.pickup_zone_key  = pu.location_id
    join dim_zone dz on f.dropoff_zone_key = dz.location_id
    group by 1,2,3
)
where rk <= 10
order by source_month, trips desc;

-- Card vs cash share by month.
create or replace view v_payment_share as
select
    source_month,
    round(100.0 * count(*) filter (where payment_type = 1) / count(*), 2) as card_pct,
    round(100.0 * count(*) filter (where payment_type = 2) / count(*), 2) as cash_pct,
    round(100.0 * count(*) filter (where payment_type = 0) / count(*), 2) as flex_pct
from fact_trip
group by 1 order by 1;