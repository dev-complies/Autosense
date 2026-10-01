CREATE OR REPLACE FUNCTION public.autosense_network_trend()
RETURNS TABLE (bucket timestamptz, aqi numeric, pm25 numeric, pm10 numeric)
LANGUAGE sql STABLE SECURITY INVOKER SET search_path = public AS $$
  SELECT date_trunc('hour', recorded_at)
           + interval '30 min' * floor(extract(minute FROM recorded_at) / 30) AS bucket,
         round(avg(aqi)::numeric, 0),
         round(avg(pm25)::numeric, 0),
         round(avg(pm10)::numeric, 0)
  FROM public.device_readings
  WHERE recorded_at >= now() - interval '6 hours'
  GROUP BY 1 ORDER BY 1;
$$;

CREATE OR REPLACE FUNCTION public.autosense_device_trend(_device_id text)
RETURNS TABLE (bucket timestamptz, aqi numeric, pm25 numeric, pm10 numeric)
LANGUAGE sql STABLE SECURITY INVOKER SET search_path = public AS $$
  SELECT date_trunc('hour', recorded_at)
           + interval '30 min' * floor(extract(minute FROM recorded_at) / 30) AS bucket,
         round(avg(aqi)::numeric, 0),
         round(avg(pm25)::numeric, 0),
         round(avg(pm10)::numeric, 0)
  FROM public.device_readings
  WHERE device_id = _device_id AND recorded_at >= now() - interval '6 hours'
  GROUP BY 1 ORDER BY 1;
$$;

CREATE OR REPLACE FUNCTION public.autosense_area_trend(_lat double precision, _lng double precision, _radius_km double precision DEFAULT 25)
RETURNS TABLE (bucket timestamptz, aqi numeric, pm25 numeric, pm10 numeric, devices bigint)
LANGUAGE sql STABLE SECURITY INVOKER SET search_path = public AS $$
  SELECT date_trunc('hour', r.recorded_at)
           + interval '30 min' * floor(extract(minute FROM r.recorded_at) / 30) AS bucket,
         round(avg(r.aqi)::numeric, 0),
         round(avg(r.pm25)::numeric, 0),
         round(avg(r.pm10)::numeric, 0),
         count(DISTINCT r.device_id)
  FROM public.device_readings r
  JOIN public.devices d ON d.device_id = r.device_id
  WHERE r.recorded_at >= now() - interval '6 hours'
    AND 6371 * 2 * asin(sqrt(
          power(sin(radians(d.latitude - _lat) / 2), 2)
          + cos(radians(_lat)) * cos(radians(d.latitude))
          * power(sin(radians(d.longitude - _lng) / 2), 2)
        )) <= _radius_km
  GROUP BY 1 ORDER BY 1;
$$;

CREATE OR REPLACE FUNCTION public.autosense_zone_aqi()
RETURNS TABLE (zone text, aqi numeric, devices bigint)
LANGUAGE sql STABLE SECURITY INVOKER SET search_path = public AS $$
  SELECT location_name, round(avg(aqi)::numeric, 0), count(*)
  FROM public.devices
  WHERE aqi IS NOT NULL
  GROUP BY 1 ORDER BY 2 DESC;
$$;

GRANT EXECUTE ON FUNCTION public.autosense_network_trend() TO anon, authenticated, service_role;
GRANT EXECUTE ON FUNCTION public.autosense_device_trend(text) TO anon, authenticated, service_role;
GRANT EXECUTE ON FUNCTION public.autosense_area_trend(double precision, double precision, double precision) TO anon, authenticated, service_role;
GRANT EXECUTE ON FUNCTION public.autosense_zone_aqi() TO anon, authenticated, service_role;