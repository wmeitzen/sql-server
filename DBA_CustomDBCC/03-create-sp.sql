USE [DBAdmin]
GO

SET ANSI_NULLS ON
GO

SET QUOTED_IDENTIFIER ON
GO

/********************************************************************************************************************
*Author: Mike Eastland
*Modified by: William Meitzen
*Notes:  The purpose of this stored procedure is to run one or more DBCC commands as dictated by the parameters *
*    passed at run-time. It has been designed to accommodate VLDBs. It is recommended to create this  *
*    procedure in a dedicated administrative database rather than a system or application database.  *
*Modifications: Logs commands, elapsed time, and errors. @maxDurationHrs can be fractions, to allow 0.5 for 30 min,
* 1.25 for 1 hr 15 min, etc.
********************************************************************************************************************/
alter PROCEDURE [dbo].[DBA_CustomDBCC] (
 @checkAlloc  BIT = 0,     -- Execute DBCC CHECKALLOC
 @checkCat  BIT = 0,     -- Execute DBCC CHECKCATALOG
 @checkDB  BIT = 1,     -- Execute DBCC CHECKDB (which includes CHECKALLOC and CHECKCATALOG)
 @checkNdx  BIT = 1,     -- Include indexes in DBCC commands
 @dbName   SYSNAME = NULL,    -- Run for a single database
 @dbExcludeList VARCHAR(MAX) = NULL,  -- Comma-separated list of databases to exclude
 @debugMode  BIT = 0,     -- Prevent execution of DBCC commands (@debugMode = 1)
 @maxDurationHrs float = 0,     -- Number of hours the procedure is allowed to run (0 = to completion)
 @physOnly  BIT = 0,     -- Run CHECKDB with PHYSICAL_ONLY option
 @tableName  SYSNAME = NULL,    -- Run for a single table
 @tblExcludeList VARCHAR(MAX) = NULL,  -- Comma-separated list of tables to exclude
 @vldbMode  BIT = 0      -- Execute DBCC commands at the table-level for VLDBs
)
AS

SET NOCOUNT, XACT_ABORT ON

DECLARE @db   VARCHAR(128),
  @dbclause VARCHAR(128),
  @end  DATETIME,
  @msg  VARCHAR(1024),
  @restart BIT,
  @sql  NVARCHAR(MAX),
  @tbl  VARCHAR(128),
  @tblid  INT;

DECLARE @db_tbl  TABLE ( DatabaseName VARCHAR(128), ProcFlag  BIT DEFAULT(0) );

DECLARE @check_tbl TABLE ( DatabaseName VARCHAR(128),
    SchemaName  VARCHAR(128),
    TableName  VARCHAR(128) );

declare @sec bigint = 1
declare @min bigint = @sec * 60
declare @hr bigint = @min * 60
declare @day bigint = @hr * 24
declare @wk bigint = @day * 7

DECLARE @ErrorMessage nvarchar(max)
DECLARE @ErrorMessageOriginal nvarchar(max)
DECLARE @Severity int
DECLARE @Error int = 0
declare @LockMessageSeverity int = 16
--DECLARE @ReturnCode int = 0

SET @msg = 'DBCC job on ' + @@SERVERNAME + ' started at ' + CONVERT(VARCHAR, GETDATE()) + '.' + CHAR(10) + CHAR(13);
 RAISERROR(@msg, 0, 0) WITH NOWAIT;

-- Set initial / default variable values
SELECT @vldbMode = ISNULL(@vldbMode, 0), @physOnly = ISNULL(@physOnly, 0), @restart = 1,
  @maxDurationHrs = CASE WHEN @maxDurationHrs IS NULL THEN 0 ELSE @maxDurationHrs END,
  @dbName = CASE LTRIM(RTRIM(@dbName)) WHEN '' THEN NULL ELSE LTRIM(RTRIM(@dbName)) END,
  @dbExcludeList = CASE ISNULL(@dbName, 'NULL') WHEN 'NULL' THEN @dbExcludeList ELSE NULL END;

  -- select getdate(), DATEADD(second, 0.005 * 60 * 60, GETDATE())

