create table public.weather_hourly (
  weather_datetime timestamp without time zone not null,
  temperature_2m_c numeric(5, 2) null,
  relative_humidity_2m smallint null,
  precipitation_mm numeric(8, 2) null,
  rain_mm numeric(8, 2) null,
  pressure_msl_hpa numeric(7, 2) null,
  cloud_cover_pct smallint null,
  wind_speed_10m_mph numeric(7, 2) null,
  wind_direction_10m_deg smallint null,
  wind_gusts_10m_mph numeric(7, 2) null,
  location_name character varying(200) not null,
  latitude numeric(8, 5) null,
  longitude numeric(8, 5) null,
  constraint weather_hourly_pkey primary key (location_name, weather_datetime)
) TABLESPACE pg_default;

create index IF not exists idx_weather_hourly_datetime on public.weather_hourly using btree (weather_datetime) TABLESPACE pg_default;
