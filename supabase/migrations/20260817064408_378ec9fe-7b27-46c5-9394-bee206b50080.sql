REVOKE ALL ON FUNCTION public.autosense_tick() FROM anon, authenticated, PUBLIC;
GRANT EXECUTE ON FUNCTION public.autosense_tick() TO service_role;