SELECT @checkDB = CASE @vldbMode WHEN 0 THEN @checkDB ELSE 0 END,
  @checkCat = CASE @checkDB WHEN 1 THEN 0 ELSE @checkCat END,
  @checkAlloc = CASE @checkDB WHEN 1 THEN 0 ELSE @checkAlloc END;

-- Validate variables
IF @dbName IS NOT NULL AND DB_ID(@dbName) IS NULL
BEGIN
 SET @msg = 'Database {' + @dbName + '} does not exist. Procedure aborted at ' + CONVERT(VARCHAR, GETDATE()) + '.';
  RAISERROR(@msg, 0, 0) WITH NOWAIT;
   RETURN;
END
ELSE
BEGIN
 SET @msg = 'DBCC job will execute for a single database {' + @dbName + '}';
  RAISERROR(@msg, 0, 0) WITH NOWAIT;
END

IF @tableName IS NOT NULL
BEGIN
 IF @vldbMode <> 1
 BEGIN
  SET @msg = 'The @vldbMode parameter must be set if @tableName is not null. Procedure aborted at ' + CONVERT(VARCHAR, GETDATE()) + '.';
   RAISERROR(@msg, 0, 0) WITH NOWAIT;
    RETURN;
 END
 ELSE
 BEGIN
  SET @msg = 'DBCC job will execute for a single table {' + @tableName + '} in each target database.';
   RAISERROR(@msg, 0, 0) WITH NOWAIT;
 END
END

IF @tblExcludeList IS NOT NULL AND @vldbMode <> 1
BEGIN
 SET @msg = 'The @vldbMode parameter must be set if @tblExcludeList is not null. Procedure aborted at ' + CONVERT(VARCHAR, GETDATE()) + '.';
  RAISERROR(@msg, 0, 0) WITH NOWAIT;
   RETURN;
END

IF @checkAlloc = 0 AND @checkCat = 0 AND @checkDB = 0 AND @vldbMode = 0
BEGIN
 SET @msg = 'Invalid parameter combination would result in no DBCC commands executed. Procedure aborted at ' + CONVERT(VARCHAR, GETDATE()) + '.';
  RAISERROR(@msg, 0, 0) WITH NOWAIT;
   RETURN;
END

IF @debugMode = 1
BEGIN
 SET @msg = 'Procedure [' + OBJECT_NAME(@@PROCID) + '] is running in debug mode. No integrity check commands will be executed.';
  RAISERROR(@msg, 0, 0) WITH NOWAIT;
END

INSERT INTO @db_tbl (DatabaseName)
SELECT [name]
FROM [master].sys.databases
WHERE [source_database_id] IS NULL
AND [database_id] <> 2
AND DATABASEPROPERTYEX([name], 'Status') = 'ONLINE'
AND LOWER([name]) = LOWER(ISNULL(@dbName, [name]));

-- Exclude databases
IF (@dbExcludeList IS NOT NULL AND LTRIM(RTRIM(@dbExcludeList)) <> '')
BEGIN
 IF OBJECT_ID('dbo.DBA_CustomDBCC_CommaStringTable') IS NULL
 BEGIN
  SET @msg = 'The function required by skip-database code does not exist.  All databases will be checked.';
   RAISERROR(@msg, 0, 0) WITH NOWAIT;
 END
 ELSE
 BEGIN
  SET @msg = 'The following databases will be skipped: (' + LTRIM(RTRIM(@dbExcludeList)) + ').';
   RAISERROR(@msg, 0, 0) WITH NOWAIT;
  
  DELETE d
  FROM @db_tbl d
   INNER JOIN dbo.DBA_CustomDBCC_CommaStringTable(@dbExcludeList) f ON LOWER(d.DatabaseName) = LOWER(f.[Value]);
 END
END

IF NOT EXISTS ( SELECT * FROM @db_tbl WHERE ProcFlag = 0 )
BEGIN
 SET @msg = 'No databases match the supplied parameters. Procedure aborted at ' + CONVERT(VARCHAR, GETDATE()) + '.';
  RAISERROR(@msg, 0, 0) WITH NOWAIT;
   RETURN;
