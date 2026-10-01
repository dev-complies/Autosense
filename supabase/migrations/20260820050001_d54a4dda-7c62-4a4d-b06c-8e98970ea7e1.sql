ALTER TABLE public.devices ADD COLUMN IF NOT EXISTS area text;

UPDATE public.devices d
SET area = sub.area
FROM (
  SELECT device_id,
    CASE location_name
      WHEN 'Noida' THEN (ARRAY['Sector 62','Sector 18','Sector 137','Sector 51','Sector 15','Sector 94'])[1 + (abs(hashtext(device_id)) % 6)]
      WHEN 'Greater Noida' THEN (ARRAY['Alpha 1','Beta 2','Knowledge Park III','Pari Chowk','Omega 1'])[1 + (abs(hashtext(device_id)) % 5)]
      WHEN 'Delhi' THEN (ARRAY['Connaught Place','Anand Vihar','Dwarka Sector 8','Rohini Sector 7','Okhla Phase 2','Mayur Vihar'])[1 + (abs(hashtext(device_id)) % 6)]
      WHEN 'Ghaziabad' THEN (ARRAY['Indirapuram','Vasundhara','Raj Nagar Extension','Loni'])[1 + (abs(hashtext(device_id)) % 4)]
      WHEN 'Faridabad' THEN (ARRAY['Sector 16A','NIT Faridabad','Sector 30','Ballabgarh'])[1 + (abs(hashtext(device_id)) % 4)]
      WHEN 'Gurugram' THEN (ARRAY['Cyber City','Sector 29','Sohna Road','Udyog Vihar'])[1 + (abs(hashtext(device_id)) % 4)]
      ELSE 'Central'
    END AS area
  FROM public.devices
) sub
WHERE d.device_id = sub.device_id AND d.area IS NULL;

CREATE OR REPLACE FUNCTION public.autosense_zone_trend(_zone text)
RETURNS TABLE(bucket timestamptz, aqi numeric, pm25 numeric, pm10 numeric, devices bigint)
LANGUAGE sql
STABLE
SET search_path TO 'public'
AS $function$
  SELECT date_trunc('hour', r.recorded_at)
           + interval '30 min' * floor(extract(minute from r.recorded_at) / 30) AS bucket,
         round(avg(r.aqi)::numeric, 0),
         round(avg(r.pm25)::numeric, 1),
         round(avg(r.pm10)::numeric, 1),
         count(distinct r.device_id)
  FROM public.device_readings r
  JOIN public.devices d ON d.device_id = r.device_id
  WHERE r.recorded_at >= now() - interval '6 hours'
    AND r.aqi IS NOT NULL
    AND (_zone IS NULL OR d.location_name = _zone)
  GROUP BY 1
  ORDER BY 1;
$function$;

GRANT EXECUTE ON FUNCTION public.autosense_zone_trend(text) TO anon, authenticated, service_role;