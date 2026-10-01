UPDATE public.devices SET device_health = 'good' WHERE device_health = 'warning';
UPDATE public.devices SET device_health = 'warning' WHERE device_id IN ('AS-005','AS-012','AS-019','AS-028','AS-044');