END

WHILE EXISTS ( SELECT * FROM @db_tbl WHERE ProcFlag = 0 )
BEGIN
 SELECT TOP 1 @db = DatabaseName FROM @db_tbl WHERE ProcFlag = 0 ORDER BY DatabaseName;

 SET @dbclause = '[' + @db + CASE @checkNdx WHEN 1 THEN ']' ELSE '], NOINDEX' END;

 -- Execute database-level DBCC commands
 --BEGIN TRY
  IF @checkAlloc = 1
  BEGIN
   SET @msg = 'DBCC CHECKALLOC against ' + QUOTENAME(@db) + ' started at ' + CONVERT(VARCHAR, GETDATE()) + '.';
    RAISERROR(@msg, 0, 0) WITH NOWAIT;

   SET @sql = 'SET QUOTED_IDENTIFIER OFF SET ARITHABORT ON DBCC CHECKALLOC (' + @dbclause + ') WITH ALL_ERRORMSGS, NO_INFOMSGS';
    RAISERROR(@sql, 0, 0) WITH NOWAIT;

   IF @debugMode = 0
    EXEC sp_ExecuteSQL @sql;

   SET @msg = 'DBCC CHECKALLOC against ' + QUOTENAME(@db) + ' completed at ' + CONVERT(VARCHAR, GETDATE()) + '.';
    RAISERROR(@msg, 0, 0) WITH NOWAIT;
  END
  
  IF @checkCat = 1
  BEGIN
   SET @msg = 'DBCC CATALOG against ' + QUOTENAME(@db) + ' started at ' + CONVERT(VARCHAR, GETDATE()) + '.';
    RAISERROR(@msg, 0, 0) WITH NOWAIT;

   SET @sql = 'SET QUOTED_IDENTIFIER OFF SET ARITHABORT ON DBCC CHECKCATALOG ([' + @db + ']) WITH NO_INFOMSGS';
    RAISERROR(@sql, 0, 0) WITH NOWAIT;

   IF @debugMode = 0
    EXEC sp_ExecuteSQL @sql;

   SET @msg = 'DBCC CATALOG against ' + QUOTENAME(@db) + ' completed at ' + CONVERT(VARCHAR, GETDATE()) + '.';
    RAISERROR(@msg, 0, 0) WITH NOWAIT;
  END

  IF @checkDB = 1
  BEGIN
   SET @msg = 'DBCC CHECKDB against ' + QUOTENAME(@db) + ' started at ' + CONVERT(VARCHAR, GETDATE()) + '.';
    RAISERROR(@msg, 0, 0) WITH NOWAIT;

   SET @sql = 'SET QUOTED_IDENTIFIER OFF SET ARITHABORT ON DBCC CHECKDB (' + @dbclause + ') WITH ALL_ERRORMSGS, NO_INFOMSGS' + 
      CASE @physOnly WHEN 1 THEN ', PHYSICAL_ONLY' ELSE '' END;
    RAISERROR(@sql, 0, 0) WITH NOWAIT;

   IF @debugMode = 0
    EXEC sp_ExecuteSQL @sql;

   SET @msg = 'DBCC CHECKDB against ' + QUOTENAME(@db) + ' completed at ' + CONVERT(VARCHAR, GETDATE()) + '.';
    RAISERROR(@msg, 0, 0) WITH NOWAIT;
  END

  IF @vldbMode = 1
  BEGIN
   SET @sql = 'SELECT [TABLE_CATALOG], [TABLE_SCHEMA], [TABLE_NAME] FROM [' + @db + 
      '].[INFORMATION_SCHEMA].[TABLES] WHERE [TABLE_TYPE] = ''BASE TABLE'' ORDER BY [TABLE_NAME]';

   INSERT INTO @check_tbl ([DatabaseName], [SchemaName], [TableName])
   EXEC sp_ExecuteSQL @sql;
  END

  UPDATE @db_tbl SET ProcFlag = 1 WHERE DatabaseName = @db;
  /*
  IF @end < GETDATE()
  BEGIN
   SET @msg = 'Procedure has exceeded max run time based on @maxDurationHrs parameter and will exit at ' + CONVERT(VARCHAR, GETDATE()) + '.';
    RAISERROR(@msg, 0, 0) WITH NOWAIT;
     RETURN;
  END
  */
 --END TRY
 /*
 BEGIN CATCH
  SET @msg = 'Failed to execute command {' + @sql + '} against database {' + @db + '} with error number: ' + CAST(ERROR_NUMBER() AS VARCHAR) + 
     '; error message: ' + ERROR_MESSAGE() + '.  Procedure terminated at ' + CONVERT(VARCHAR, GETDATE()) + '.';
   RAISERROR(@msg, 16, 1) WITH LOG, NOWAIT;
    RETURN(-1);  
 END CATCH
*/
END

