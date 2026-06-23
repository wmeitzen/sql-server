-- =================================================================
-- StatsOptimize - standalone script (no stored procedure)
-- =================================================================
-- Same logic as master.dbo.StatsOptimize, packaged as a single batch
-- you can run ad hoc. Edit the variables in the DECLARE block below,
-- then execute the whole script.
--
-- Requires SQL Server 2016 or later. State (last usage snapshot) is
-- kept in the CommandLog table (configurable), same as the stored procedure.
--
-- VERSION: 2.0
-- =================================================================

-- Command dispatch
DECLARE @Command VARCHAR(32) = 'OPTIMIZE';            -- OPTIMIZE, SHOWUSAGE, STATSOPTIMIZEDATA_DDL (null/invalid prints help)
-- Target selection
DECLARE @Databases NVARCHAR(MAX) = 'USER_DATABASES';              -- Ola tokens: USER_DATABASES, ALL_DATABASES, CSV list, -Exclusion
DECLARE @Statistics NVARCHAR(MAX) = NULL --'ALL_STATISTICS,-%.%.%.%WA%';             -- Ola-style: ALL_STATISTICS, 3-part DB.Schema.Object, 4-part DB.Schema.Object.Stat; % wildcards, -Exclusion; NULL = all
-- Usage model (drives cadence and priority order, never sample size)
DECLARE @UsageModel VARCHAR(20) = 'Continuous';       -- Continuous (usage-weighted) or None (size/staleness/churn only)
-- Sample size (driven by table SIZE, not popularity)
DECLARE @with_sample_percent NVARCHAR(10) = 'TF2371'; -- 'TF2371' = size-adaptive curve (TF2371-style, not the trace flag's algorithm), a numeric percent (forced), or NULL (engine default)
DECLARE @with_persist_sample_percent CHAR(1) = 'N';   -- Y appends PERSIST_SAMPLE_PERCENT = ON (off by default on purpose)
DECLARE @RespectPersistedSample CHAR(1) = 'Y';        -- Y = honor a stat's persisted sample rate as desired (SQL 2019+); N = always use TF2371/@with_sample_percent
-- Update trigger thresholds
DECLARE @ModificationThreshold DECIMAL(5, 2) = 5.0;   -- % rows modified since last update that triggers a refresh
DECLARE @SamplingGapTolerance DECIMAL(5, 2) = 2.0;    -- "close enough" tolerance (pct points) between actual and desired sample
-- Cadence: skip window interpolated by usage (hot = busiest, cold = idle)
DECLARE @HotSkipHours INT = 24;                       -- busiest stats: eligible again after this many hours
DECLARE @ColdSkipHours INT = 720;                     -- idle stats: eligible again after this many hours (720 = 30 days)
DECLARE @DefaultSkipHours INT = 168;                  -- used when usage is untrusted or @UsageModel = 'None' (168 = 1 week)
-- Priority weighting
DECLARE @UsagePriorityWeight DECIMAL(9, 2) = 5.0;     -- weight applied to the 0-100 usage percentile in the priority score
-- Stats row-count bounds
DECLARE @MinNumberOfStatsRows BIGINT = 1000;          -- skip statistics with fewer rows than this
DECLARE @MaxNumberOfStatsRows BIGINT = NULL;          -- skip statistics with more rows than this (null = no upper bound)
-- Usage trust gate
DECLARE @MinInstanceUptimeDays INT = 14;
-- Column (auto-created) statistics handling
DECLARE @AutoStatsMode VARCHAR(20) = 'ParentUsage';   -- ParentUsage, Modification
-- Throttle and behavior
DECLARE @MaxDOP INT = NULL;                            -- NULL = server default; 1 = serial; 2+ = limit parallelism per stat update
DECLARE @TimeLimit INT = NULL;                         -- seconds; stop starting new updates past this
DECLARE @Execute CHAR(1) = 'N';                        -- N previews, Y runs
DECLARE @LogToTable CHAR(1) = 'Y';                     -- log to CommandLog table
DECLARE @CommandLog NVARCHAR(512) = 'master.dbo.CommandLog'; -- 3-part name of the CommandLog table
DECLARE @StatsOptimizeTableMode VARCHAR(20) = NULL; -- NULL/None = no state; StatsOptimizeData = dedicated table; CommandLog = legacy snapshot rows
DECLARE @StatsOptimizeTable NVARCHAR(512) = 'master.dbo.StatsOptimizeData'; -- 3-part name of the state table (used when mode = StatsOptimizeData)

SET NOCOUNT ON;
SET XACT_ABORT, ANSI_PADDING, ARITHABORT, CONCAT_NULL_YIELDS_NULL ON;
SET NUMERIC_ROUNDABORT OFF;
SET ANSI_WARNINGS ON;

-- When in doubt, in the unlikely scenario of this script deadlocking with
-- a business transaction, this script should be the victim
SET DEADLOCK_PRIORITY LOW;

-- Normalize dispatch / mode parameters (case- and whitespace-insensitive)
SET @Command = UPPER(LTRIM(RTRIM(@Command)));
SET @UsageModel = UPPER(LTRIM(RTRIM(@UsageModel)));
SET @AutoStatsMode = UPPER(LTRIM(RTRIM(@AutoStatsMode)));
SET @Execute = UPPER(LTRIM(RTRIM(@Execute)));
SET @LogToTable = UPPER(LTRIM(RTRIM(@LogToTable)));
SET @with_persist_sample_percent = UPPER(LTRIM(RTRIM(@with_persist_sample_percent)));
SET @RespectPersistedSample = UPPER(LTRIM(RTRIM(@RespectPersistedSample)));
IF (@with_sample_percent IS NOT NULL) SET @with_sample_percent = LTRIM(RTRIM(@with_sample_percent));
IF (@Statistics IS NOT NULL) SET @Statistics = LTRIM(RTRIM(@Statistics));

-- Validate and quote the CommandLog 3-part name
SET @CommandLog = LTRIM(RTRIM(@CommandLog));
DECLARE @CmdLogDb     SYSNAME = PARSENAME(@CommandLog, 3);
DECLARE @CmdLogSchema SYSNAME = PARSENAME(@CommandLog, 2);
DECLARE @CmdLogTable  SYSNAME = PARSENAME(@CommandLog, 1);
IF (@CmdLogDb IS NULL OR @CmdLogSchema IS NULL OR @CmdLogTable IS NULL)
BEGIN
	RAISERROR('@CommandLog must be a valid 3-part name (database.schema.table).', 16, 1);
	RETURN;
END
DECLARE @CommandLogQuoted NVARCHAR(512) = QUOTENAME(@CmdLogDb) + '.' + QUOTENAME(@CmdLogSchema) + '.' + QUOTENAME(@CmdLogTable);

-- Normalize @StatsOptimizeTableMode: NULL -> 'NONE'
SET @StatsOptimizeTableMode = UPPER(LTRIM(RTRIM(ISNULL(@StatsOptimizeTableMode, 'NONE'))));
IF (@StatsOptimizeTableMode NOT IN ('NONE', 'STATSOPTIMIZEDATA', 'COMMANDLOG'))
BEGIN
	PRINT 'Error: @StatsOptimizeTableMode must be NULL, None, StatsOptimizeData, or CommandLog.';
	RETURN;
END

-- Validate and quote the StatsOptimizeTable 3-part name
SET @StatsOptimizeTable = LTRIM(RTRIM(@StatsOptimizeTable));
DECLARE @SOTDb     SYSNAME = PARSENAME(@StatsOptimizeTable, 3);
DECLARE @SOTSchema SYSNAME = PARSENAME(@StatsOptimizeTable, 2);
DECLARE @SOTTable  SYSNAME = PARSENAME(@StatsOptimizeTable, 1);
IF (@SOTDb IS NULL OR @SOTSchema IS NULL OR @SOTTable IS NULL)
BEGIN
	RAISERROR('@StatsOptimizeTable must be a valid 3-part name (database.schema.table).', 16, 1);
	RETURN;
END
DECLARE @StatsOptimizeTableQuoted NVARCHAR(512) = QUOTENAME(@SOTDb) + '.' + QUOTENAME(@SOTSchema) + '.' + QUOTENAME(@SOTTable);

-- =============================================================
-- STATSOPTIMIZEDATA_DDL: print DDL for the state table and return
-- =============================================================
IF (@Command = 'STATSOPTIMIZEDATA_DDL')
BEGIN
	PRINT '-- Creates the state table used by @StatsOptimizeTableMode = ''StatsOptimizeData''';
	PRINT '-- Adjust @StatsOptimizeTable if you want a different database/name.';
	PRINT '';
	PRINT 'USE ' + QUOTENAME(@SOTDb) + ';';
	PRINT 'GO';
	PRINT '';
	PRINT 'IF OBJECT_ID(''' + QUOTENAME(@SOTSchema) + '.' + QUOTENAME(@SOTTable) + ''', ''U'') IS NULL';
	PRINT 'BEGIN';
	PRINT '    CREATE TABLE ' + QUOTENAME(@SOTSchema) + '.' + QUOTENAME(@SOTTable) + ' (';
	PRINT '        DatabaseName  SYSNAME     NOT NULL,';
	PRINT '        SchemaName    SYSNAME     NOT NULL,';
	PRINT '        ObjectName    SYSNAME     NOT NULL,';
	PRINT '        StatsName     SYSNAME     NOT NULL,';
	PRINT '        TotalUses     BIGINT      NOT NULL,';
	PRINT '        UserSeeks     BIGINT      NOT NULL,';
	PRINT '        UserScans     BIGINT      NOT NULL,';
	PRINT '        UserLookups   BIGINT      NOT NULL,';
	PRINT '        SnapshotTime  DATETIME    NOT NULL,';
	PRINT '        CONSTRAINT PK_' + @SOTTable + ' PRIMARY KEY CLUSTERED';
	PRINT '            (DatabaseName, SchemaName, ObjectName, StatsName)';
	PRINT '    );';
	PRINT 'END';
	PRINT 'GO';
	RETURN;
END

-- =============================================================
-- HELP / USAGE
-- =============================================================
IF (@Command IS NULL OR @Command NOT IN ('OPTIMIZE', 'SHOWUSAGE'))
BEGIN
	PRINT '=================================================================';
	PRINT 'StatsOptimize - Size-and-Usage-Driven Statistics Maintenance';
	PRINT '=================================================================';
	PRINT '';
	PRINT 'PURPOSE:';
	PRINT '  Update SQL Server statistics intelligently. Two independent';
	PRINT '  signals drive the work:';
	PRINT '    1. SAMPLE SIZE comes from table SIZE (row count) via the TF2371';
	PRINT '       power curve, so a billion-row table is sampled lightly while';
	PRINT '       a small table is scanned in full.';
	PRINT '    2. CADENCE and PRIORITY come from index USAGE (seeks/scans/';
	PRINT '       lookups per day), so busy objects refresh sooner and first.';
	PRINT '';
	PRINT '  Built in the spirit of Ola Hallengren''s Maintenance Solution:';
	PRINT '  parameter-driven, logs to CommandLog (configurable), and supports a';
	PRINT '  preview mode (@Execute = ''N'') that prints commands without running.';
	PRINT '';
	PRINT 'COMMANDS:';
	PRINT '  OPTIMIZE             - Evaluate statistics and update (or preview) them.';
	PRINT '  SHOWUSAGE            - Report the uses/day distribution (read-only).';
	PRINT '  STATSOPTIMIZEDATA_DDL - Print the CREATE TABLE script for the state table.';
	PRINT '';
	PRINT '=================================================================';
	PRINT 'SAMPLE SIZE (TF2371 curve)';
	PRINT '=================================================================';
	PRINT '  @with_sample_percent controls the SAMPLE clause:';
	PRINT '    ''TF2371'' - size-adaptive sample curve. Named for the trace';
	PRINT '               flag''s philosophy (big tables treated differently),';
	PRINT '               not its formula. CEILING(20.0*POWER(rows/25000,-0.265)).';
	PRINT '    <number> - force that integer SAMPLE percent for every stat.';
	PRINT '               The percentage falls as the table grows; a result';
	PRINT '               of 95 or more becomes WITH FULLSCAN.';
	PRINT '    NULL     - emit no SAMPLE/FULLSCAN clause (engine default).';
	PRINT '  @with_persist_sample_percent  Y appends PERSIST_SAMPLE_PERCENT=ON';
	PRINT '               (OFF by default on purpose: a huge table plus auto';
	PRINT '               stats update can trigger a costly mid-day refresh).';
	PRINT '  @RespectPersistedSample  Y (default) means when a stat already has';
	PRINT '               PERSIST_SAMPLE_PERCENT=ON (SQL 2019+), use its persisted';
	PRINT '               rate as the desired floor instead of TF2371. N ignores it.';
	PRINT '';
	PRINT '=================================================================';
	PRINT 'USAGE MODEL (cadence + priority)';
	PRINT '=================================================================';
	PRINT '  @UsageModel:';
	PRINT '    Continuous - weigh each stat by its usage percentile (0-100)';
	PRINT '                 computed across the run from the seeks/scans/';
	PRINT '                 lookups delta since the previous snapshot.';
	PRINT '    None       - ignore usage; rank by size/staleness/churn only.';
	PRINT '';
	PRINT '  Cadence: the skip window is interpolated from @ColdSkipHours down';
	PRINT '  to @HotSkipHours by usage percentile (busier = shorter wait).';
	PRINT '  When usage is untrusted or @UsageModel = ''None'', @DefaultSkipHours';
	PRINT '  is used instead.';
	PRINT '';
	PRINT '  Priority score (higher = processed earlier):';
	PRINT '    staleness(days, cap 365) * 1';
	PRINT '    + churn(% modified, cap 100) * 10';
	PRINT '    + sampling gap(desired - actual, beyond tolerance) * 20';
	PRINT '    + usage percentile(0-100) * @UsagePriorityWeight';
	PRINT '';
	PRINT '=================================================================';
	PRINT 'KEY PARAMETERS';
	PRINT '=================================================================';
	PRINT '  @Databases              USER_DATABASES, ALL_DATABASES, CSV, -Exclude';
	PRINT '  @Statistics             Ola-style stat selector (see below)';
	PRINT '  @UsageModel             Continuous (default) or None';
	PRINT '  @with_sample_percent    TF2371 (default), a number, or NULL';
	PRINT '  @with_persist_sample_percent  Y/N (default N)';
	PRINT '  @RespectPersistedSample Y = honor a stat''s persisted rate as desired (def Y)';
	PRINT '  @ModificationThreshold  % modified that triggers an update (def 5)';
	PRINT '  @SamplingGapTolerance   Allowed gap vs desired sample % (def 2)';
	PRINT '  @HotSkipHours/@ColdSkipHours  Cadence window ends (def 24 / 720)';
	PRINT '  @DefaultSkipHours       Cadence when usage untrusted (def 168)';
	PRINT '  @UsagePriorityWeight    Weight for usage percentile (def 5)';
	PRINT '  @MinNumberOfStatsRows/@MaxNumberOfStatsRows  Row-count bounds';
	PRINT '  @MinInstanceUptimeDays  Trust usage only past this uptime (def 14)';
	PRINT '  @AutoStatsMode          ParentUsage or Modification (column stats)';
	PRINT '  @MaxDOP                 NULL (server default), 1 (serial), or 2-64';
	PRINT '  @TimeLimit              Seconds; stop starting new updates after';
	PRINT '  @Execute                N previews (default), Y runs';
	PRINT '  @LogToTable             Y logs to the CommandLog table';
	PRINT '  @CommandLog             3-part name of CommandLog table (default master.dbo.CommandLog)';
	PRINT '  @StatsOptimizeTableMode NULL/None (default), StatsOptimizeData, or CommandLog';
	PRINT '                          Controls where usage-delta state is persisted:';
	PRINT '                            None = no state; uses absolute average for uses/day';
	PRINT '                            StatsOptimizeData = flat MERGE table (constant size)';
	PRINT '                            CommandLog = legacy INSERT rows (one per stat per run)';
	PRINT '  @StatsOptimizeTable     3-part name of the state table (default master.dbo.StatsOptimizeData)';
	PRINT '';
	PRINT '=================================================================';
	PRINT '@STATISTICS SELECTOR';
	PRINT '=================================================================';
	PRINT '  NULL or ALL_STATISTICS = process all statistics (default).';
	PRINT '  Otherwise, comma-separated tokens in 3-part or 4-part form:';
	PRINT '    3-part: Database.Schema.Object    (all stats on that object)';
	PRINT '    4-part: Database.Schema.Object.Statistic (one specific stat)';
	PRINT '  Use % as a wildcard within any part.';
	PRINT '  Prefix a token with - to exclude (exclusion wins).';
	PRINT '  The database part is intersected with @Databases (not an override).';
	PRINT '  Examples:';
	PRINT '    ''SalesDB.dbo.%''              all stats in SalesDB.dbo';
	PRINT '    ''%.%.Orders''              all stats on any "Orders" table';
	PRINT '    ''SalesDB.dbo.Orders.PK%''    stats starting with PK on Orders';
	PRINT '    ''%.%.%,-%.%.%.\_WA%''      all, excluding auto-created _WA stats';
	PRINT '';
	PRINT '=================================================================';
	PRINT 'EXAMPLES';
	PRINT '=================================================================';
	PRINT '  -- Set the variables in the DECLARE block at the top of this';
	PRINT '  -- script, then run it. For example:';
	PRINT '    @Command = ''OPTIMIZE'', @Databases = ''USER_DATABASES''';
	PRINT '    @Command = ''SHOWUSAGE'', @Databases = ''SalesDB''';
	PRINT '    @Statistics = ''SalesDB.dbo.Customers'' (3-part: all stats on table)';
	PRINT '    @Statistics = ''SalesDB.dbo.Customers.IX_Customers_Email'' (4-part)';
	PRINT '';
	PRINT '=================================================================';
	PRINT 'NOTES:';
	PRINT '  - Requires SQL Server 2016 or later.';
	PRINT '  - Usage is read live from sys.dm_db_index_usage_stats but only';
	PRINT '    trusted once instance uptime >= @MinInstanceUptimeDays.';
	PRINT '  - State (last usage snapshot) is kept in the CommandLog table.';
	PRINT '=================================================================';
	PRINT 'VERSION: 2.0';
	PRINT '=================================================================';
	RETURN;
END

-- =============================================================
-- Parameter validation
-- =============================================================
IF (@Databases IS NULL OR LTRIM(RTRIM(@Databases)) = '')
BEGIN
	PRINT 'Error: @Databases is required.';
	PRINT 'Use USER_DATABASES, ALL_DATABASES, SYSTEM_DATABASES, a CSV list, or -Exclusions.';
	RETURN;
END

IF (@UsageModel NOT IN ('CONTINUOUS', 'NONE'))
BEGIN
	PRINT 'Error: @UsageModel must be Continuous or None.';
	RETURN;
END

-- @with_sample_percent: 'TF2371', a numeric percent in [1,100], or NULL (no clause)
IF (@with_sample_percent IS NOT NULL
	AND UPPER(@with_sample_percent) <> 'TF2371'
	AND (ISNUMERIC(@with_sample_percent) = 0
			OR TRY_CONVERT(DECIMAL(5, 2), @with_sample_percent) IS NULL
			OR TRY_CONVERT(DECIMAL(5, 2), @with_sample_percent) < 1
			OR TRY_CONVERT(DECIMAL(5, 2), @with_sample_percent) > 100))
BEGIN
	PRINT 'Error: @with_sample_percent must be ''TF2371'', a number between 1 and 100, or NULL.';
	RETURN;
END

IF (@with_persist_sample_percent NOT IN ('Y', 'N'))
BEGIN
	PRINT 'Error: @with_persist_sample_percent must be Y or N.';
	RETURN;
END

IF (@RespectPersistedSample NOT IN ('Y', 'N'))
BEGIN
	PRINT 'Error: @RespectPersistedSample must be Y or N.';
	RETURN;
END

IF (@AutoStatsMode NOT IN ('PARENTUSAGE', 'MODIFICATION'))
BEGIN
	PRINT 'Error: @AutoStatsMode must be ParentUsage or Modification.';
	RETURN;
END

IF (@Execute NOT IN ('Y', 'N'))
BEGIN
	PRINT 'Error: @Execute must be Y or N.';
	RETURN;
END

IF (@LogToTable NOT IN ('Y', 'N'))
BEGIN
	PRINT 'Error: @LogToTable must be Y or N.';
	RETURN;
END

IF (@MaxDOP IS NOT NULL AND (@MaxDOP < 1 OR @MaxDOP > 64))
BEGIN
	PRINT 'Error: @MaxDOP must be NULL (server default) or between 1 and 64.';
	RETURN;
END

-- @Statistics: NULL/empty = all; ALL_STATISTICS keyword; or 3/4-part dot tokens (CSV, -exclusions)
IF (@Statistics IS NOT NULL AND @Statistics <> '')
BEGIN
	DECLARE @StatValToken NVARCHAR(512);
	DECLARE @StatValRaw NVARCHAR(512);
	DECLARE @StatValParts INT;

	DECLARE cur_Val CURSOR LOCAL FAST_FORWARD FOR
		SELECT LTRIM(RTRIM(value))
		FROM STRING_SPLIT(@Statistics, ',')
		WHERE LTRIM(RTRIM(value)) <> '';

	OPEN cur_Val;
	FETCH NEXT FROM cur_Val INTO @StatValRaw;

	WHILE @@FETCH_STATUS = 0
	BEGIN
		-- Strip leading '-' for exclusion tokens
		SET @StatValToken = CASE WHEN LEFT(@StatValRaw, 1) = '-'
								 THEN LTRIM(RTRIM(SUBSTRING(@StatValRaw, 2, 512)))
								 ELSE @StatValRaw END;

		-- Count parts by dots: PARSENAME handles up to 4
		SET @StatValParts = LEN(@StatValToken) - LEN(REPLACE(@StatValToken, '.', '')) + 1;

		IF (UPPER(@StatValToken) = 'ALL_STATISTICS')
		BEGIN
			-- valid 1-part keyword
			SET @StatValParts = 0; -- sentinel: skip further checks
		END

		IF (@StatValParts NOT IN (0, 3, 4))
		BEGIN
			PRINT 'Error: @Statistics token ''' + @StatValRaw + ''' is invalid.';
			PRINT '  Valid forms: ALL_STATISTICS, DB.Schema.Object (3-part), DB.Schema.Object.Statistic (4-part).';
			PRINT '  Use % as a wildcard within any part. Prefix with - to exclude.';
			CLOSE cur_Val;
			DEALLOCATE cur_Val;
			RETURN;
		END

		FETCH NEXT FROM cur_Val INTO @StatValRaw;
	END

	CLOSE cur_Val;
	DEALLOCATE cur_Val;
END

-- Logging and usage-delta tracking both depend on CommandLog
IF (@LogToTable = 'Y' AND OBJECT_ID(@CommandLog) IS NULL)
BEGIN
	PRINT 'Warning: ' + @CommandLog + ' not found. Logging and usage-delta tracking are disabled.';
	SET @LogToTable = 'N';
END

-- StatsOptimizeData mode requires the state table to exist
IF (@StatsOptimizeTableMode = 'STATSOPTIMIZEDATA'
	AND OBJECT_ID(@StatsOptimizeTable, 'U') IS NULL)
BEGIN
	PRINT 'Warning: ' + @StatsOptimizeTable + ' not found. Falling back to @StatsOptimizeTableMode = ''None''.';
	PRINT '  Run: EXEC master.dbo.StatsOptimize @Command = ''STATSOPTIMIZEDATA_DDL'' to get the CREATE TABLE script.';
	SET @StatsOptimizeTableMode = 'NONE';
END

-- CommandLog mode also requires the CommandLog table to exist
IF (@StatsOptimizeTableMode = 'COMMANDLOG' AND OBJECT_ID(@CommandLog) IS NULL)
BEGIN
	PRINT 'Warning: ' + @CommandLog + ' not found. Falling back to @StatsOptimizeTableMode = ''None''.';
	SET @StatsOptimizeTableMode = 'NONE';
END

-- =============================================================
-- Resolve @Databases tokens into #DatabaseList
-- =============================================================
IF OBJECT_ID('tempdb..#DatabaseList') IS NOT NULL DROP TABLE #DatabaseList;
CREATE TABLE #DatabaseList (DatabaseName sysname NOT NULL PRIMARY KEY);

-- Selectable databases: online, writable, not snapshots
IF OBJECT_ID('tempdb..#DatabaseCandidate') IS NOT NULL DROP TABLE #DatabaseCandidate;
CREATE TABLE #DatabaseCandidate (
	DatabaseName sysname NOT NULL PRIMARY KEY,
	is_system BIT NOT NULL
);

INSERT INTO #DatabaseCandidate (DatabaseName, is_system)
SELECT d.name,
	CASE WHEN d.database_id <= 4 OR d.name IN ('master', 'model', 'msdb', 'tempdb') THEN 1 ELSE 0 END
FROM sys.databases AS d
WHERE d.state = 0                                            -- ONLINE
	AND d.is_read_only = 0                                     -- writable (stats updates need write)
	AND d.source_database_id IS NULL                           -- exclude snapshots
	AND DATABASEPROPERTYEX(d.name, 'Updateability') = 'READ_WRITE';

-- Tokenize @Databases on commas; a leading '-' marks an exclusion
IF OBJECT_ID('tempdb..#Token') IS NOT NULL DROP TABLE #Token;
CREATE TABLE #Token (
	TokenText NVARCHAR(256) NOT NULL,
	IsExclusion BIT NOT NULL
);

INSERT INTO #Token (TokenText, IsExclusion)
SELECT
	CASE WHEN LEFT(t.val, 1) = '-' THEN LTRIM(RTRIM(SUBSTRING(t.val, 2, 256))) ELSE t.val END,
	CASE WHEN LEFT(t.val, 1) = '-' THEN 1 ELSE 0 END
FROM (
	SELECT LTRIM(RTRIM(value)) AS val
	FROM STRING_SPLIT(@Databases, ',')
) AS t
WHERE LTRIM(RTRIM(t.val)) <> '';

-- Inclusions: keyword tokens are case-insensitive; names match by LIKE (supports % wildcards)
INSERT INTO #DatabaseList (DatabaseName)
SELECT DISTINCT c.DatabaseName
FROM #DatabaseCandidate AS c
WHERE EXISTS (
	SELECT 1
	FROM #Token AS tok
	WHERE tok.IsExclusion = 0
		AND (
			(UPPER(tok.TokenText) = 'ALL_DATABASES')
			OR (UPPER(tok.TokenText) = 'USER_DATABASES' AND c.is_system = 0)
			OR (UPPER(tok.TokenText) = 'SYSTEM_DATABASES' AND c.is_system = 1)
			OR (UPPER(tok.TokenText) NOT IN ('ALL_DATABASES', 'USER_DATABASES', 'SYSTEM_DATABASES')
				AND c.DatabaseName LIKE tok.TokenText)
			)
);

-- Exclusions
DELETE dl
FROM #DatabaseList AS dl
WHERE EXISTS (
	SELECT 1
	FROM #Token AS tok
	WHERE tok.IsExclusion = 1
		AND (
			(UPPER(tok.TokenText) = 'ALL_DATABASES')
			OR (UPPER(tok.TokenText) = 'USER_DATABASES'
				AND EXISTS (SELECT 1 FROM #DatabaseCandidate AS c WHERE c.DatabaseName = dl.DatabaseName AND c.is_system = 0))
			OR (UPPER(tok.TokenText) = 'SYSTEM_DATABASES'
				AND EXISTS (SELECT 1 FROM #DatabaseCandidate AS c WHERE c.DatabaseName = dl.DatabaseName AND c.is_system = 1))
			OR (UPPER(tok.TokenText) NOT IN ('ALL_DATABASES', 'USER_DATABASES', 'SYSTEM_DATABASES')
				AND dl.DatabaseName LIKE tok.TokenText)
			)
);

DROP TABLE #Token;
DROP TABLE #DatabaseCandidate;

IF NOT EXISTS (SELECT 1 FROM #DatabaseList)
BEGIN
	PRINT 'No databases matched @Databases = ''' + @Databases + '''.';
	PRINT 'Valid tokens: USER_DATABASES, ALL_DATABASES, SYSTEM_DATABASES, a CSV list (% wildcards allowed), and -Exclusions.';
	RETURN;
END

-- =============================================================
-- Parse @Statistics into #StatFilter
-- =============================================================
-- NULL or empty = all statistics (no filtering). ALL_STATISTICS
-- keyword is also "all". Otherwise each token is 3-part
-- (DB.Schema.Object) or 4-part (DB.Schema.Object.Statistic).
-- The database part is intersected with #DatabaseList downstream.
-- =============================================================
DECLARE @HasStatInclusions BIT = 0;

IF OBJECT_ID('tempdb..#StatFilter') IS NOT NULL DROP TABLE #StatFilter;
CREATE TABLE #StatFilter (
	IsExclusion BIT NOT NULL,
	DbPart NVARCHAR(256) NULL,
	SchemaPart NVARCHAR(256) NULL,
	ObjectPart NVARCHAR(256) NULL,
	StatPart NVARCHAR(256) NULL
);

IF (@Statistics IS NOT NULL AND @Statistics <> ''
	AND UPPER(@Statistics) <> 'ALL_STATISTICS')
BEGIN
	INSERT INTO #StatFilter (IsExclusion, DbPart, SchemaPart, ObjectPart, StatPart)
	SELECT
		CASE WHEN LEFT(t.val, 1) = '-' THEN 1 ELSE 0 END,
		-- PARSENAME works right-to-left: part 4=leftmost, part 1=rightmost
		-- 4-part (dots=3): DB.Schema.Object.Stat -> PARSENAME(x,4)=DB, (3)=Schema, (2)=Object, (1)=Stat
		-- 3-part (dots=2): DB.Schema.Object      -> PARSENAME(x,3)=DB, (2)=Schema, (1)=Object; Stat=NULL
		CASE WHEN LEN(t.clean) - LEN(REPLACE(t.clean, '.', '')) = 3
			THEN PARSENAME(t.clean, 4)
			ELSE PARSENAME(t.clean, 3) END,
		CASE WHEN LEN(t.clean) - LEN(REPLACE(t.clean, '.', '')) = 3
			THEN PARSENAME(t.clean, 3)
			ELSE PARSENAME(t.clean, 2) END,
		CASE WHEN LEN(t.clean) - LEN(REPLACE(t.clean, '.', '')) = 3
			THEN PARSENAME(t.clean, 2)
			ELSE PARSENAME(t.clean, 1) END,
		CASE WHEN LEN(t.clean) - LEN(REPLACE(t.clean, '.', '')) = 3
			THEN PARSENAME(t.clean, 1)
			ELSE NULL END
	FROM (
		SELECT
			LTRIM(RTRIM(value)) AS val,
			CASE WHEN LEFT(LTRIM(RTRIM(value)), 1) = '-'
				 THEN LTRIM(RTRIM(SUBSTRING(LTRIM(RTRIM(value)), 2, 512)))
				 ELSE LTRIM(RTRIM(value)) END AS clean
		FROM STRING_SPLIT(@Statistics, ',')
		WHERE LTRIM(RTRIM(value)) <> ''
	) AS t
	WHERE UPPER(t.clean) <> 'ALL_STATISTICS';

	IF EXISTS (SELECT 1 FROM #StatFilter WHERE IsExclusion = 0)
		SET @HasStatInclusions = 1;
END

-- =============================================================
-- Uptime gate: only trust usage DMVs once the instance has been
-- up long enough to have representative seek/scan/lookup counts.
-- =============================================================
DECLARE @InstanceStart DATETIME;
DECLARE @UptimeDays INT;
DECLARE @TrustUsage BIT;
DECLARE @EffectiveModel VARCHAR(20);

SELECT @InstanceStart = sqlserver_start_time
FROM sys.dm_os_sys_info;

SET @UptimeDays = DATEDIFF(DAY, @InstanceStart, GETDATE());
SET @TrustUsage = CASE WHEN @UptimeDays >= @MinInstanceUptimeDays THEN 1 ELSE 0 END;

-- The model actually used downstream. Usage-based models collapse to
-- 'NONE' when usage cannot be trusted yet.
SET @EffectiveModel = @UsageModel;
IF (@TrustUsage = 0 AND @EffectiveModel <> 'NONE')
BEGIN
	PRINT 'Warning: instance uptime is ' + CAST(@UptimeDays AS VARCHAR(10)) + ' day(s), below @MinInstanceUptimeDays = '
		+ CAST(@MinInstanceUptimeDays AS VARCHAR(10)) + '.';
	PRINT '  Usage statistics are not yet representative; falling back to @UsageModel = ''None''';
	PRINT '  (cadence uses @DefaultSkipHours = ' + CAST(@DefaultSkipHours AS VARCHAR(10))
		+ ' hour(s); usage no longer affects priority).';
	SET @EffectiveModel = 'NONE';
END

-- =============================================================
-- Gather statistics metadata + usage into #StatsWork
-- =============================================================
IF OBJECT_ID('tempdb..#StatsWork') IS NOT NULL DROP TABLE #StatsWork;
CREATE TABLE #StatsWork (
	DatabaseName sysname NOT NULL,
	SchemaName sysname NOT NULL,
	ObjectName sysname NOT NULL,
	object_id INT NOT NULL,
	StatsName sysname NOT NULL,
	stats_id INT NOT NULL,
	auto_created BIT NULL,
	user_created BIT NULL,
	is_index_stat BIT NOT NULL,
	is_memory_optimized BIT NOT NULL DEFAULT (0),
	is_columnstore BIT NOT NULL DEFAULT (0),
	last_updated DATETIME2 NULL,
	[Rows] BIGINT NULL,
	rows_sampled BIGINT NULL,
	modification_counter BIGINT NULL,
	sampled_pct DECIMAL(10, 2) NULL,
	modified_pct DECIMAL(10, 2) NULL,
	days_since_update INT NULL,
	cur_user_seeks BIGINT NULL,
	cur_user_scans BIGINT NULL,
	cur_user_lookups BIGINT NULL,
	cur_total_uses BIGINT NULL,
	prev_total_uses BIGINT NULL,
	prev_snapshot_time DATETIME NULL,
	uses_per_day DECIMAL(18, 2) NULL,
	usage_percentile DECIMAL(9, 4) NULL,
	tf2371_sample INT NULL,
	desired_sampling_rate DECIMAL(5, 2) NULL,
	has_persisted_sample BIT NULL,
	persisted_sample_percent DECIMAL(5, 2) NULL,
	effective_skip_hours INT NULL,
	order_by_priority_score FLOAT NULL,
	[started] DATETIME NULL,
	finished DATETIME NULL,
	sec_elapsed BIGINT NULL,
	rows_per_sec FLOAT NULL,
	processed BIT NOT NULL DEFAULT (0),
	IsCandidate BIT NOT NULL DEFAULT (0),
	SkipReason VARCHAR(100) NULL
);

