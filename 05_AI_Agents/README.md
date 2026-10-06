# AI Agents

Agents turn the platform's data into prioritized recommendations. Each agent is Claude with a small set of **read-only tools** over the SQL Server database: it investigates, measures impact, and writes a report a stakeholder can act on.

| Agent | Status | Reads |
|---|---|---|
| [Data Quality Agent](data_quality_agent/agent.py) | Built; tools tested, first run pending an API key | `dq`, `audit`, `raw` schemas |
| Supplier Risk Agent | Planned (after the star schema) | `mart` |
| Inventory Risk Agent | Planned | `mart` |
| Transfer Recommendation Agent | Planned | `mart` |
| Demand Forecast Agent | Planned (after forecasting) | `mart`, forecast |
| Executive Briefing Agent | Planned (last) | Other agents' outputs |

## Data Quality Agent

Reads the results of the 119 data quality rules and tells the Data Steward what to fix first, **ranked by business impact rather than issue count**. For example, 10 duplicate supplier records that split $317,854 of purchase order spend outrank thousands of date-format issues that the clean layer fixes automatically.

**Tools** (fixed, parameterized queries; the model never writes SQL):

| Tool | Returns |
|---|---|
| `get_quality_overview` | Data quality score per table, issues by dimension and severity |
| `list_failing_rules` | Rules with failures, filterable by source system and severity |
| `get_rule_detail` | One rule plus sample failing records |
| `get_business_impact` | What a rule's failures touch downstream: PO spend, sales revenue, transactions |
| `get_run_history` | Trend across rule runs |
| `get_data_freshness` | Last load time and status of every dataset |

**Security**

- The database connection switches to `dq_agent_reader` (`EXECUTE AS USER ... WITH NO REVERT`), a user with no login that can only `SELECT` from `dq`, `audit`, and `raw`. Writes, schema changes, the `mart`, and switching back to the original identity are all refused (tested).
- No free-form SQL: tools run fixed queries with bound parameters.
- Values from source data are treated as data, not instructions (stated in the system prompt).
- The API key is read from the environment and never written to disk.

**Model:** `claude-opus-5-5` with high effort, prompt caching, and server-side refusal fallback. A triage report is roughly $0.30.

### Run

```powershell
pip install -r requirements.txt
$env:ANTHROPIC_API_KEY = "..."      # from console.anthropic.com

python 05_AI_Agents/data_quality_agent/agent.py                  # triage report -> 05_AI_Agents/reports/
python 05_AI_Agents/data_quality_agent/agent.py --ask "Which supplier issues affect the most spend?"
python 05_AI_Agents/data_quality_agent/agent.py --dry-run        # test every tool, no API call
```

Run `04_Database/run_dq.py` first so the agent reads current results.