IF @vldbMode = 1
BEGIN
 IF OBJECT_ID('[dbo].[DBA_CustomDBCC_CheckTableStatus]', 'U') IS NULL
begin
        print 'The table DBA_CustomDBCC_CheckTableStatus is missing. Aborting.'
        return
    end
 ELSE
  DELETE FROM [dbo].[DBA_CustomDBCC_CheckTableStatus] WHERE [endDate] < GETDATE() - 367 AND ISNULL([procFlag], 1) = 1;

 -- Check for outstanding CHECKTABLE commands
 IF EXISTS ( SELECT * FROM [dbo].[DBA_CustomDBCC_CheckTableStatus] WHERE [procFlag] = 0 )
  SET @restart = 0;

 IF @restart = 1
  INSERT INTO [dbo].[DBA_CustomDBCC_CheckTableStatus] ([databaseName], [schemaName], [tableName], [procFlag])
  SELECT DatabaseName, SchemaName, TableName, 0
  FROM @check_tbl c
  WHERE NOT EXISTS ( SELECT *
       FROM dbo.DBA_CustomDBCC_CommaStringTable(@tblExcludeList) f
       WHERE LOWER(f.[Value]) = LOWER(c.tableName) )
  AND LOWER(c.tableName) = LOWER(ISNULL(@tableName, c.tableName));
 ELSE
 BEGIN
  SET @msg = 'Procedure has unfinished business in VLDB mode.';
   RAISERROR(@msg, 0, 0) WITH NOWAIT;
 END

 -- Exclude tables
 IF (@tblExcludeList IS NOT NULL AND LTRIM(RTRIM(@tblExcludeList)) <> '')
 BEGIN
  IF OBJECT_ID('dbo.DBA_CustomDBCC_CommaStringTable') IS NULL
  BEGIN
   SELECT @msg = 'The function required by skip-table code does not exist. All tables will be checked.', @tblExcludeList = NULL;
    RAISERROR(@msg, 0, 0) WITH NOWAIT;
  END
  ELSE
  BEGIN
   SET @msg = 'The following tables will be skipped for all databases: (' + REPLACE(@tblExcludeList, ' ', '') + ').';
    RAISERROR(@msg, 0, 0) WITH NOWAIT;

   UPDATE cts
   SET cts.[procFlag] = NULL
   FROM [dbo].[DBA_CustomDBCC_CheckTableStatus] cts
    INNER JOIN dbo.DBA_CustomDBCC_CommaStringTable(@tblExcludeList) cst ON LOWER(cts.tableName) = LOWER(cst.[Value])
   WHERE ISNULL(cts.[procFlag], 0) = 0;
  END
 END

SELECT @end = CASE @maxDurationHrs WHEN 0 THEN '9999-12-31 23:59:59:997' ELSE DATEADD(second, @maxDurationHrs * 60 * 60, GETDATE()) END