-- Detect whether sys.dm_db_stats_properties exposes persisted sample columns (SQL 2019+ / 2016 SP2 CU17+)
DECLARE @HasPersistedSampleSupport BIT = 0;
IF EXISTS (
	SELECT 1
	FROM sys.dm_exec_describe_first_result_set(
		N'SELECT * FROM sys.dm_db_stats_properties(0, 0)', NULL, 0)
	WHERE name = 'has_persisted_sample'
)
	SET @HasPersistedSampleSupport = 1;

DECLARE @SQL NVARCHAR(MAX);
DECLARE @CurrentDb sysname;

DECLARE cur_Db CURSOR LOCAL FAST_FORWARD FOR
	SELECT DatabaseName FROM #DatabaseList ORDER BY DatabaseName;

OPEN cur_Db;
FETCH NEXT FROM cur_Db INTO @CurrentDb;

WHILE @@FETCH_STATUS = 0
BEGIN
	BEGIN TRY
		SET @SQL = N'
USE ' + QUOTENAME(@CurrentDb) + N';
;WITH ObjectUsage AS (
SELECT ius.object_id,
	SUM(ISNULL(ius.user_seeks, 0))   AS obj_seeks,
	SUM(ISNULL(ius.user_scans, 0))   AS obj_scans,
	SUM(ISNULL(ius.user_lookups, 0)) AS obj_lookups
FROM sys.dm_db_index_usage_stats AS ius
WHERE ius.database_id = DB_ID()
GROUP BY ius.object_id
)
INSERT INTO #StatsWork (
DatabaseName, SchemaName, ObjectName, object_id, StatsName, stats_id,
auto_created, user_created, is_index_stat, is_memory_optimized, is_columnstore,
last_updated, [Rows], rows_sampled, modification_counter,
sampled_pct, modified_pct, days_since_update,
cur_user_seeks, cur_user_scans, cur_user_lookups, cur_total_uses'
+ CASE WHEN @HasPersistedSampleSupport = 1
	THEN N', has_persisted_sample, persisted_sample_percent'
	ELSE N'' END + N'
)
SELECT
DB_NAME(),
sch.name,
o.name,
s.object_id,
s.name,
s.stats_id,
s.auto_created,
s.user_created,
CASE WHEN i.index_id IS NOT NULL THEN 1 ELSE 0 END,
ISNULL(t.is_memory_optimized, 0),
CASE WHEN i.type IN (5, 6) THEN 1 ELSE 0 END,
sp.last_updated,
sp.rows,
sp.rows_sampled,
sp.modification_counter,
CAST(100.0 * sp.rows_sampled / NULLIF(sp.rows, 0) AS DECIMAL(10, 2)),
CASE WHEN sp.rows > 0 THEN CAST(100.0 * sp.modification_counter / sp.rows AS DECIMAL(10, 2)) ELSE 0 END,
DATEDIFF(DAY, sp.last_updated, GETDATE()),
CASE WHEN i.index_id IS NOT NULL THEN ISNULL(ius.user_seeks, 0)
		WHEN @p_AutoStatsMode = ''PARENTUSAGE'' THEN ISNULL(ou.obj_seeks, 0)
		ELSE 0 END,
