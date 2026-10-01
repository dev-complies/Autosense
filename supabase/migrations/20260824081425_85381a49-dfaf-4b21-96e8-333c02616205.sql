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
    WHERE status = 'active' AND is_moving AND is_simulated
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
  WHERE status = 'active' AND NOT is_moving AND is_simulated;

  UPDATE public.devices SET device_health = 'warning'
  WHERE status = 'active' AND battery_percentage < 20 AND device_health = 'good';

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
  WHERE d.status = 'active'
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
    WHERE d.status = 'active'
    ORDER BY random()
    LIMIT 1;
  END IF;

  DELETE FROM public.device_readings WHERE recorded_at < now() - interval '24 hours';
  DELETE FROM public.device_events WHERE created_at < now() - interval '6 hours';
END $$;

REVOKE ALL ON FUNCTION public.autosense_tick() FROM anon, authenticated, PUBLIC;
GRANT EXECUTE ON FUNCTION public.autosense_tick() TO service_role;