CREATE OR REPLACE FUNCTION public.load_weather_history(p_location_name character varying, p_latitude numeric, p_longitude numeric, p_full_reload boolean DEFAULT false, p_max_chunks integer DEFAULT 30, p_overlap_days integer DEFAULT 14, p_timezone text DEFAULT 'Europe/London'::text)
 RETURNS TABLE(rows_upserted bigint, chunks_run integer, loaded_from date, loaded_to date, finished boolean)
 LANGUAGE plpgsql
 SET search_path TO 'public', 'extensions'
AS $function$
#variable_conflict use_column
DECLARE
    c_start_date    CONSTANT date := DATE '1940-01-01';   -- static start of the archive
    v_end           date;                                 -- today (in the chosen timezone)
    v_last_loaded   date;
    v_from          date;
    v_to            date;
    v_first_from    date;
    v_last_to       date;
    v_chunks        integer := 0;
    v_rows          bigint  := 0;
    v_chunk_rows    bigint;
    v_url           text;
    v_resp          extensions.http_response;
    v_hourly        jsonb;
BEGIN
    ------------------------------------------------------------
    -- Validation
    ------------------------------------------------------------
    IF p_location_name IS NULL OR btrim(p_location_name) = '' THEN
        RAISE EXCEPTION 'p_location_name is required.';
    END IF;
    IF p_latitude  IS NULL OR p_latitude  NOT BETWEEN  -90 AND  90
    OR p_longitude IS NULL OR p_longitude NOT BETWEEN -180 AND 180 THEN
        RAISE EXCEPTION 'Latitude must be -90..90 and longitude -180..180.';
    END IF;

    -- Give the API up to 60 seconds per call (the default is only 5).
    PERFORM extensions.http_set_curlopt('CURLOPT_TIMEOUT', '60');

    ------------------------------------------------------------
    -- Work out the date range: 1940-01-01 .. today
    ------------------------------------------------------------
    v_end := (now() AT TIME ZONE p_timezone)::date;

    SELECT max(w.weather_datetime)::date
    INTO   v_last_loaded
    FROM   weather_hourly w
    WHERE  w.location_name = p_location_name;

    -- First load (or forced reload): start at the static 1940-01-01.
    -- Refresh: carry on from the last loaded day, minus a small overlap.
    v_from := CASE
                  WHEN p_full_reload OR v_last_loaded IS NULL THEN c_start_date
                  ELSE GREATEST(c_start_date, v_last_loaded - p_overlap_days)
              END;
    v_first_from := v_from;

    ------------------------------------------------------------
    -- One API call per year, upserting each as we go
    ------------------------------------------------------------
    WHILE v_from <= v_end AND v_chunks < p_max_chunks LOOP

        v_to := LEAST(((v_from + interval '1 year')::date) - 1, v_end);

        v_url := format(
            'https://archive-api.open-meteo.com/v1/archive'
            || '?latitude=%s&longitude=%s&start_date=%s&end_date=%s'
            || '&hourly=temperature_2m,relative_humidity_2m,precipitation,rain,pressure_msl,'
            ||   'cloud_cover,wind_speed_10m,wind_direction_10m,wind_gusts_10m'
            || '&timezone=%s&wind_speed_unit=mph&precipitation_unit=mm&format=json',
            p_latitude, p_longitude, v_from, v_to,
            replace(p_timezone, '/', '%2F')
        );

        v_resp := extensions.http_get(v_url);

        IF v_resp.status <> 200 THEN
            RAISE EXCEPTION 'Open-Meteo returned HTTP % for % to %: %',
                v_resp.status, v_from, v_to, left(v_resp.content, 300);
        END IF;

        v_hourly := (v_resp.content::jsonb) -> 'hourly';

        IF v_hourly IS NULL OR jsonb_typeof(v_hourly -> 'time') <> 'array' THEN
            RAISE EXCEPTION 'Unexpected response from Open-Meteo for % to %: %',
                v_from, v_to, left(v_resp.content, 300);
        END IF;

        -- The API returns parallel arrays (one list per variable), so we walk them
        -- by position to rebuild one row per hour.
        INSERT INTO weather_hourly AS w
        (
            location_name, latitude, longitude, weather_datetime,
            temperature_2m_c, relative_humidity_2m, precipitation_mm, rain_mm,
            pressure_msl_hpa, cloud_cover_pct, wind_speed_10m_mph,
            wind_direction_10m_deg, wind_gusts_10m_mph
        )
        SELECT DISTINCT ON (r.t)      -- DISTINCT ON guards against a repeated hour when clocks change
            p_location_name, p_latitude, p_longitude, r.t,
            r.temperature, r.humidity::smallint, r.precip, r.rain,
            r.pressure, r.cloud::smallint, r.wind_speed,
            r.wind_dir::smallint, r.wind_gust
        FROM
        (
            SELECT
                (v_hourly -> 'time'                 ->> i)::timestamp(0)  AS t,
                (v_hourly -> 'temperature_2m'       ->> i)::numeric       AS temperature,
                (v_hourly -> 'relative_humidity_2m' ->> i)::numeric       AS humidity,
                (v_hourly -> 'precipitation'        ->> i)::numeric       AS precip,
                (v_hourly -> 'rain'                 ->> i)::numeric       AS rain,
                (v_hourly -> 'pressure_msl'         ->> i)::numeric       AS pressure,
                (v_hourly -> 'cloud_cover'          ->> i)::numeric       AS cloud,
                (v_hourly -> 'wind_speed_10m'       ->> i)::numeric       AS wind_speed,
                (v_hourly -> 'wind_direction_10m'   ->> i)::numeric       AS wind_dir,
                (v_hourly -> 'wind_gusts_10m'       ->> i)::numeric       AS wind_gust
            FROM generate_series(0, jsonb_array_length(v_hourly -> 'time') - 1) AS i
        ) r
        -- The archive lags real time by a few days; skip hours it hasn't filled in yet.
        -- They get picked up on a later run thanks to the overlap.
        WHERE r.temperature IS NOT NULL OR r.precip IS NOT NULL
        ORDER BY r.t
        ON CONFLICT ON CONSTRAINT weather_hourly_pkey DO UPDATE
        SET latitude               = EXCLUDED.latitude,
            longitude              = EXCLUDED.longitude,
            temperature_2m_c       = EXCLUDED.temperature_2m_c,
            relative_humidity_2m   = EXCLUDED.relative_humidity_2m,
            precipitation_mm       = EXCLUDED.precipitation_mm,
            rain_mm                = EXCLUDED.rain_mm,
            pressure_msl_hpa       = EXCLUDED.pressure_msl_hpa,
            cloud_cover_pct        = EXCLUDED.cloud_cover_pct,
            wind_speed_10m_mph     = EXCLUDED.wind_speed_10m_mph,
            wind_direction_10m_deg = EXCLUDED.wind_direction_10m_deg,
            wind_gusts_10m_mph     = EXCLUDED.wind_gusts_10m_mph;

        GET DIAGNOSTICS v_chunk_rows = ROW_COUNT;

        v_rows    := v_rows + v_chunk_rows;
        v_chunks  := v_chunks + 1;
        v_last_to := v_to;
        v_from    := v_to + 1;

        PERFORM pg_sleep(0.3);   -- be polite to the free API
    END LOOP;

    RETURN QUERY
    SELECT v_rows, v_chunks, v_first_from, v_last_to, (v_from > v_end);
END;
$function$
