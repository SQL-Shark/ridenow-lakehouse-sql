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





create or replace view v_tip_rate_by_borough_hour as
select
    z.borough,
    f.pickup_hour,
    count(*)                                                     as trips,
    -- How often: share of trips carrying any tip at all.
    round(100.0 * count(*) filter (where f.tip_amount > 0)
        / count(*), 1)                                           as tip_incidence_pct,
    -- How much: tip as a share of fare, among trips that tipped.
    round(100.0 * sum(f.tip_amount)  filter (where f.tip_amount > 0)
        / nullif(sum(f.fare_amount)  filter (where f.tip_amount > 0), 0), 2)
                                                                 as tip_rate_when_tipped_pct,
    -- Retained for continuity with the naive metric. Do not report alone.
    round(100.0 * sum(f.tip_amount) / nullif(sum(f.fare_amount), 0), 2)
                                                                 as blended_tip_rate_pct
from fact_trip f
join dim_zone         z on f.pickup_zone_key   = z.location_id
join dim_payment_type p on f.payment_type_key  = p.payment_type_key
where p.records_tip
  -- 'N/A' and 'Unknown' are real rows in the TLC zone lookup, so they pass
  -- referential validation, but they are meaningless in a borough cut.
  -- Excluded here at the mart, not in silver, so the rows stay available.
  and z.borough not in ('N/A', 'Unknown')
group by 1, 2
-- Small groups produce nonsense rates: Staten Island had a 146% rate on two
-- trips before this threshold. Suppress rather than caveat.
having count(*) >= 100
order by 1, 2;


-- Payment mix by month, now with names instead of codes.
create or replace view v_payment_share as
select
    f.source_month,
    p.payment_type_name,
    count(*)                                                  as trips,
    round(100.0 * count(*) / sum(count(*)) over (partition by f.source_month), 2)
                                                              as share_pct
from fact_trip f
join dim_payment_type p on f.payment_type_key = p.payment_type_key
group by 1, 2
order by 1, 4 desc;


-- Volume by vendor. Small, but it surfaces the 798-trip third vendor that
-- is invisible in every other aggregate.
create or replace view v_vendor_share as
select
    v.vendor_name,
    count(*)                                                  as trips,
    round(100.0 * count(*) / sum(count(*)) over (), 4)        as share_pct
from fact_trip f
join dim_vendor v on f.vendor_key = v.vendor_key
group by 1
order by 2 desc;