CASE WHEN i.index_id IS NOT NULL THEN ISNULL(ius.user_scans, 0)
		WHEN @p_AutoStatsMode = ''PARENTUSAGE'' THEN ISNULL(ou.obj_scans, 0)
		ELSE 0 END,
CASE WHEN i.index_id IS NOT NULL THEN ISNULL(ius.user_lookups, 0)
		WHEN @p_AutoStatsMode = ''PARENTUSAGE'' THEN ISNULL(ou.obj_lookups, 0)
		ELSE 0 END,
CASE WHEN i.index_id IS NOT NULL
		THEN ISNULL(ius.user_seeks, 0) + ISNULL(ius.user_scans, 0) + ISNULL(ius.user_lookups, 0)
		WHEN @p_AutoStatsMode = ''PARENTUSAGE''
		THEN ISNULL(ou.obj_seeks, 0) + ISNULL(ou.obj_scans, 0) + ISNULL(ou.obj_lookups, 0)
		ELSE 0 END'
+ CASE WHEN @HasPersistedSampleSupport = 1
	THEN N',
CAST(ISNULL(sp.has_persisted_sample, 0) AS BIT),
CAST(sp.persisted_sample_percent AS DECIMAL(5, 2))'
	ELSE N'' END + N'
FROM sys.stats AS s
INNER JOIN sys.objects AS o ON s.object_id = o.object_id
INNER JOIN sys.schemas AS sch ON o.schema_id = sch.schema_id
CROSS APPLY sys.dm_db_stats_properties(s.object_id, s.stats_id) AS sp
LEFT OUTER JOIN sys.indexes AS i ON i.object_id = s.object_id AND i.index_id = s.stats_id
LEFT OUTER JOIN sys.dm_db_index_usage_stats AS ius
ON ius.database_id = DB_ID() AND ius.object_id = s.object_id AND ius.index_id = s.stats_id
LEFT OUTER JOIN ObjectUsage AS ou ON ou.object_id = s.object_id
LEFT OUTER JOIN sys.tables AS t ON t.object_id = o.object_id
WHERE o.type IN (''U'', ''V'')
AND o.is_ms_shipped = 0
AND sch.name <> ''sys'';';

		EXEC sp_executesql @SQL,
			N'@p_AutoStatsMode varchar(20)',
			@AutoStatsMode;
	END TRY
	BEGIN CATCH
		PRINT 'Warning: failed to gather statistics for database ' + QUOTENAME(@CurrentDb) + ' - ' + ERROR_MESSAGE();
	END CATCH

	FETCH NEXT FROM cur_Db INTO @CurrentDb;
