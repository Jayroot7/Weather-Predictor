
    SELECT DISTINCT
        w.location_name::text AS location_name
    FROM public.weather_hourly AS w
    WHERE w.location_name IS NOT NULL
      AND btrim(w.location_name::text) <> ''
    ORDER BY location_name;
