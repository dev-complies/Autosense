ALTER TABLE public.devices ADD COLUMN IF NOT EXISTS decommissioned_at timestamptz;

CREATE INDEX IF NOT EXISTS devices_decommissioned_idx ON public.devices (decommissioned_at);

-- Simulation: skip retired nodes, keep longer history for reports.
CREATE OR REPLACE FUNCTION public.autosense_tick()
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  moved record;
BEGIN
  FOR moved IN
    SELECT device_id, latitude, longitude, heading, speed, battery_percentage, aqi
    FROM public.devices
    WHERE status = 'active' AND is_moving AND is_simulated AND decommissioned_at IS NULL
  LOOP
    UPDATE public.devices SET
      heading = ((moved.heading + (random() - 0.5) * 18) + 360)::numeric % 360,
      speed = greatest(8, least(78, moved.speed + round(((random() - 0.5) * 8)::numeric, 0))),
      latitude = moved.latitude + (moved.speed * 0.0028 / 111.0) * cos(radians(moved.heading)),
      longitude = moved.longitude + (moved.speed * 0.0028 / (111.0 * cos(radians(moved.latitude)))) * sin(radians(moved.heading)),
      aqi = greatest(22, least(340, moved.aqi + round(((random() - 0.5) * 7)::numeric)::int)),
      pm25 = round((greatest(22, least(340, moved.aqi)) * 0.48)::numeric, 0),
      pm10 = round((greatest(22, least(340, moved.aqi)) * 0.79)::numeric, 0),
      battery_percentage = CASE
        WHEN random() < 0.12 THEN greatest(3, moved.battery_percentage - 1)
        ELSE moved.battery_percentage END,
      last_updated = now()
    WHERE device_id = moved.device_id;
  END LOOP;

  UPDATE public.devices SET
    aqi = greatest(22, least(340, aqi + round(((random() - 0.5) * 5)::numeric)::int)),
    pm25 = round((aqi * 0.48)::numeric, 0),
    pm10 = round((aqi * 0.79)::numeric, 0),
    last_updated = now()
  WHERE status = 'active' AND NOT is_moving AND is_simulated AND decommissioned_at IS NULL;

  UPDATE public.devices SET device_health = 'warning'
  WHERE status = 'active' AND battery_percentage < 20 AND device_health = 'good'
    AND decommissioned_at IS NULL;

  INSERT INTO public.device_readings (
    device_id, recorded_at, latitude, longitude, aqi, pm25, pm10,
    temperature, humidity, battery_percentage, speed
  )
  SELECT d.device_id, now(), d.latitude, d.longitude, d.aqi, d.pm25, d.pm10,
         d.temperature, d.humidity, d.battery_percentage, d.speed
  FROM public.devices d
  LEFT JOIN (
    SELECT device_id, max(recorded_at) AS last_at
    FROM public.device_readings GROUP BY device_id
  ) r ON r.device_id = d.device_id
  WHERE d.status = 'active' AND d.decommissioned_at IS NULL
    AND (r.last_at IS NULL OR r.last_at < now() - interval '5 minutes');

  IF random() < 0.3 THEN
    INSERT INTO public.device_events (device_id, event_type, message, severity)
    SELECT d.device_id,
           CASE WHEN d.battery_percentage < 20 THEN 'battery' ELSE 'movement' END,
           CASE WHEN d.battery_percentage < 20
                THEN d.device_id || ' battery below 20%'
                ELSE d.device_id || ' is moving through ' || d.location_name END,
           CASE WHEN d.battery_percentage < 20 THEN 'warning' ELSE 'info' END
    FROM public.devices d
    WHERE d.status = 'active' AND d.decommissioned_at IS NULL
    ORDER BY random()
    LIMIT 1;
  END IF;

  DELETE FROM public.device_readings WHERE recorded_at < now() - interval '35 days';
  DELETE FROM public.device_events WHERE created_at < now() - interval '30 days';
END $$;

REVOKE ALL ON FUNCTION public.autosense_tick() FROM anon, authenticated, PUBLIC;
GRANT EXECUTE ON FUNCTION public.autosense_tick() TO service_role;

-- Backfill 30 days of hourly history so week / month reports have data.
DO $$
DECLARE
  d record;
  h integer;
  r_time timestamptz;
  r_aqi integer;
  base_aqi integer;
