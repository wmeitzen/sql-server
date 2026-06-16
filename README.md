StatsOptimize.sql and StatsOptimizeSQL.sql

StatsOptimize is an Ola Hallengren-like SQL Server utility for updating statistics. It complements Ola Hallengren's IndexOptimize utility by focusing on database statistics only. Both files are functionally identical. StatsOptimize.sql is a stored procedure, and StatsOptimizeSQL.sql is standalone T-SQL.

It's defaults will show what statistics will be updated in order. Set @Execute = 'Y' to have the commands run.

# StatsOptimize

Requires SQL Server 2016 or later.

StatsOptimize maintains SQL Server statistics using two independent signals:

1. **Sample size** is driven by table row count (TF2371 curve), not by how often an object is queried.
2. **Cadence and priority** are driven by index usage (seeks, scans, lookups per day), so busy objects are refreshed sooner and processed first.

The procedure is parameter-driven, supports preview mode (`@Execute = 'N'`), and can log to a CommandLog-style table. It follows the same general style as Ola Hallengren's maintenance solution.

## Files

| File | Purpose |
|------|---------|
| `StatsOptimize.sql` | Creates `master.dbo.StatsOptimize` |
| `StatsOptimizeSQL.sql` | Same logic as a standalone script; edit the `DECLARE` block at the top and run the batch |

Install the procedure once, then call it from jobs or SSMS. Use the standalone script for ad hoc runs without deploying an object.

## Prerequisites

- SQL Server 2016+
- Target databases must be online, writable, and not database snapshots
- Optional: `master.dbo.CommandLog` (or your Ola CommandLog table) for execution logging
- Optional: `master.dbo.StatsOptimizeData` when using `@StatsOptimizeTableMode = 'StatsOptimizeData'`

Create the state table:

```sql
EXEC master.dbo.StatsOptimize @Command = 'STATSOPTIMIZEDATA_DDL';
-- Run the printed CREATE TABLE script
```

## @Command parameter

| Command | Description |
|---------|-------------|
| `OPTIMIZE` | Evaluate statistics and update or preview them |
| `SHOWUSAGE` | Report uses per day and TF2371 sample sizes (read-only) |
| `STATSOPTIMIZEDATA_DDL` | Print CREATE TABLE for the usage snapshot table |
| (invalid or omitted) | Prints built-in help |

## Quick start

```sql
-- Preview (no changes)
EXEC master.dbo.StatsOptimize
    @Command = 'OPTIMIZE',
    @Databases = 'USER_DATABASES';

-- Usage report
EXEC master.dbo.StatsOptimize
    @Command = 'SHOWUSAGE',
    @Databases = 'SalesDB';

-- Run with TF2371 and a 1-hour cap
EXEC master.dbo.StatsOptimize
    @Command = 'OPTIMIZE',
    @Databases = 'USER_DATABASES',
    @with_sample_percent = 'TF2371',
    @TimeLimit = 3600,
    @Execute = 'Y';
```

For **StatsOptimizeSQL.sql**, set variables in the `DECLARE` block at the top, then execute the whole script.

## When a statistic is updated

A statistic is a candidate when:

- Row count is between `@MinNumberOfStatsRows` and `@MaxNumberOfStatsRows` (if set)
- It is outside the cadence skip window (`effective_skip_hours`)
- Either modification percent exceeds `@ModificationThreshold`, or current sample percent is below desired sample by more than `@SamplingGapTolerance`

Candidates run in priority order (higher score first):

- Staleness in days (cap 365) times 1
- Churn percent modified (cap 100) times 10
- Sampling gap beyond tolerance times 20
- Usage percentile (0-100) times `@UsagePriorityWeight`

## Sample size (TF2371)

When `@with_sample_percent = 'TF2371'`:

`CEILING(20.0 * POWER(rows / 25000.0, -0.265))` clamped between 1 and 100.

- Small tables: often FULLSCAN (95% or higher becomes `WITH FULLSCAN`)
- Large tables: light sample (for example about 2% at ~162M rows)

You can also pass a fixed percent (1-100) or `NULL` for no SAMPLE/FULLSCAN clause.

## @Databases tokens

Comma-separated. Prefix with `-` to exclude.

| Token | Meaning |
|-------|---------|
| `USER_DATABASES` | Non-system databases |
| `ALL_DATABASES` | All online writable databases |
| `SYSTEM_DATABASES` | master, model, msdb, tempdb |
| `SalesDB` | Exact name |
| `Sales%` | LIKE pattern |

Example: `USER_DATABASES,-AdventureWorks`

## @Statistics selector

Intersected with `@Databases`.

- `NULL` or `ALL_STATISTICS` — all statistics
- 3-part: `SalesDB.dbo.Orders` — all stats on that object
- 4-part: `SalesDB.dbo.Orders.PK_Orders` — one statistic
- `%` wildcards in any part
- `-` prefix excludes (exclusion wins)

Example: `SalesDB.dbo.%,-SalesDB.dbo.%._WA%`

## @StatsOptimizeTableMode parameter

| Mode | Behavior |
|------|----------|
| `None` (default) | No persisted state; uses per day falls back to lifetime average |
| `StatsOptimizeData` | MERGE into flat table (recommended) |
| `CommandLog` | Legacy: STATS_USAGE_SNAPSHOT rows in CommandLog |

