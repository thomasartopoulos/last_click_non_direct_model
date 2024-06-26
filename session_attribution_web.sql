-- We declare todays_date as a global variable
DECLARE today_date STRING;
SET today_date = FORMAT_DATE("%Y%m%d", (DATE(CURRENT_DATE())));


WITH
t1 AS
(SELECT
event_date,
event_timestamp,
user_pseudo_id,
concat(user_pseudo_id, (select value.int_value from unnest(event_params) where key = 'ga_session_id')) as real_session_id,
(select value.int_value from unnest(event_params) where key = 'ga_session_id') as ga_session_id,
event_name,
ROW_NUMBER() OVER (PARTITION BY user_pseudo_id ORDER BY event_timestamp) AS event_number,
(select
   as struct (select value.string_value from unnest(event_params) where key = 'source') as source,
   (select value.string_value from unnest(event_params) where key = 'medium') as medium,
   (select value.string_value from unnest(event_params) where key = 'campaign') as campaign,
   (select value.string_value from unnest(event_params) where key = 'gclid') as gclid) as traffic_source,
FROM `TABLE.events_*`
WHERE regexp_extract(_table_suffix,'[0-9]+') between FORMAT_DATE("%Y%m%d", DATE_SUB(CURRENT_DATE(), INTERVAL 30 DAY)) -- cambiamos fecha
AND today_date
AND stream_id='' -- Filter by Web Stream
AND concat(user_pseudo_id, (select value.int_value from unnest(event_params) where key = 'ga_session_id')) IS NOT NULL
AND event_name NOT IN ('first_visit', 'session_start')
),


t2 AS
(SELECT
event_date,
user_pseudo_id,
real_session_id,
ga_session_id,
array_agg(
if(
coalesce(traffic_source.source,traffic_source.medium,traffic_source.campaign,traffic_source.gclid) is not null,
  (
    select
      as struct if(traffic_source.gclid is not null, 'google', traffic_source.source) as source,
        if(traffic_source.gclid is not null, 'cpc', traffic_source.medium) as medium,
        traffic_source.campaign,
        traffic_source.gclid
  ),
  null
) ignore nulls
order by
  event_number asc
limit
  1
) [safe_offset(0)] as session_first_traffic_source,

array_agg(
if(
  coalesce(traffic_source.source,traffic_source.medium,traffic_source.campaign,traffic_source.gclid) is not null,
  (
    select
      as struct if(traffic_source.gclid is not null, 'google', traffic_source.source) as source,
        if(traffic_source.gclid is not null, 'cpc', traffic_source.medium) as medium,
        traffic_source.campaign,
        traffic_source.gclid
  ),
  null
) ignore nulls
order by
  event_number desc
limit
  1
) [safe_offset(0)] as session_last_traffic_source
FROM t1
GROUP BY 1,2,3,4),

t3 AS
(SELECT
*,
IFNULL(session_first_traffic_source,LAST_VALUE(session_last_traffic_source IGNORE NULLS) OVER(PARTITION BY user_pseudo_id ORDER BY ga_session_id)) AS attribution
FROM t2)

SELECT
CONCAT(attribution.source,' / ', attribution.medium) AS source_medium,
COUNT(DISTINCT(real_session_id)) AS session_count,
FROM t3
WHERE event_date=today_date
GROUP BY 1
ORDER BY session_count desc