BEGIN
  PERFORM setseed(0.7171);
  FOR d IN SELECT device_id, latitude, longitude, aqi, temperature, humidity, battery_percentage, is_moving FROM public.devices LOOP
    base_aqi := coalesce(d.aqi, 90);
    FOR h IN 7..720 LOOP
      r_time := now() - (h || ' hours')::interval;
      r_aqi := greatest(20, least(340, base_aqi
        + round((sin(h / 3.8) * 26 + sin(h / 26.0) * 34 + (random() - 0.5) * 20))::int));
      INSERT INTO public.device_readings (
        device_id, recorded_at, latitude, longitude, aqi, pm25, pm10,
        temperature, humidity, battery_percentage, speed
      ) VALUES (
        d.device_id,
        r_time,
        d.latitude + (random() - 0.5) * 0.01,
        d.longitude + (random() - 0.5) * 0.01,
        r_aqi,
        round((r_aqi * 0.48)::numeric, 0),
        round((r_aqi * 0.79)::numeric, 0),
        round((coalesce(d.temperature, 30) + (random() - 0.5) * 6)::numeric, 0),
        round((coalesce(d.humidity, 55) + (random() - 0.5) * 12)::numeric, 0),
        least(100, greatest(5, d.battery_percentage + (h % 40))),
        CASE WHEN d.is_moving THEN round((10 + random() * 50)::numeric, 0) ELSE 0 END
      );
    END LOOP;
  END LOOP;
END $$;

-- Report helpers (admin/server use only).
CREATE OR REPLACE FUNCTION public.autosense_device_report_buckets(
  _device_id text,
  _hours integer,
  _bucket_minutes integer
)
RETURNS TABLE (
  bucket timestamptz,
  aqi numeric,
  pm25 numeric,
  pm10 numeric,
  temperature numeric,
  humidity numeric,
  battery numeric,
  speed numeric,
  samples bigint
)
LANGUAGE sql STABLE SECURITY DEFINER SET search_path = public AS $$
  SELECT to_timestamp(floor(extract(epoch FROM r.recorded_at) / (_bucket_minutes * 60)) * (_bucket_minutes * 60)) AS bucket,
         round(avg(r.aqi)::numeric, 0),
         round(avg(r.pm25)::numeric, 1),
         round(avg(r.pm10)::numeric, 1),
         round(avg(r.temperature)::numeric, 1),
         round(avg(r.humidity)::numeric, 1),
         round(avg(r.battery_percentage)::numeric, 0),
         round(avg(r.speed)::numeric, 1),
         count(*)
  FROM public.device_readings r
  WHERE r.device_id = _device_id
    AND r.recorded_at >= now() - (_hours || ' hours')::interval
  GROUP BY 1
  ORDER BY 1;
$$;

CREATE OR REPLACE FUNCTION public.autosense_device_report_summary(
  _device_id text,
  _hours integer
)
RETURNS TABLE (
  samples bigint,
  first_at timestamptz,
  last_at timestamptz,
  avg_aqi numeric,
  min_aqi numeric,
  max_aqi numeric,
  avg_pm25 numeric,
  max_pm25 numeric,
  avg_pm10 numeric,
  max_pm10 numeric,
  avg_temperature numeric,
  min_temperature numeric,
  max_temperature numeric,
  avg_humidity numeric,
  min_battery numeric,
  max_battery numeric,
  avg_speed numeric,
  max_speed numeric
)
LANGUAGE sql STABLE SECURITY DEFINER SET search_path = public AS $$
  SELECT count(*),
         min(r.recorded_at),
         max(r.recorded_at),
         round(avg(r.aqi)::numeric, 0),
         min(r.aqi)::numeric,
         max(r.aqi)::numeric,
         round(avg(r.pm25)::numeric, 1),
         max(r.pm25)::numeric,
         round(avg(r.pm10)::numeric, 1),
         max(r.pm10)::numeric,
         round(avg(r.temperature)::numeric, 1),
         min(r.temperature)::numeric,
         max(r.temperature)::numeric,
         round(avg(r.humidity)::numeric, 1),
         min(r.battery_percentage)::numeric,
         max(r.battery_percentage)::numeric,
         round(avg(r.speed)::numeric, 1),
         max(r.speed)::numeric
  FROM public.device_readings r
  WHERE r.device_id = _device_id
    AND r.recorded_at >= now() - (_hours || ' hours')::interval;
$$;

REVOKE ALL ON FUNCTION public.autosense_device_report_buckets(text, integer, integer) FROM anon, authenticated, PUBLIC;
REVOKE ALL ON FUNCTION public.autosense_device_report_summary(text, integer) FROM anon, authenticated, PUBLIC;
GRANT EXECUTE ON FUNCTION public.autosense_device_report_buckets(text, integer, integer) TO service_role;
GRANT EXECUTE ON FUNCTION public.autosense_device_report_summary(text, integer) TO service_role;