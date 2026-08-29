# Weather-Driven Electricity Demand & Renewables Forecasting Platform

**A Microsoft Fabric data engineering portfolio project combining the ENTSO-E Transparency Platform API and the Open-Meteo API**

---

## 1. Problem statement

Electricity demand and renewable generation are both driven heavily by weather: cold snaps and heatwaves push heating/cooling demand up, wind speed drives wind generation, and solar irradiance drives solar generation. Grid operators (TSOs) and energy trading desks forecast next-day demand and renewable output using exactly this kind of weather-linked data every day.

This project builds an end-to-end data platform on Microsoft Fabric that:

- Ingests real electricity market data (load, generation by fuel type, day-ahead prices) from the **ENTSO-E Transparency Platform API**.
- Ingests real weather data (temperature, wind speed, solar radiation) from the **Open-Meteo API**.
- Cleans, aligns, and joins both sources by bidding zone and hour.
- Produces analytical dashboards and a day-ahead demand forecasting model.

The goal is a project that is defensible in an interview: every design decision maps to a real constraint (API rate limits, timezone handling, schema evolution, incremental loading, cost/performance tradeoffs), not just a working demo.

---

## 2. Scope (MVP)

To keep the project buildable and demoable, the initial scope is deliberately narrow:

- **Bidding zones:** 2–3 zones to start (e.g. France `FR`, Germany `DE`, Spain `ES`), each parameterized so more zones can be added later without code changes.
- **ENTSO-E data:** actual total load, generation by production type (wind, solar, gas, nuclear, etc.), and day-ahead prices.
- **Open-Meteo data:** hourly temperature, wind speed at 10m/100m, and shortwave solar radiation, for a representative coordinate per bidding zone.
- **Time range:** rolling historical window (e.g. last 12 months) plus daily incremental updates going forward.

Extensibility (more zones, intraday prices, cross-border flows, additional weather variables) is discussed in Section 9.

---

## 3. High-level architecture

```
ENTSO-E API  ─┐
              ├─► Bronze (raw) ─► Silver (cleaned/conformed) ─► Gold (features) ─┬─► Power BI dashboards
Open-Meteo API┘                                                                  └─► Forecasting notebook (MLflow)
```

