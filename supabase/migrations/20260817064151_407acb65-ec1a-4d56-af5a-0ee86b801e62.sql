CREATE TABLE public.devices (
  device_id text PRIMARY KEY,
  device_name text NOT NULL,
  status text NOT NULL DEFAULT 'active' CHECK (status IN ('active','inactive','faulted')),
  battery_percentage integer NOT NULL DEFAULT 100 CHECK (battery_percentage BETWEEN 0 AND 100),
  latitude double precision NOT NULL,
  longitude double precision NOT NULL,
  heading double precision NOT NULL DEFAULT 0,
  aqi integer,
  pm25 numeric,
  pm10 numeric,
  temperature numeric,
  humidity numeric,
  is_moving boolean NOT NULL DEFAULT false,
  speed numeric NOT NULL DEFAULT 0,
  vehicle_id text,
  vehicle_status text CHECK (vehicle_status IN ('moving','stopped')),
  location_name text NOT NULL DEFAULT 'Unknown',
  device_health text NOT NULL DEFAULT 'good' CHECK (device_health IN ('good','warning','fault')),
  connection_status text NOT NULL DEFAULT 'online' CHECK (connection_status IN ('online','offline')),
  is_simulated boolean NOT NULL DEFAULT true,
  last_updated timestamptz NOT NULL DEFAULT now(),
  created_at timestamptz NOT NULL DEFAULT now()
);

CREATE TABLE public.device_readings (
  id bigserial PRIMARY KEY,
  device_id text NOT NULL REFERENCES public.devices(device_id) ON DELETE CASCADE,
  recorded_at timestamptz NOT NULL DEFAULT now(),
  latitude double precision,
  longitude double precision,
  aqi integer,
  pm25 numeric,
  pm10 numeric,
  temperature numeric,
  humidity numeric,
  battery_percentage integer,
  speed numeric
);

CREATE INDEX device_readings_device_time_idx ON public.device_readings (device_id, recorded_at DESC);
CREATE INDEX device_readings_time_idx ON public.device_readings (recorded_at DESC);

CREATE TABLE public.device_events (
  id bigserial PRIMARY KEY,
  device_id text NOT NULL,
  event_type text NOT NULL,
  message text NOT NULL,
  severity text NOT NULL DEFAULT 'info' CHECK (severity IN ('info','warning','critical')),
  created_at timestamptz NOT NULL DEFAULT now()
);

CREATE INDEX device_events_time_idx ON public.device_events (created_at DESC);

GRANT SELECT ON public.devices TO anon, authenticated;
GRANT SELECT ON public.device_readings TO anon, authenticated;
GRANT SELECT ON public.device_events TO anon, authenticated;
GRANT ALL ON public.devices TO service_role;
GRANT ALL ON public.device_readings TO service_role;
GRANT ALL ON public.device_events TO service_role;
GRANT USAGE, SELECT ON SEQUENCE public.device_readings_id_seq TO service_role;
GRANT USAGE, SELECT ON SEQUENCE public.device_events_id_seq TO service_role;

ALTER TABLE public.devices ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.device_readings ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.device_events ENABLE ROW LEVEL SECURITY;

CREATE POLICY "Device network is publicly readable" ON public.devices FOR SELECT USING (true);
CREATE POLICY "Device readings are publicly readable" ON public.device_readings FOR SELECT USING (true);
CREATE POLICY "Device events are publicly readable" ON public.device_events FOR SELECT USING (true);

DO $$
DECLARE
  zones text[] := ARRAY['Ghaziabad','Noida','Greater Noida','Delhi','Faridabad'];
  zone_lat double precision[] := ARRAY[28.6692, 28.5355, 28.4744, 28.6139, 28.4089];
  zone_lng double precision[] := ARRAY[77.4538, 77.3910, 77.5040, 77.2090, 77.3178];
  i integer;
  z integer;
  d_status text;
  d_health text;
  d_conn text;
  d_battery integer;
  d_moving boolean;
  d_vehicle text;
  d_vehicle_status text;
  d_speed numeric;
  d_aqi integer;
  d_lat double precision;
  d_lng double precision;
  d_temp numeric;
  d_hum numeric;
  t integer;
  r_aqi integer;
  r_time timestamptz;
