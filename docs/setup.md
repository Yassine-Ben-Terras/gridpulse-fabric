# Step 1 — Repo, Lakehouses & Secrets Setup

You already have a Fabric workspace and an ENTSO-E token, so this step wires
them together. Everything below is a one-time setup.

## 1. Create the three Lakehouses

In your Fabric workspace → **New item → Lakehouse**, create three:

| Name | Purpose |
|---|---|
| `lh_bronze` | Raw landing zone — Files only, no Delta tables |
| `lh_silver` | Conformed Delta tables |
| `lh_gold` | Star schema Delta tables |

Naming them explicitly (rather than one lakehouse with folders) keeps
permissions, lineage, and the Fabric monitoring hub honest about which layer
is which — worth mentioning in an interview as a deliberate choice.

## 2. Put the ENTSO-E token in Azure Key Vault

If you don't already have a Key Vault for this project:

1. Azure Portal → **Key Vaults → Create**. Any resource group/region is fine;
   this doesn't need to be co-located with Fabric capacity.
2. Once created: **Secrets → Generate/Import** →
   - Name: `entsoe-api-token`
   - Value: your ENTSO-E security token
3. **Access policies / Access configuration** (depends on Key Vault
   permission model): grant your Fabric capacity's/tenant's managed
   identity — or, simplest for a portfolio project, your own account —
   `Get` and `List` permission on **Secrets**.

## 3. Reference the secret from a Fabric notebook — no hardcoded tokens

Fabric notebooks can read Key Vault secrets directly via `notebookutils`,
with no separate "connection" object needed for this pattern:

```python
entsoe_token = notebookutils.credentials.getSecret(
    "https://<your-keyvault-name>.vault.azure.net/",
    "entsoe-api-token"
)
```

Run that alone in a scratch notebook cell against `lh_bronze` to confirm it
resolves before building anything else — if it fails, it's almost always the
access-policy step above, not the code.

Open-Meteo needs no secret (documented in the design doc as a deliberate
callout — one API needs credential plumbing, the other doesn't, and a
pipeline should handle both cleanly).

## 4. Connect this repo to the workspace via Git integration

1. Push this repo to GitHub (or Azure DevOps).
2. Fabric workspace → **Workspace settings → Git integration** → connect,
   pick the branch (`main`) and this repo.
3. Fabric will show existing workspace items as "uncommitted" — commit them
   so the workspace and repo converge.

From here on, notebooks/pipelines built in the Fabric UI sync back to this
repo, and this repo's `notebooks/`, `pipelines/`, `sql/` folders stay in
lockstep with what's actually deployed.

## 5. Watermark table

The ingestion pipeline (Step 4) needs a place to track "last successfully
loaded timestamp per zone/source" so incremental daily runs don't re-pull
the full history each time. DDL for it lives in `sql/silver_watermark.sql`
— it's created in `lh_silver` once, in the next step, right before the
first Silver notebook is built.

## Done-when

- [ ] `lh_bronze`, `lh_silver`, `lh_gold` exist in the workspace
- [ ] `entsoe-api-token` secret exists in Key Vault and resolves from a
      notebook via `notebookutils.credentials.getSecret(...)`
- [ ] This repo is connected via Git integration and workspace items show
      as committed
