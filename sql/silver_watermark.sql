-- Run once in lh_silver (e.g. via a notebook %%sql cell, or Fabric SQL endpoint).
-- Tracks the last successfully loaded timestamp per (zone, source), so the
-- ingestion pipeline's daily run only pulls new data, not the full history.

CREATE TABLE IF NOT EXISTS silver.watermark (
    zone_code       STRING      NOT NULL,   -- e.g. 'FR', matches config/zones.json
    source          STRING      NOT NULL,   -- 'entsoe_load' | 'entsoe_generation' | 'entsoe_prices' | 'weather'
    last_loaded_ts  TIMESTAMP   NOT NULL,   -- UTC, inclusive: data up to and including this hour is loaded
    updated_at      TIMESTAMP   NOT NULL    -- when this watermark row was last written, for auditability
)
USING DELTA;

-- Seed rows: one per zone x source, so the first pipeline run has an
-- explicit start date to work from instead of special-casing "no watermark
-- yet" logic in the pipeline. Adjust the seed date to match history_window_days
-- in config/zones.json (default: 365 days back from today).
-- Example seed (repeat per zone/source combination):
--
-- INSERT INTO silver.watermark VALUES
--   ('FR', 'entsoe_load', TIMESTAMP '2025-08-29 00:00:00', current_timestamp());