BEGIN
  PERFORM setseed(0.4242);

  FOR i IN 1..50 LOOP
    z := 1 + (i % 5);
    d_lat := zone_lat[z] + (random() - 0.5) * 0.16;
    d_lng := zone_lng[z] + (random() - 0.5) * 0.16;

    IF i <= 42 THEN d_status := 'active';
    ELSIF i <= 47 THEN d_status := 'inactive';
    ELSE d_status := 'faulted';
    END IF;

    -- 6 devices below 20% battery
    IF i IN (5, 12, 19, 28, 44, 49) THEN
      d_battery := 6 + floor(random() * 13)::int;
    ELSE
      d_battery := 34 + floor(random() * 62)::int;
    END IF;

    -- devices 1..35 are mounted on vehicles; 1..27 are moving
    IF i <= 35 THEN
      d_vehicle := 'VH-' || lpad(i::text, 3, '0');
      d_moving := i <= 27;
      d_vehicle_status := CASE WHEN d_moving THEN 'moving' ELSE 'stopped' END;
      d_speed := CASE WHEN d_moving THEN round((14 + random() * 52)::numeric, 0) ELSE 0 END;
    ELSE
      d_vehicle := NULL;
      d_moving := false;
      d_vehicle_status := NULL;
      d_speed := 0;
    END IF;

    IF d_status = 'faulted' THEN
      d_health := 'fault';
      d_conn := 'offline';
    ELSIF d_status = 'inactive' THEN
      d_health := CASE WHEN i IN (44, 45) THEN 'warning' ELSE 'good' END;
      d_conn := 'offline';
    ELSE
      d_health := CASE WHEN d_battery < 20 OR i IN (7, 23) THEN 'warning' ELSE 'good' END;
      d_conn := 'online';
    END IF;

    d_aqi := 48 + floor(random() * 165)::int;
    d_temp := round((26 + random() * 12)::numeric, 0);
    d_hum := round((38 + random() * 40)::numeric, 0);

    INSERT INTO public.devices (
      device_id, device_name, status, battery_percentage, latitude, longitude, heading,
      aqi, pm25, pm10, temperature, humidity, is_moving, speed, vehicle_id, vehicle_status,
      location_name, device_health, connection_status, last_updated
    ) VALUES (
      'AS-' || lpad(i::text, 3, '0'),
      'AutoSense Node ' || lpad(i::text, 3, '0'),
      d_status,
      d_battery,
      round(d_lat::numeric, 5)::double precision,
      round(d_lng::numeric, 5)::double precision,
      round((random() * 360)::numeric, 1)::double precision,
      d_aqi,
      round((d_aqi * 0.48 + random() * 8)::numeric, 0),
      round((d_aqi * 0.79 + random() * 12)::numeric, 0),
      d_temp,
      d_hum,
      d_moving,
      d_speed,
      d_vehicle,
      d_vehicle_status,
      zones[z],
      d_health,
      d_conn,
      now() - (floor(random() * 90) || ' seconds')::interval
    );

    -- 6 hours of half-hourly history (13 points, oldest first)
    FOR t IN 0..12 LOOP
      r_time := now() - ((12 - t) * 30 || ' minutes')::interval;
      r_aqi := greatest(20, least(320, d_aqi + round((sin(t / 2.2) * 16 + (random() - 0.5) * 14))::int - (12 - t)));
      INSERT INTO public.device_readings (
        device_id, recorded_at, latitude, longitude, aqi, pm25, pm10,
        temperature, humidity, battery_percentage, speed
      ) VALUES (
        'AS-' || lpad(i::text, 3, '0'),
        r_time,
        round((d_lat - (12 - t) * 0.0015)::numeric, 5)::double precision,
        round((d_lng - (12 - t) * 0.0012)::numeric, 5)::double precision,
        r_aqi,
        round((r_aqi * 0.48)::numeric, 0),
        round((r_aqi * 0.79)::numeric, 0),
        round((d_temp + (random() - 0.5) * 3)::numeric, 0),
        round((d_hum + (random() - 0.5) * 6)::numeric, 0),
        least(100, d_battery + (12 - t)),
        CASE WHEN d_moving THEN round((10 + random() * 50)::numeric, 0) ELSE 0 END
      );
    END LOOP;
  END LOOP;
END $$;

INSERT INTO public.device_events (device_id, event_type, message, severity, created_at) VALUES
  ('AS-014','movement','AS-014 started moving','info', now() - interval '1 minute'),
  ('AS-021','battery','AS-021 battery below 20%','warning', now() - interval '4 minutes'),
  ('AS-008','connection','AS-008 connection restored','info', now() - interval '9 minutes'),
  ('AS-032','fault','AS-032 reported fault','critical', now() - interval '14 minutes'),
  ('AS-017','geofence','AS-017 entered Noida','info', now() - interval '22 minutes'),
  ('AS-005','battery','AS-005 battery below 20%','warning', now() - interval '31 minutes'),
  ('AS-044','connection','AS-044 went offline','warning', now() - interval '48 minutes');