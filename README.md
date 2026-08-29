# Weather-Driven Electricity Demand & Renewables Forecasting Platform

Microsoft Fabric data engineering project joining the ENTSO-E Transparency
Platform API (load, generation, day-ahead prices) with the Open-Meteo API
(temperature, wind, solar radiation) into a Bronze → Silver → Gold lakehouse,
feeding Power BI dashboards and a day-ahead forecasting notebook.

Full design write-up: see `docs/design.md` (the original project spec).

## Repo layout

```
weather-energy-fabric/
├── config/
│   └── zones.json          # bidding zones, EIC codes, coordinates — edit this to add a zone
├── docs/
│   └── setup.md             # step-by-step Fabric workspace / Key Vault setup
├── notebooks/
│   ├── bronze/               # raw landing notebooks (ENTSO-E XML, Open-Meteo JSON -> OneLake Files)
│   ├── silver/                # parsing, tz-normalization, dedup, schema enforcement -> Delta
│   └── gold/                  # star schema build + feature engineering -> Delta
├── pipelines/                 # Fabric Data Pipeline definitions (exported JSON, once built in-portal)
├── sql/                        # DDL for watermark table, dim/fact tables
├── tests/                       # local unit tests for parsing/transform logic
├── requirements.txt              # local dev deps (linting/testing parsing code outside Fabric)
└── .gitignore
```

This repo is meant to be connected to the Fabric workspace via **Git
integration** (Workspace settings → Git integration → connect to this repo).
That way notebooks and pipeline JSON are edited in the Fabric UI but version
history lives here, and `main` is the source of truth for what's deployed.

## How each repo folder maps to a Fabric item

| Repo folder | Fabric item | Notes |
|---|---|---|
| `notebooks/bronze` | Notebook(s) attached to `lh_bronze` lakehouse | One per source (ENTSO-E, Open-Meteo) |
| `notebooks/silver` | Notebook(s) attached to `lh_silver` lakehouse | One per target Delta table |
| `notebooks/gold` | Notebook(s) attached to `lh_gold` lakehouse | Builds dims + facts |
| `pipelines/` | Fabric Data Pipeline | Orchestrates the `ForEach` over `config/zones.json` |
| `sql/` | Run once against `lh_silver` / `lh_gold` via notebook `%%sql` or a Fabric SQL endpoint | DDL only, no data |

## Build checklist

- [x] **Step 1 — Repo & secrets setup** (this step)
- [ ] Step 2 — ENTSO-E ingestion notebook (Bronze)
- [ ] Step 3 — Open-Meteo ingestion notebook (Bronze)
- [ ] Step 4 — Data Pipeline orchestration (ForEach + watermark + schedule)
- [ ] Step 5 — Silver transformations (parse, tz-normalize, dedupe, schema)
- [ ] Step 6 — Gold star schema (dims + facts + engineered features)
- [ ] Step 7 — Power BI semantic model / Direct Lake dashboards
- [ ] Step 8 — Forecasting notebook (MLflow)
- [ ] Step 9 — Optional: Data Activator alert