Usage is trusted only when instance uptime is at least `@MinInstanceUptimeDays` (default 14). Before that, the procedure uses `@UsageModel = 'None'` and `@DefaultSkipHours`.

## Parameters

### Command and scope

**@Command** (default: `OPTIMIZE`)  
Selects the operation: OPTIMIZE, SHOWUSAGE, or STATSOPTIMIZEDATA_DDL. Invalid values print help.

**@Databases** (required)  
Which databases to process. Use USER_DATABASES, ALL_DATABASES, SYSTEM_DATABASES, a comma-separated list, percent wildcards, or minus exclusions.

**@Statistics** (default: NULL)  
Which statistics to include. NULL or ALL_STATISTICS means all; otherwise use 3-part or 4-part names with wildcards and exclusions.

### Usage model (cadence and priority only; not sample size)

**@UsageModel** (default: `Continuous`)  
Continuous weights cadence and priority by usage percentile. None ignores usage and uses size, staleness, and churn only.

**@HotSkipHours** (default: 24)  
Minimum hours between updates for the busiest statistics.

**@ColdSkipHours** (default: 720)  
Maximum hours between updates for idle statistics (30 days).

**@DefaultSkipHours** (default: 168)  
Fixed skip window when usage is untrusted or UsageModel is None (one week).

**@UsagePriorityWeight** (default: 5.0)  
Multiplier for usage percentile in the priority score. Higher values favor busy objects earlier.

**@MinInstanceUptimeDays** (default: 14)  
Minimum instance uptime before usage from `sys.dm_db_index_usage_stats` is trusted.

### Sample size

**@with_sample_percent** (default: `TF2371`)  
TF2371 size curve, a fixed percent 1-100, or NULL for no SAMPLE/FULLSCAN clause.

**@with_persist_sample_percent** (default: `N`)  
When Y, appends PERSIST_SAMPLE_PERCENT = ON. Default N avoids costly surprise rescans on large tables.

### Update triggers

**@ModificationThreshold** (default: 5.0)  
Percent of rows modified since last update that triggers a refresh.

**@SamplingGapTolerance** (default: 2.0)  
Allowed gap in percentage points between actual and desired sample before under-sampling triggers a refresh.

### Row-count filters

**@MinNumberOfStatsRows** (default: 1000)  
Skip statistics on smaller objects.

**@MaxNumberOfStatsRows** (default: NULL)  
Skip statistics on larger objects. NULL means no upper limit.

### Column (auto-created) statistics

**@AutoStatsMode** (default: `ParentUsage`)  
For column stats, ParentUsage inherits parent object usage; Modification treats usage as zero.

### Execution control

**@MaxDOP** (default: NULL)  
Parallelism per UPDATE STATISTICS. NULL uses server default; 1 is serial; 2-64 caps DOP.

**@TimeLimit** (default: NULL)  
Stop after this many seconds.

**@Execute** (default: `N`)  
N previews only; Y executes commands. Preview on a new environment first.

### Logging and state

**@LogToTable** (default: `Y`)  
Log each UPDATE STATISTICS to CommandLog. Disabled if the table is missing.

**@CommandLog** (default: `master.dbo.CommandLog`)  
Three-part name of the log table.

**@StatsOptimizeTableMode** (default: None)  
Where usage snapshots are stored: None, StatsOptimizeData, or CommandLog.

**@StatsOptimizeTable** (default: `master.dbo.StatsOptimizeData`)  
Three-part name of the snapshot table when mode is StatsOptimizeData.

## More examples

```sql
-- Preview with defaults
EXEC master.dbo.StatsOptimize
    @Databases = 'USER_DATABASES'

-- Execute with defaults
EXEC master.dbo.StatsOptimize
    @Databases = 'USER_DATABASES',
    @Execute = 'Y';

-- Update only the SalesDB database
-- Customers table in all schemas, and dbo.Sales table
EXEC master.dbo.StatsOptimize
    @Databases = 'SalesDB',
    @Statistics = '%.%.Customers, %.dbo.Sales',
    @Execute = 'Y';

-- Limit to 3600 seconds = 1 hr
EXEC master.dbo.StatsOptimize
    @Databases = 'USER_DATABASES',
    @TimeLimit = 3600,
    @Execute = 'Y';

-- Set all objects in SaleDB to 10% sample size
EXEC master.dbo.StatsOptimize
    @Databases = 'SalesDB',
    @with_sample_percent = '10',
    @Execute = 'Y';
```

## Operational notes

- Default is preview (`@Execute = 'N'`). Review output before executing.
- `DEADLOCK_PRIORITY LOW`: business transactions win on deadlock.
- After failover or restart, usage DMVs reset; wait for `@MinInstanceUptimeDays` or use `@UsageModel = 'None'` until counters stabilize.
- For SQL Agent: use `StatsOptimizeData` mode for stable usage deltas across runs.

## Attribution

Inspired by [Ola Hallengren's Maintenance Solution](https://ola.hallengren.com/) (parameters and CommandLog pattern). TF2371 sampling, usage-weighted cadence, and priority logic are specific to StatsOptimize.
