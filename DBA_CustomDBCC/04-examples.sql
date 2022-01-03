
EXEC DBAdmin.dbo.DBA_CustomDBCC
@maxDuration = 0.0028 -- hours; 0.0028 = 10 sec; 0 = run until completion
,@debugMode = 0 -- 0 = execute, 1 = print only, do not execute
,@vldbMode = 1 -- 1 = execute dbcc checktable
;

-- attribution: https://www.mssqltips.com/sqlservertip/3485/sql-server-dbcc-checkdb-checkcatalog-and-checkalloc-for-vldbs/
-- run integrity check, and if incomplete, resume where it left off
EXEC DBAdmin.dbo.DBA_CustomDBCC
@maxDuration = 1 -- hours; 0 = run until completion
,@debugMode = 0 -- 0 = execute, 1 = print only, do not execute
,@vldbMode = 1 -- 1 = execute dbcc checktable
;

--select top 100 * from DBAdmin.dbo.CheckTableStatus

EXEC DBAdmin.[dbo].[DBA_CustomDBCC] 
            @checkAlloc = 0
          , @checkCat = 0
          , @checkDB = 0
          , @checkNdx = 0
          , @dbName = 'dbName'
          , @dbExcludeList = 'ExcludeDB1, ExcludeDB2, ExcludeDBN'
          , @debugMode = 0
          , @maxDurationHrs = 2
          , @physOnly = 0
          , @tableName = 'tableName'
          , @tblExcludeList = 'ExcludeTable1,ExcludeTable2, ExcludeTableN'
          , @vldbMode = vldbMode;