All storage lives in **OneLake** (Fabric's unified lake), so Bronze/Silver/Gold are Lakehouses within a single Fabric workspace, and there is no data duplication or copying between services — everything is accessed via Delta tables/Files in place.

### Layer responsibilities

| Layer | Contents | Format | Purpose |
|---|---|---|---|
| **Bronze** | Raw API responses, as received | JSON (Open-Meteo) / XML (ENTSO-E), landed as files | Immutable source of truth, fully replayable |
| **Silver** | Parsed, timezone-normalized, deduplicated, schema-enforced | Delta tables | Trusted, query-ready, but not yet business-shaped |
| **Gold** | Joined fact table: load + generation + price + weather, by zone/hour, with engineered features | Delta tables | Feeds BI and ML directly |

### Batch vs. real-time

This platform is **scheduled batch / micro-batch**, not streaming — and that's a deliberate, defensible choice rather than a limitation:

- **ENTSO-E** does not push data. Actual load and generation are published on the platform with a delay (typically 15 minutes to a few hours behind real time), and day-ahead prices are published once per day. There is no event stream to subscribe to — only a REST API to poll.
- **Open-Meteo** forecasts refresh a few times a day on a fixed model run schedule; historical data is inherently batch.

Because neither source refreshes continuously, a streaming architecture would add complexity (Eventstream, KQL database, always-on compute) without reducing meaningful latency. The pipeline instead runs:

- **Daily**, once ENTSO-E's prior-day data is finalized, for day-ahead prices.
- **Hourly / every few hours** for actual load, generation, and weather, since these update intraday but not continuously.

**Where near-real-time would legitimately fit (extension, not MVP):** a Fabric Eventstream polling both APIs every 5–15 minutes into a KQL database, if a future use case needed lower latency. This is called out as a considered-and-deferred option, not an oversight.

---

## 4. Ingestion layer

### 4.1 Orchestration

Fabric **Data Pipelines** orchestrate ingestion on a schedule (e.g. daily at 06:00 UTC, once ENTSO-E's prior-day data is finalized). Each pipeline run is parameterized by:

- `bidding_zone` (EIC code for ENTSO-E, lat/long for Open-Meteo)
- `start_date` / `end_date`, driven by a **watermark table** in Silver that tracks the last successfully loaded timestamp per zone/source

A `ForEach` activity iterates over the configured list of zones, calling a notebook activity per zone. This makes adding a new zone a configuration change, not a code change.

### 4.2 ENTSO-E API specifics

- **Endpoint:** REST API returning XML `MarketDocument` payloads, authenticated with a security token (requested free from the ENTSO-E platform).
- **Document types pulled:**
  - `A65` — total load (actual)
  - `A75` — actual generation per production type
  - `A44` — day-ahead prices
- **Rate limit:** hard limit of 60 requests/minute; exceeding it triggers a temporary IP ban. The pipeline throttles to a conservative ~25–30 requests/minute with explicit delay between calls, and retries with exponential backoff on `429`/`5xx` responses.
- **Chunking:** ENTSO-E limits the date range per request (historically ~1 year for some document types), so requests are chunked into monthly windows and looped.
- **Idempotency:** each request is deterministic given `(zone, document_type, start, end)`, so re-running a failed pipeline step simply re-fetches the same window — no duplicate-avoidance logic needed at this stage (that happens in Silver).

### 4.3 Open-Meteo API specifics

- **Endpoint:** REST API returning JSON, **no authentication required** for the free tier, historical and forecast endpoints both available.
- **Variables pulled:** `temperature_2m`, `windspeed_10m`, `windspeed_100m`, `shortwave_radiation`, hourly resolution.
- **Coordinates:** one representative lat/long per bidding zone (e.g. a population-weighted or capital-city point); documented as a simplification — a production system would use multiple weighted points per zone.
- **Rate limit:** generous for the free tier, but the pipeline still batches requests per zone per month to stay well within limits and to align chunk sizes with the ENTSO-E ingestion pattern.

### 4.4 Secrets management

API tokens (ENTSO-E) are stored in **Azure Key Vault** and referenced via Fabric's connection/credential system — never hardcoded in notebooks or pipeline JSON. Open-Meteo requires no secret for the free tier, which is called out explicitly as a difference worth knowing in an interview.

---

## 5. Bronze layer

- Raw ENTSO-E XML and raw Open-Meteo JSON are landed unmodified into OneLake **Files**, partitioned by `source/zone/year/month/`.
- No parsing, no filtering, no type casting — Bronze exists purely so that any transformation bug downstream can be fixed by re-running Silver against Bronze, without re-calling the APIs.
- Each landed file is named with a deterministic key (`zone_doctype_startdate_enddate.xml`) so re-ingestion is naturally idempotent (overwrite-on-rerun, not append).

---

## 6. Silver layer

A PySpark notebook (or Dataflow Gen2, see tradeoff discussion in Section 8) reads Bronze and produces conformed Delta tables:

- **`silver.entsoe_load`**, **`silver.entsoe_generation`**, **`silver.entsoe_prices`**, **`silver.weather_hourly`**

Key transformations:

- **XML/JSON parsing** into flat rows: one row per `(zone, timestamp, metric)`.
- **Timezone normalization**: ENTSO-E timestamps are in UTC with a `resolution` field (typically 15 or 60 minutes) that must be expanded into individual timestamps; Open-Meteo timestamps are returned in the zone's local time by default and are converted to UTC to match. This mismatch is a real gotcha worth calling out directly in an interview — it's the kind of bug that silently shifts an entire day's correlation if missed.
- **Resolution alignment**: ENTSO-E generation/load data may be 15-minute resolution while Open-Meteo is hourly; Silver resamples ENTSO-E data to hourly (mean for load/price, sum where appropriate for energy) so both sources share a common grain.
- **Deduplication**: merge/upsert (`MERGE INTO`) on the natural key `(zone, timestamp, metric)` so re-running a pipeline for an already-loaded window doesn't create duplicate rows.
- **Schema enforcement**: explicit Delta schema per table; malformed or out-of-range records (e.g. negative load, missing timestamps) are quarantined into a `silver.rejects` table rather than silently dropped or silently passed through.
- **Watermark update**: on successful write, the watermark table used by the ingestion pipeline is advanced.

---

## 7. Gold layer — data modeling

Gold uses a **Kimball-style dimensional model (star schema)**, not a single flat table and not a normalized/3NF or Data Vault model. Reasoning below.

### Why dimensional modeling

- **Not a normalized/3NF model**: Gold is an analytics and ML consumption layer, not a system of record — nobody writes single-row transactions against it. Power BI and the forecasting notebook both need fast, wide, denormalized reads, which is exactly what a star schema is built for, and it maps directly onto how Power BI's semantic model wants data shaped.
- **Not Data Vault**: Data Vault (hubs/links/satellites) earns its complexity with many source systems giving conflicting definitions of the same entity and a need for full historical auditability at the model layer. Here there are two sources, no conflicting definitions, and Bronze already gives full replayability — Data Vault would be over-engineering for this scope.
- **Not one undifferentiated flat table**: slowly-changing attributes (zone name, country, EIC code) are pulled into a dimension rather than repeated on every hourly row — denormalize the *measures* for query speed, but don't redundantly repeat *attributes* across millions of rows.

### Tables

**`dim_zone`** — bidding zone code, country, EIC code, representative coordinates
**`dim_date`** — calendar attributes: day of week, holiday flag, season
**`dim_fuel_type`** — fuel/production type reference (wind, solar, gas, nuclear, etc.)

**`fact_demand_weather_hourly`** — grain: one row per `(bidding_zone, hour_timestamp_utc)`. Measures: load, day-ahead price, temperature, wind speed, solar radiation, plus engineered features:

- **Heating/cooling degree-days** derived from temperature — a standard proxy for weather-driven heating/cooling demand.
- **Wind power proxy** (wind speed cubed, capturing the cubic relationship between wind speed and turbine power output).
- **Lag and rolling-average features** (previous-day same-hour load, 7-day rolling average temperature) for the forecasting model.
- **Calendar features** (hour of day, day of week, holiday flag) since demand has strong daily/weekly seasonality independent of weather.

**`fact_generation_hourly`** — grain: one row per `(bidding_zone, hour_timestamp_utc, fuel_type)`. This is a **separate fact at a different grain** from the demand/weather fact — generation-by-fuel is inherently a longer/narrower grain, so it's a genuine grain mismatch, not something to jam into one wide table. Modeled long (`fuel_type`, `value_mw`) rather than wide (one column per fuel) so a new ENTSO-E production type doesn't require a schema change.

Both facts share `dim_zone` and `dim_date`, so they can still be joined for cross-fact analysis (e.g. price vs. wind output) without duplicating dimension attributes.

No separate feature store is used at this scale — noted as a deliberate scoping decision, with "introduce a feature store" listed as the natural next step if multiple models/consumers start requiring overlapping but differently-versioned features (see Section 9).

---

## 8. Consumption layer

### 8.1 Power BI

Dashboards built directly on `fact_demand_weather_hourly` and `fact_generation_hourly` (joined via `dim_zone`/`dim_date`) via Direct Lake mode (no import/refresh lag, queries OneLake Delta tables directly):

- Load vs. temperature scatter/correlation, by zone
- Renewable generation (wind + solar) vs. forecast weather
- Day-ahead price overlaid against demand and weather extremes (e.g. price spikes during cold snaps)
- **Price driver panel**: day-ahead price segmented by (high demand / low demand) × (high renewable output / low renewable output), to visualize the merit-order effect — see Section 11.

### 8.2 Forecasting notebook

A PySpark/scikit-learn/LightGBM notebook that trains **two forecasting tasks**, since demand and renewable output are the two sides of the balance a trading/grid-balancing analyst actually cares about:

- **Demand forecast**: day-ahead `load` per zone, using temperature/degree-day, calendar, and lag features from `fact_demand_weather_hourly`.
- **Renewable output forecast**: day-ahead wind/solar `value_mw` per zone, using wind speed (cubed) and solar radiation features from `fact_generation_hourly` joined to weather.

Both are tracked with **MLflow** (parameters, metrics like MAPE/RMSE, model artifacts), built into Fabric notebooks. Registered models write batch predictions back into `fact_forecast_hourly`, which Power BI also visualizes (forecast vs. actual).

### 8.3 Optional: Data Activator

An alert rule watching for the coincidence of an extreme weather forecast (e.g. temperature below a threshold) with unusually high predicted demand — demonstrating the "act on data" piece of the platform, not just "report on data."