declare @dteStartTime datetime = current_timestamp

 WHILE EXISTS ( SELECT c.*
     FROM [dbo].[DBA_CustomDBCC_CheckTableStatus] c
      INNER JOIN @db_tbl t ON c.databaseName = t.DatabaseName
     WHERE c.procFlag = 0
     AND LOWER(c.tableName) = LOWER(ISNULL(@tableName, c.tableName))

     and @end > GETDATE() -- exit if we've exceeded our max time
     )
 BEGIN  
  SELECT TOP 1 @tbl = '[' + c.databaseName + '].[' + c.schemaName + '].[' + c.tableName + ']', 
      @sql = 'SET QUOTED_IDENTIFIER OFF SET ARITHABORT ON DBCC CHECKTABLE (' + CHAR(39) + @tbl + CHAR(39) + 
      CASE @checkNdx WHEN 0 THEN ', NOINDEX' ELSE '' END + ') WITH ALL_ERRORMSGS, NO_INFOMSGS' + 
      CASE @physOnly WHEN 1 THEN ', PHYSICAL_ONLY' ELSE '' END, @tblid = c.checkTableID
  FROM [dbo].[DBA_CustomDBCC_CheckTableStatus] c
   INNER JOIN @db_tbl t ON c.databaseName = t.DatabaseName
  WHERE c.procFlag = 0
  AND LOWER(c.tableName) NOT IN ( SELECT LOWER([Value]) FROM dbo.DBA_CustomDBCC_CommaStringTable(@tblExcludeList) )
  AND LOWER(c.tableName) = LOWER(ISNULL(@tableName, c.tableName))
  ORDER BY c.databaseName, c.schemaName, c.tableName;

  -- Execute table-level DBCC commands
--  BEGIN TRY
   --RAISERROR(@sql, 0, 0) WITH NOWAIT;
         
   IF @debugMode = 0
   BEGIN
    UPDATE [dbo].[DBA_CustomDBCC_CheckTableStatus] SET
    command = @sql
    ,startDate = GETDATE()
    WHERE checkTableID = @tblid;
    
    BEGIN TRY
      --EXECUTE @sp_executesql @stmt = @Command
      EXEC sp_ExecuteSQL @stmt = @sql;
    END TRY
    BEGIN CATCH
      SET @Error = ERROR_NUMBER()
      SET @ErrorMessageOriginal = ERROR_MESSAGE()

      SET @ErrorMessage = 'Msg ' + CAST(ERROR_NUMBER() AS nvarchar) + ', ' + ISNULL(ERROR_MESSAGE(),'')
      --SET @Severity = CASE WHEN ERROR_NUMBER() IN(1205,1222) THEN @LockMessageSeverity ELSE 16 END
      --RAISERROR('%s' ,@Severity, 1, @ErrorMessage) WITH NOWAIT

    END CATCH

    UPDATE [dbo].[DBA_CustomDBCC_CheckTableStatus] SET
        procFlag = CASE ISNULL(OBJECT_ID(@tbl), 0) WHEN 0 THEN NULL
            ELSE 1 END
        ,endDate = GETDATE()
        ,[error_number] = @Error
        ,[error_message] = @ErrorMessageOriginal
        WHERE checkTableID = @tblid;
   END
   ELSE
    UPDATE [dbo].[DBA_CustomDBCC_CheckTableStatus] SET procFlag = NULL WHERE checkTableID = @tblid;
/*
   IF @end < GETDATE()
   BEGIN
    SET @msg = 'Procedure has exceeded max run time based on @maxDurationHrs parameter and will exit at ' + CONVERT(VARCHAR, GETDATE()) + '.';
     RAISERROR(@msg, 0, 0) WITH NOWAIT;
      --RETURN;
   END
*/
/*
  END TRY
  
  BEGIN CATCH
   SET @msg = 'Failed to execute command {' + @sql + '} with error number: ' + CAST(ERROR_NUMBER() AS VARCHAR) + '; error message: ' + 
      ERROR_MESSAGE() + '.  Procedure terminated at ' + CONVERT(VARCHAR, GETDATE()) + '.';
    RAISERROR(@msg, 16, 2) WITH LOG, NOWAIT;
     RETURN(-2);  
  END CATCH
*/
 END
END

--update DBA_CustomDBCC_CheckTableStatus set elapsed_sec = null, elapsed_desc = null

update dbo.DBA_CustomDBCC_CheckTableStatus SET
elapsed_sec = datediff(second, startDate, endDate)
--where elapsed_sec is null