END

CLOSE cur_Db;
DEALLOCATE cur_Db;

-- =============================================================
-- Apply @Statistics inclusion/exclusion filter to #StatsWork
-- =============================================================
-- Inclusions: if any non-exclusion tokens exist, only keep rows
-- that match at least one inclusion token (Ola semantics).
IF (@HasStatInclusions = 1)
BEGIN
	DELETE sw
	FROM #StatsWork AS sw
	WHERE NOT EXISTS (
		SELECT 1
		FROM #StatFilter AS f
		WHERE f.IsExclusion = 0
		  AND sw.DatabaseName LIKE f.DbPart
		  AND sw.SchemaName LIKE f.SchemaPart
		  AND sw.ObjectName LIKE f.ObjectPart
		  AND (f.StatPart IS NULL OR sw.StatsName LIKE f.StatPart)
	);
END

-- Exclusions: remove any row matching an exclusion token (exclusion wins).
IF EXISTS (SELECT 1 FROM #StatFilter WHERE IsExclusion = 1)
BEGIN
	DELETE sw
	FROM #StatsWork AS sw
	WHERE EXISTS (
		SELECT 1
		FROM #StatFilter AS f
		WHERE f.IsExclusion = 1
		  AND sw.DatabaseName LIKE f.DbPart
		  AND sw.SchemaName LIKE f.SchemaPart
		  AND sw.ObjectName LIKE f.ObjectPart
		  AND (f.StatPart IS NULL OR sw.StatsName LIKE f.StatPart)
	);
END

IF NOT EXISTS (SELECT 1 FROM #StatsWork)
BEGIN
	PRINT 'No statistics found for the requested databases / filters.';
	DROP TABLE #StatsWork;
	DROP TABLE #DatabaseList;
	RETURN;
END

-- =============================================================
-- Read prior usage snapshot per statistic
-- (used to compute the usage delta between runs)
-- Mode: STATSOPTIMIZEDATA = flat table, COMMANDLOG = XML in
--       CommandLog rows, NONE = skip (absolute average only).
-- =============================================================
DECLARE @SqlSnapshotRead NVARCHAR(MAX);

IF (@StatsOptimizeTableMode = 'STATSOPTIMIZEDATA')
BEGIN
	SET @SqlSnapshotRead = N'
	UPDATE sw
	SET sw.prev_total_uses = sod.TotalUses,
		sw.prev_snapshot_time = sod.SnapshotTime
	FROM #StatsWork AS sw
	INNER JOIN ' + @StatsOptimizeTableQuoted + N' AS sod
		ON sod.DatabaseName = sw.DatabaseName
		AND sod.SchemaName = sw.SchemaName
		AND sod.ObjectName = sw.ObjectName
		AND sod.StatsName = sw.StatsName;';
	EXEC sp_executesql @SqlSnapshotRead;
END
ELSE IF (@StatsOptimizeTableMode = 'COMMANDLOG' AND OBJECT_ID(@CommandLog) IS NOT NULL)
BEGIN
	SET @SqlSnapshotRead = N'
	;WITH LastSnap AS (
		SELECT
			cl.DatabaseName,
			cl.SchemaName,
			cl.ObjectName,
			cl.StatisticsName,
			cl.StartTime,
			cl.ExtendedInfo,
			ROW_NUMBER() OVER (
				PARTITION BY cl.DatabaseName, cl.SchemaName, cl.ObjectName, cl.StatisticsName
				ORDER BY cl.ID DESC
			) AS rn
		FROM ' + @CommandLogQuoted + N' AS cl
		WHERE cl.CommandType = ''STATS_USAGE_SNAPSHOT''
	)
	UPDATE sw
	SET sw.prev_total_uses = TRY_CONVERT(BIGINT, ls.ExtendedInfo.value(''(/StatsOptimize/TotalUses)[1]'', ''varchar(40)'')),
		sw.prev_snapshot_time = ls.StartTime
	FROM #StatsWork AS sw
	INNER JOIN LastSnap AS ls
		ON ls.rn = 1
		AND ls.DatabaseName = sw.DatabaseName
		AND ls.SchemaName = sw.SchemaName
		AND ls.ObjectName = sw.ObjectName
		AND ls.StatisticsName = sw.StatsName;';
	EXEC sp_executesql @SqlSnapshotRead;
END
-- ELSE: mode = 'NONE' -- no prior snapshot; uses_per_day will use absolute average

-- =============================================================
-- Compute uses/day: prefer the snapshot delta, otherwise fall
-- back to the absolute average since instance start.
-- =============================================================
UPDATE #StatsWork
SET uses_per_day =
	CASE
		WHEN prev_total_uses IS NOT NULL
				AND prev_snapshot_time IS NOT NULL
				AND cur_total_uses >= prev_total_uses
				AND DATEDIFF(SECOND, prev_snapshot_time, GETDATE()) > 0
			THEN CAST((cur_total_uses - prev_total_uses) * 86400.0
					/ DATEDIFF(SECOND, prev_snapshot_time, GETDATE()) AS DECIMAL(18, 2))
		WHEN @UptimeDays > 0
			THEN CAST(cur_total_uses * 1.0 / @UptimeDays AS DECIMAL(18, 2))
		ELSE CAST(cur_total_uses AS DECIMAL(18, 2))
	END;

-- =============================================================
-- Usage percentile (0-100) across the whole run. Higher = busier.
-- Drives both cadence (skip window) and priority weighting.
-- Set to 0 when usage is untrusted or @UsageModel = 'None', so
-- those runs rank purely on size / staleness / churn.
-- =============================================================
IF (@EffectiveModel = 'NONE')
BEGIN
	UPDATE #StatsWork
	SET usage_percentile = 0;
END
ELSE
BEGIN
	;WITH Ranked AS (
		SELECT
			object_id,
			stats_id,
			PERCENT_RANK() OVER (ORDER BY uses_per_day) AS pr
		FROM #StatsWork
	)
	UPDATE sw
	SET sw.usage_percentile = CAST(r.pr * 100.0 AS DECIMAL(9, 4))
	FROM #StatsWork AS sw
	INNER JOIN Ranked AS r
		ON r.object_id = sw.object_id
		AND r.stats_id = sw.stats_id;

	UPDATE #StatsWork
	SET usage_percentile = 0
	WHERE usage_percentile IS NULL;
END

-- =============================================================
-- TF2371 size curve: sample size is driven by table SIZE, never
-- by usage. Smaller tables are sampled heavily (up to a full
-- scan); very large tables are sampled lightly.
--   CEILING(20.0 * POWER(rows / 25000.0, -0.265)) clamped [1,100]
-- Examples: ~162M rows -> 2%, ~8.6M -> 5%, ~4.5B -> 1%.
-- =============================================================
UPDATE #StatsWork
SET tf2371_sample =
	CASE
		WHEN [Rows] IS NULL OR [Rows] <= 0 THEN 100
		WHEN CEILING(20.0 * POWER(CAST([Rows] AS FLOAT) / 25000.0, -0.265)) > 100 THEN 100
		WHEN CEILING(20.0 * POWER(CAST([Rows] AS FLOAT) / 25000.0, -0.265)) < 1 THEN 1
		ELSE CAST(CEILING(20.0 * POWER(CAST([Rows] AS FLOAT) / 25000.0, -0.265)) AS INT)
	END;

-- =============================================================
-- desired_sampling_rate: the percent we will actually request.
--   @with_sample_percent = 'TF2371' -> the size curve above
--   @with_sample_percent = <number> -> force that percent
--   @with_sample_percent IS NULL    -> no SAMPLE/FULLSCAN clause
-- =============================================================
IF (@with_sample_percent IS NULL)
BEGIN
	UPDATE #StatsWork SET desired_sampling_rate = NULL;
END
ELSE IF (UPPER(@with_sample_percent) = 'TF2371')
BEGIN
	UPDATE #StatsWork SET desired_sampling_rate = tf2371_sample;
END
ELSE
BEGIN
	UPDATE #StatsWork SET desired_sampling_rate = TRY_CONVERT(DECIMAL(5, 2), @with_sample_percent);
END

-- =============================================================
-- Override: respect persisted sample rate when the DBA explicitly
-- set PERSIST_SAMPLE_PERCENT = ON for a statistic (SQL 2019+).
-- The persisted rate becomes the desired floor; the "never
-- downgrade" gap logic is already one-directional, so a stat
-- already sampled above the persisted rate will not be re-sampled.
-- =============================================================
IF (@RespectPersistedSample = 'Y' AND @HasPersistedSampleSupport = 1)
BEGIN
	UPDATE #StatsWork
	SET desired_sampling_rate = persisted_sample_percent
	WHERE has_persisted_sample = 1
	  AND persisted_sample_percent IS NOT NULL
	  AND persisted_sample_percent > 0;
END

-- =============================================================
-- Cadence: how long to wait before a stat is eligible again.
-- Trusted + Continuous: interpolate from @ColdSkipHours down to
-- @HotSkipHours by usage_percentile (busier = shorter window).
-- Otherwise (untrusted or @UsageModel = 'None'): @DefaultSkipHours.
-- =============================================================
IF (@EffectiveModel = 'CONTINUOUS')
BEGIN
	UPDATE #StatsWork
	SET effective_skip_hours =
		CAST(ROUND(
			@ColdSkipHours
			+ (ISNULL(usage_percentile, 0) / 100.0) * (@HotSkipHours - @ColdSkipHours)
		, 0) AS INT);
END
ELSE
BEGIN
	UPDATE #StatsWork SET effective_skip_hours = @DefaultSkipHours;
END

-- =============================================================
-- SHOWUSAGE: report the uses/day distribution and the size-driven
-- sample each stat would get. Read-only: changes nothing.
-- =============================================================
DECLARE @ExaminedCount INT;
SELECT @ExaminedCount = COUNT(*) FROM #StatsWork;

IF (@Command = 'SHOWUSAGE')
BEGIN
	PRINT '=================================================================';
	PRINT 'StatsOptimize - SHOWUSAGE';
	PRINT '=================================================================';
	PRINT 'Instance uptime: ' + CAST(@UptimeDays AS VARCHAR(10)) + ' day(s)'
		+ CASE WHEN @TrustUsage = 1 THEN ' (usage trusted)' ELSE ' (usage NOT yet trusted)' END;
	PRINT 'Usage model in effect: ' + @EffectiveModel;
	PRINT 'Statistics examined: ' + CAST(@ExaminedCount AS VARCHAR(20));
	PRINT '';
	PRINT 'Sample size follows table size (TF2371 curve); usage_percentile';
	PRINT 'governs cadence (effective_skip_hours) and priority order only.';
	PRINT '';

	-- Result set 1: per-database uses/day percentile breakpoints
	;WITH Pctl AS (
		SELECT DISTINCT
			DatabaseName,
			PERCENTILE_CONT(0.50) WITHIN GROUP (ORDER BY uses_per_day) OVER (PARTITION BY DatabaseName) AS P50,
			PERCENTILE_CONT(0.75) WITHIN GROUP (ORDER BY uses_per_day) OVER (PARTITION BY DatabaseName) AS P75,
			PERCENTILE_CONT(0.90) WITHIN GROUP (ORDER BY uses_per_day) OVER (PARTITION BY DatabaseName) AS P90,
			PERCENTILE_CONT(0.95) WITHIN GROUP (ORDER BY uses_per_day) OVER (PARTITION BY DatabaseName) AS P95,
			PERCENTILE_CONT(0.99) WITHIN GROUP (ORDER BY uses_per_day) OVER (PARTITION BY DatabaseName) AS P99
		FROM #StatsWork
	)
	SELECT
		p.DatabaseName AS [database_name],
		(SELECT COUNT(*) FROM #StatsWork sw WHERE sw.DatabaseName = p.DatabaseName) AS stats_count,
		CAST(p.P50 AS DECIMAL(18, 2))                AS p50_uses_per_day,
		CAST(p.P75 AS DECIMAL(18, 2))                AS p75_uses_per_day,
		CAST(p.P90 AS DECIMAL(18, 2))                AS p90_uses_per_day,
		CAST(p.P95 AS DECIMAL(18, 2))                AS p95_uses_per_day,
		CAST(p.P99 AS DECIMAL(18, 2))                AS p99_uses_per_day
	FROM Pctl AS p
	ORDER BY p.DatabaseName;

	-- Result set 2: sample-size distribution from the TF2371 curve
	SELECT
		CASE WHEN tf2371_sample >= 95 THEN 'FULLSCAN' ELSE CAST(tf2371_sample AS VARCHAR(10)) + '%' END AS tf2371_sample,
		COUNT(*)        AS stats_count,
		MIN([Rows])     AS min_rows,
		MAX([Rows])     AS max_rows
	FROM #StatsWork
	GROUP BY CASE WHEN tf2371_sample >= 95 THEN 'FULLSCAN' ELSE CAST(tf2371_sample AS VARCHAR(10)) + '%' END
	ORDER BY MIN([Rows]) DESC;

	-- Result set 3: the busiest statistics (top 50 by uses/day)
	SELECT TOP (50)
		DatabaseName AS [database_name],
		SchemaName AS [schema_name],
		ObjectName AS [object_name],
		StatsName AS stats_name,
		CASE WHEN is_index_stat = 1 THEN 'Index' ELSE 'Column' END AS kind,
		CASE WHEN is_memory_optimized = 1 THEN 'Memory-Optimized'
			 WHEN is_columnstore = 1 THEN 'Columnstore'
			 ELSE 'Rowstore' END AS storage_type,
		[Rows] AS [rows],
		cur_total_uses,
		uses_per_day,
		usage_percentile,
		CASE WHEN tf2371_sample >= 95 THEN 'FULLSCAN' ELSE CAST(tf2371_sample AS VARCHAR(10)) + '%' END AS tf2371_sample,
		effective_skip_hours,
		modified_pct,
		sampled_pct,
		days_since_update
	FROM #StatsWork
	ORDER BY uses_per_day DESC, cur_total_uses DESC;

	DROP TABLE #StatsWork;
	DROP TABLE #DatabaseList;
	RETURN;
END

-- =============================================================
-- OPTIMIZE: flag candidates, then preview or execute updates.
-- Skip when: too few (or too many) rows, still within the cadence
-- window, or neither churned nor under-sampled. Otherwise update.
-- Trigger: modified_pct > @ModificationThreshold (churn)
--          OR sampled_pct below desired by more than the tolerance.
-- =============================================================
UPDATE #StatsWork
SET IsCandidate =
	CASE
		WHEN [Rows] IS NULL OR [Rows] < @MinNumberOfStatsRows THEN 0
		WHEN @MaxNumberOfStatsRows IS NOT NULL AND [Rows] > @MaxNumberOfStatsRows THEN 0
		WHEN ISNULL(days_since_update, 100000) * 24 < effective_skip_hours THEN 0
		WHEN modified_pct > @ModificationThreshold
				OR (desired_sampling_rate IS NOT NULL
					AND sampled_pct IS NOT NULL
					AND sampled_pct < (desired_sampling_rate - @SamplingGapTolerance))
			THEN 1
		ELSE 0
	END;

UPDATE #StatsWork
SET SkipReason =
	CASE
		WHEN [Rows] IS NULL OR [Rows] < @MinNumberOfStatsRows
			THEN 'Below @MinNumberOfStatsRows (' + ISNULL(CAST([Rows] AS VARCHAR(20)), 'null') + ' rows)'
		WHEN @MaxNumberOfStatsRows IS NOT NULL AND [Rows] > @MaxNumberOfStatsRows
			THEN 'Above @MaxNumberOfStatsRows (' + CAST([Rows] AS VARCHAR(20)) + ' rows)'
		WHEN ISNULL(days_since_update, 100000) * 24 < effective_skip_hours
			THEN 'Within cadence (updated ' + CAST(days_since_update AS VARCHAR(10)) + 'd ago, skip ' + CAST(effective_skip_hours AS VARCHAR(10)) + 'h)'
		ELSE 'Below threshold (modified ' + CAST(modified_pct AS VARCHAR(10)) + '%, sampled '
				+ ISNULL(CAST(sampled_pct AS VARCHAR(10)), 'n/a') + '% vs desired '
				+ ISNULL(CAST(desired_sampling_rate AS VARCHAR(10)), 'n/a') + '%)'
	END
WHERE IsCandidate = 0;

-- =============================================================
-- Priority score (higher = process earlier). Combines staleness,
-- churn, the sampling gap (desired vs actual, beyond tolerance),
-- and the usage percentile. GREATEST is emulated with CASE for
-- SQL Server 2016 compatibility.
-- =============================================================
UPDATE #StatsWork
SET order_by_priority_score =
	(CASE
		WHEN days_since_update IS NULL THEN 365
		WHEN days_since_update > 365 THEN 365
		ELSE days_since_update
		END) * 1.0
	+ (CASE
		WHEN modified_pct IS NULL THEN 0
		WHEN modified_pct > 100 THEN 100
		ELSE modified_pct
		END) * 10.0
	+ (CASE
		WHEN desired_sampling_rate IS NULL OR sampled_pct IS NULL THEN 0
		WHEN (desired_sampling_rate - sampled_pct - @SamplingGapTolerance) > 0
			THEN (desired_sampling_rate - sampled_pct - @SamplingGapTolerance)
		ELSE 0
		END) * 20.0
	+ ISNULL(usage_percentile, 0) * @UsagePriorityWeight;

DECLARE @CandidateCount INT;
DECLARE @SuccessCount INT = 0;
DECLARE @FailCount INT = 0;
SELECT @CandidateCount = COUNT(*) FROM #StatsWork WHERE IsCandidate = 1;

PRINT '=================================================================';
PRINT 'StatsOptimize - OPTIMIZE';
PRINT '=================================================================';
PRINT 'Usage model: ' + @EffectiveModel
	+ CASE WHEN @EffectiveModel <> @UsageModel THEN ' (requested ' + @UsageModel + ', usage untrusted)' ELSE '' END;
PRINT 'Sample size: ' + CASE WHEN @with_sample_percent IS NULL THEN 'engine default (no clause)'
							WHEN UPPER(@with_sample_percent) = 'TF2371' THEN 'TF2371 size curve'
							ELSE @with_sample_percent + ' percent (forced)' END;
PRINT 'MAXDOP:  ' + CASE WHEN @MaxDOP IS NULL THEN 'server default' ELSE CAST(@MaxDOP AS VARCHAR(10)) END;
PRINT 'Mode:  ' + CASE WHEN @Execute = 'Y' THEN 'EXECUTE' ELSE 'PREVIEW (no changes made)' END;
PRINT 'Statistics examined:  ' + CAST(@ExaminedCount AS VARCHAR(20));
PRINT 'Statistics to update: ' + CAST(@CandidateCount AS VARCHAR(20));
PRINT '';

-- Result set: the statistics selected for update (priority order)
SELECT
	DatabaseName AS [database_name],
	SchemaName AS [schema_name],
	ObjectName AS [object_name],
	StatsName AS stats_name,
	CASE WHEN is_index_stat = 1 THEN 'Index' ELSE 'Column' END AS kind,
	CASE WHEN is_memory_optimized = 1 THEN 'Memory-Optimized'
		 WHEN is_columnstore = 1 THEN 'Columnstore'
		 ELSE 'Rowstore' END AS storage_type,
	[Rows] AS [rows],
	uses_per_day,
	usage_percentile,
	modified_pct,
	sampled_pct,
	days_since_update,
	effective_skip_hours,
	CASE WHEN desired_sampling_rate IS NULL THEN 'default'
			WHEN desired_sampling_rate >= 95.0 THEN 'FULLSCAN'
			ELSE CAST(CASE WHEN desired_sampling_rate < 1 THEN 1 ELSE CAST(ROUND(desired_sampling_rate, 0) AS INT) END AS VARCHAR(10))
	END             AS sample_planned,
	CAST(order_by_priority_score AS DECIMAL(18, 2)) AS priority
FROM #StatsWork
WHERE IsCandidate = 1
ORDER BY order_by_priority_score DESC, DatabaseName, SchemaName, ObjectName, StatsName;

-- Cursor over the selected statistics, in priority order
DECLARE @od_Db sysname, @od_Schema sysname, @od_Object sysname, @od_Stats sysname;
DECLARE @od_Desired DECIMAL(5, 2), @od_Rows BIGINT;
DECLARE @od_IsMemOpt BIT, @od_IsColumnstore BIT;
DECLARE @SamplePct INT, @StatCmd NVARCHAR(MAX), @SampleClause NVARCHAR(100);
DECLARE @cmdStart DATETIME2, @cmdEnd DATETIME2, @errNum INT, @errMsg NVARCHAR(MAX);
DECLARE @OptimizeStart DATETIME2 = SYSDATETIME();
DECLARE @TimeLimitHit BIT = 0;
DECLARE @ElapsedMs BIGINT, @ScannedRows FLOAT;
DECLARE @RowsScannedTotal FLOAT = 0, @MsElapsedTotal FLOAT = 0;
DECLARE @PredictedSec FLOAT, @ElapsedSec BIGINT;

IF (@CandidateCount > 0)
BEGIN
	DECLARE cur_Opt CURSOR LOCAL FAST_FORWARD FOR
		SELECT DatabaseName, SchemaName, ObjectName, StatsName, desired_sampling_rate, [Rows],
			is_memory_optimized, is_columnstore
		FROM #StatsWork
		WHERE IsCandidate = 1
		ORDER BY order_by_priority_score DESC, DatabaseName, SchemaName, ObjectName, StatsName;

	OPEN cur_Opt;
	FETCH NEXT FROM cur_Opt INTO @od_Db, @od_Schema, @od_Object, @od_Stats, @od_Desired, @od_Rows,
		@od_IsMemOpt, @od_IsColumnstore;

	WHILE @@FETCH_STATUS = 0
	BEGIN
		-- Sample size is driven by table size (desired_sampling_rate):
		--   NULL  -> no clause (engine default)
		--   >= 95 -> WITH FULLSCAN
		--   else  -> WITH SAMPLE n PERCENT (integer only; decimals error)
		-- PERSIST_SAMPLE_PERCENT is appended only when explicitly requested.
		-- Resolved before the time check so the row-scan estimate (and thus
		-- the time prediction) reflects the sample size we will request.

		-- Memory-optimized: SAMPLE and MAXDOP are not supported; force FULLSCAN
		IF (@od_IsMemOpt = 1)
		BEGIN
			SET @SamplePct = 100;
			SET @SampleClause = N' WITH FULLSCAN';
		END
		-- Columnstore: FULLSCAN is cheap (batch-mode reads) and produces better histograms
		ELSE IF (@od_IsColumnstore = 1)
		BEGIN
			SET @SamplePct = 100;
			SET @SampleClause = N' WITH FULLSCAN'
				+ CASE WHEN @with_persist_sample_percent = 'Y' THEN N', PERSIST_SAMPLE_PERCENT = ON' ELSE N'' END;
			IF (@MaxDOP IS NOT NULL)
				SET @SampleClause = @SampleClause + N', MAXDOP = ' + CAST(@MaxDOP AS NVARCHAR(3));
		END
		-- Rowstore: normal sample-clause logic
		ELSE IF (@od_Desired IS NULL)
		BEGIN
			SET @SamplePct = NULL;
			SET @SampleClause = N'';
		END
		ELSE IF (@od_Desired >= 95.0)
		BEGIN
			SET @SamplePct = 100;
			SET @SampleClause = N' WITH FULLSCAN'
				+ CASE WHEN @with_persist_sample_percent = 'Y' THEN N', PERSIST_SAMPLE_PERCENT = ON' ELSE N'' END;
		END
		ELSE
		BEGIN
			SET @SamplePct = CASE WHEN @od_Desired < 1 THEN 1 WHEN @od_Desired > 100 THEN 100
									ELSE CAST(ROUND(@od_Desired, 0) AS INT) END;
			SET @SampleClause = N' WITH SAMPLE ' + CAST(@SamplePct AS NVARCHAR(10)) + N' PERCENT'
				+ CASE WHEN @with_persist_sample_percent = 'Y' THEN N', PERSIST_SAMPLE_PERCENT = ON' ELSE N'' END;
		END

		-- Append MAXDOP hint if specified (rowstore only; columnstore handled above; memory-optimized cannot use it)
		IF (@MaxDOP IS NOT NULL AND @od_IsMemOpt = 0 AND @od_IsColumnstore = 0)
		BEGIN
			IF (@SampleClause = N'')
				SET @SampleClause = N' WITH MAXDOP = ' + CAST(@MaxDOP AS NVARCHAR(3));
			ELSE
				SET @SampleClause = @SampleClause + N', MAXDOP = ' + CAST(@MaxDOP AS NVARCHAR(3));
		END

		-- Estimated rows actually scanned = rows * sample fraction. This is
		-- the real unit of work (a 4% sample of 17M rows scans far more than
		-- a 37% sample of 2.5K rows), so it drives both the running rate and
		-- the per-stat time prediction below.
		SET @ScannedRows = ISNULL(@od_Rows, 0) * (ISNULL(@SamplePct, 100) / 100.0);

		SET @ElapsedSec = DATEDIFF(SECOND, @OptimizeStart, SYSDATETIME());

		-- Honor @TimeLimit: stop if already past the limit, or if the
		-- predicted time for this stat would push us past it. The prediction
		-- uses the CUMULATIVE scanned-rows-per-millisecond rate measured so
		-- far (not just the previous stat), so one fast stat cannot skew it.
		IF (@TimeLimit IS NOT NULL)
		BEGIN
			SET @PredictedSec = CASE
					WHEN @RowsScannedTotal > 0 AND @MsElapsedTotal > 0
						THEN (@ScannedRows * @MsElapsedTotal / @RowsScannedTotal) / 1000.0
					ELSE 0
				END;

			IF (@ElapsedSec >= @TimeLimit
				OR (@RowsScannedTotal > 0 AND @MsElapsedTotal > 0
					AND (@ElapsedSec + @PredictedSec) >= @TimeLimit))
			BEGIN
				SET @TimeLimitHit = 1;
				PRINT 'Time limit of ' + CAST(@TimeLimit AS VARCHAR(10)) + ' second(s) reached'
					+ CASE WHEN @ElapsedSec < @TimeLimit THEN ' (next stat would exceed it)' ELSE '' END
					+ '; stopping.';
				BREAK;
			END
		END

		SET @StatCmd = N'USE ' + QUOTENAME(@od_Db) + N'; UPDATE STATISTICS '
			+ QUOTENAME(@od_Schema) + N'.' + QUOTENAME(@od_Object) + N' ' + QUOTENAME(@od_Stats)
			+ @SampleClause + N';';

		IF (@Execute = 'Y')
		BEGIN
			SET @cmdStart = SYSDATETIME();
			SET @errNum = NULL;
			SET @errMsg = NULL;

			BEGIN TRY
				EXEC sp_executesql @StatCmd;
				SET @SuccessCount = @SuccessCount + 1;
				PRINT '  [DONE] ' + @od_Db + '.' + QUOTENAME(@od_Schema) + '.' + QUOTENAME(@od_Object)
					+ ' ' + QUOTENAME(@od_Stats)
					+ ' (' + CASE WHEN @SamplePct IS NULL THEN 'default'
									WHEN @od_Desired >= 95.0 THEN 'FULLSCAN'
									ELSE 'sample ' + CAST(@SamplePct AS VARCHAR(10)) + '%' END + ')';
			END TRY
			BEGIN CATCH
				SET @FailCount = @FailCount + 1;
				SET @errNum = ERROR_NUMBER();
				SET @errMsg = ERROR_MESSAGE();
				PRINT '  [ERROR] ' + @od_Db + '.' + QUOTENAME(@od_Schema) + '.' + QUOTENAME(@od_Object)
					+ ' ' + QUOTENAME(@od_Stats) + ' - ' + @errMsg;
			END CATCH

			SET @cmdEnd = SYSDATETIME();

			-- Record timing in milliseconds (floored to >= 1 ms so a fast stat
			-- cannot read as zero), then fold this stat into the cumulative
			-- scanned-rows / elapsed-ms totals that drive the next prediction.
			-- Accumulating avoids letting a single tiny stat dominate the rate.
			SET @ElapsedMs = CASE WHEN DATEDIFF(MILLISECOND, @cmdStart, @cmdEnd) > 0
									THEN DATEDIFF(MILLISECOND, @cmdStart, @cmdEnd) ELSE 1 END;

			UPDATE #StatsWork
			SET [started] = @cmdStart,
				finished = @cmdEnd,
				sec_elapsed = CAST(ROUND(@ElapsedMs / 1000.0, 0) AS BIGINT),
				rows_per_sec = CASE WHEN @od_Rows IS NOT NULL THEN @od_Rows * 1000.0 / @ElapsedMs ELSE NULL END,
				processed = 1
			WHERE DatabaseName = @od_Db AND SchemaName = @od_Schema
				AND ObjectName = @od_Object AND StatsName = @od_Stats;

			IF (@errNum IS NULL)
			BEGIN
				SET @RowsScannedTotal = @RowsScannedTotal + @ScannedRows;
				SET @MsElapsedTotal = @MsElapsedTotal + @ElapsedMs;
			END

			IF (@LogToTable = 'Y')
			BEGIN
				DECLARE @SqlLog NVARCHAR(MAX);
				SET @SqlLog = N'INSERT INTO ' + @CommandLogQuoted + N'
					(DatabaseName, SchemaName, ObjectName, StatisticsName, CommandType, Command, StartTime, EndTime, ErrorNumber, ErrorMessage)
				VALUES
					(@p_Db, @p_Schema, @p_Object, @p_Stats, ''UPDATE_STATISTICS'', @p_Cmd, @p_Start, @p_End, @p_ErrNum, @p_ErrMsg);';
				EXEC sp_executesql @SqlLog,
					N'@p_Db sysname, @p_Schema sysname, @p_Object sysname, @p_Stats sysname, @p_Cmd NVARCHAR(MAX), @p_Start datetime, @p_End datetime, @p_ErrNum int, @p_ErrMsg NVARCHAR(MAX)',
					@od_Db, @od_Schema, @od_Object, @od_Stats, @StatCmd, @cmdStart, @cmdEnd, @errNum, @errMsg;
			END
		END
		ELSE
		BEGIN
			PRINT '  [PREVIEW] ' + @StatCmd;
		END

		FETCH NEXT FROM cur_Opt INTO @od_Db, @od_Schema, @od_Object, @od_Stats, @od_Desired, @od_Rows,
			@od_IsMemOpt, @od_IsColumnstore;
	END

	CLOSE cur_Opt;
	DEALLOCATE cur_Opt;
END

-- =============================================================
-- Write the usage snapshot for the next run's delta (execute
-- mode only, so preview stays side-effect free).
-- Mode: STATSOPTIMIZEDATA = MERGE into flat table (constant size)
--       COMMANDLOG = INSERT rows into CommandLog (legacy)
--       NONE = skip (no state persisted)
-- =============================================================
IF (@Execute = 'Y')
BEGIN
	DECLARE @SnapTime DATETIME = GETDATE();
	DECLARE @SqlSnapshotWrite NVARCHAR(MAX);

	IF (@StatsOptimizeTableMode = 'STATSOPTIMIZEDATA')
	BEGIN
		SET @SqlSnapshotWrite = N'
		MERGE ' + @StatsOptimizeTableQuoted + N' AS tgt
		USING (
			SELECT DatabaseName, SchemaName, ObjectName, StatsName,
				cur_total_uses, cur_user_seeks, cur_user_scans, cur_user_lookups
			FROM #StatsWork
		) AS src
		ON tgt.DatabaseName = src.DatabaseName
			AND tgt.SchemaName = src.SchemaName
			AND tgt.ObjectName = src.ObjectName
			AND tgt.StatsName = src.StatsName
		WHEN MATCHED THEN
			UPDATE SET
				TotalUses = src.cur_total_uses,
				UserSeeks = src.cur_user_seeks,
				UserScans = src.cur_user_scans,
				UserLookups = src.cur_user_lookups,
				SnapshotTime = @p_SnapTime
		WHEN NOT MATCHED THEN
			INSERT (DatabaseName, SchemaName, ObjectName, StatsName,
					TotalUses, UserSeeks, UserScans, UserLookups, SnapshotTime)
			VALUES (src.DatabaseName, src.SchemaName, src.ObjectName, src.StatsName,
					src.cur_total_uses, src.cur_user_seeks, src.cur_user_scans,
					src.cur_user_lookups, @p_SnapTime);';
		EXEC sp_executesql @SqlSnapshotWrite,
			N'@p_SnapTime datetime',
			@SnapTime;
	END
	ELSE IF (@StatsOptimizeTableMode = 'COMMANDLOG' AND @LogToTable = 'Y')
	BEGIN
		SET @SqlSnapshotWrite = N'
		INSERT INTO ' + @CommandLogQuoted + N'
			(DatabaseName, SchemaName, ObjectName, StatisticsName, CommandType, Command, StartTime, EndTime, ExtendedInfo)
		SELECT
			sw.DatabaseName, sw.SchemaName, sw.ObjectName, sw.StatsName,
			''STATS_USAGE_SNAPSHOT'', ''StatsOptimize usage snapshot'', @p_SnapTime, @p_SnapTime,
			(SELECT
				sw.cur_total_uses    AS TotalUses,
				sw.cur_user_seeks    AS UserSeeks,
				sw.cur_user_scans    AS UserScans,
				sw.cur_user_lookups  AS UserLookups,
				sw.[Rows]            AS [Rows],
				sw.modification_counter AS ModCounter,
				sw.sampled_pct       AS PctSampled,
				sw.uses_per_day      AS UsesPerDay,
				@p_UptimeDays        AS InstanceUptimeDays,
				CONVERT(VARCHAR(30), @p_SnapTime, 126) AS UsageReadAt
			 FOR XML PATH(''StatsOptimize''), TYPE)
		FROM #StatsWork AS sw;';
		EXEC sp_executesql @SqlSnapshotWrite,
			N'@p_SnapTime datetime, @p_UptimeDays int',
			@SnapTime, @UptimeDays;
	END
	-- ELSE: mode = 'NONE' -- no snapshot written
END

-- =============================================================
-- Final summary
-- =============================================================
PRINT '';
PRINT '=================================================================';
IF (@Execute = 'Y')
BEGIN
	PRINT 'Done. Updated: ' + CAST(@SuccessCount AS VARCHAR(10))
		+ ' | Failed: ' + CAST(@FailCount AS VARCHAR(10))
		+ CASE WHEN @TimeLimitHit = 1 THEN ' | Stopped early (time limit)' ELSE '' END;
	IF (@LogToTable = 'Y')
		PRINT 'Logged to ' + @CommandLog + ' (UPDATE_STATISTICS).';
	IF (@StatsOptimizeTableMode = 'STATSOPTIMIZEDATA')
		PRINT 'Usage state persisted to ' + @StatsOptimizeTable + ' (MERGE).';
	ELSE IF (@StatsOptimizeTableMode = 'COMMANDLOG')
		PRINT 'Usage snapshots written to ' + @CommandLog + ' (STATS_USAGE_SNAPSHOT rows).';
END
ELSE
BEGIN
	PRINT 'Preview complete. ' + CAST(@CandidateCount AS VARCHAR(10)) + ' statistic(s) would be updated.';
	PRINT 'Set @Execute = ''Y'' to run them.';
END
PRINT '=================================================================';

-- Cleanup
DROP TABLE #StatsWork;
DROP TABLE #DatabaseList;