update dbo.DBA_CustomDBCC_CheckTableStatus SET
elapsed_desc = 
    case
        when (elapsed_sec + 30 *@min) > 14 *@day
            then '> 14 days'
        when (elapsed_sec + 30 *@min) >= 2 *@day then -- >= 2: show days (plural) + hr
            cast(floor((elapsed_sec + 30 *@min) / @day) as varchar(2)) + ' days ' 
            + cast(floor((elapsed_sec + 30 *@min) / @hr) % 24 as varchar(2)) + ' hr'
        when (elapsed_sec + 30 *@min) >= 1 *@day then -- >= 1: show day (singular) + hr
            cast(floor((elapsed_sec + 30 *@min) / @day) as varchar(2)) + ' day ' 
            + cast(floor((elapsed_sec + 30 *@min) / @hr) % 24 as varchar(2)) + ' hr'
        when (elapsed_sec + 30 *@sec) >= 1 *@hr then -- >=1 hr, show hr + min
            cast(floor((elapsed_sec + 30 *@sec) / @hr) as varchar(2)) + ' hr ' 
            + cast(floor((elapsed_sec + 30 *@sec) / @min) % 60 as varchar(2)) + ' min'
        when (elapsed_sec) >= 15 *@min then -- >= 15 min, show min only
            cast(floor((elapsed_sec) / @min) as varchar(2)) + ' min'
        when (elapsed_sec + 0.5 *@sec) >= 1 *@min then -- >= 1 min, show min + sec
            cast(floor((elapsed_sec + 0.5 *@sec) / @min) % 60 as varchar(2)) + ' min ' 
            + cast(floor((elapsed_sec + 0.5 *@sec) / @sec) % 60 as varchar(2)) + ' sec'
        when (elapsed_sec + 0.5 *@sec) >= 1 *@sec then -- >= 1 sec, show sec only
            cast(floor((elapsed_sec + 0.5 *@sec) / @sec) % 60 as varchar(2)) + ' sec'
        else '0 sec'
    end
--where elapsed_sec is not null and elapsed_desc is null

IF @debugMode = 1
 UPDATE dbo.DBA_CustomDBCC_CheckTableStatus SET procFlag = 0, startDate = NULL, endDate = NULL WHERE procFlag IS NULL;

SET @msg = CHAR(10) + CHAR(13) + 'DBCC job on ' + @@SERVERNAME + ' ended at ' + CONVERT(VARCHAR, GETDATE()) + '.';
 RAISERROR(@msg, 0, 0) WITH NOWAIT;

-- show error codes
IF exists(select * from dbo.DBA_CustomDBCC_CheckTableStatus where startDate >= @dteStartTime and [error_number] <> 0)
BEGIN
	--print 'got here.1'
	DECLARE ErrorCursor CURSOR FAST_FORWARD FOR
		SELECT [error_number], [error_message]
		FROM dbo.DBA_CustomDBCC_CheckTableStatus where startDate >= @dteStartTime
			and [error_number] <> 0
		ORDER BY startDate

	OPEN ErrorCursor

	FETCH ErrorCursor INTO @Error, @ErrorMessage

	WHILE @@FETCH_STATUS = 0
	BEGIN
		RAISERROR('%s', 16, 1, @ErrorMessage) WITH NOWAIT
		--RAISERROR('%s', 10, 1, @ErrorMessage) WITH NOWAIT
		--RAISERROR(@EmptyLine, 10, 1) WITH NOWAIT

		FETCH NEXT FROM ErrorCursor INTO @Error, @ErrorMessage
	END

	CLOSE ErrorCursor

	DEALLOCATE ErrorCursor
	
	-- return error code
	RETURN 50000
end


GO




/*
EXEC DBAdmin.dbo.DBA_CustomDBCC
@maxDurationHrs = 0.0028 -- hours; 0.0028 = 10 sec; 0 = run until completion
,@debugMode = 0 -- 0 = execute, 1 = print only, do not execute
,@vldbMode = 1 -- 1 = execute dbcc checktable
;

select top 100 * from DBAdmin.dbo.DBA_CustomDBCC_CheckTableStatus
order by startDate desc

*/

