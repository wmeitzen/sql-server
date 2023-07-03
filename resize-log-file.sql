
/*
Given the database name and ratio of log file to data file (.ldf to .mdf),
show whether the log file needs to be resized,
and generate commands to resize the log file and growth characteristics.

This script outputs TSQL commands, but does not execute the commands.
I highly recommend running each TSQL command individually.

Set query results to text
Set Query / Query options / Results / Text / Max # of chars to 8000
Set @strDatabaseName to the database name
Set @fltLogFilePercentageOfDataFile to the ratio of log file to data file (.ldf to .mdf)
Run the script.
*/

declare @strDatabaseName sysname = 'msdb' -- set database name
declare @fltLogFilePercentageOfDataFile float = 0.25 -- set log file ratio - 0.2 = 20%, 0.25 = 25%, etc.

set nocount on

declare @strLogFileLogicalName nvarchar(120)
declare @intLogFileSizeDestinationMB bigint
declare @intAlterDatabaseSizeMB bigint
declare @strAlterDatabaseSizeMB varchar(12)
declare @strAlterDatabaseCommands nvarchar(max)

declare @strRecoveryModelDesc varchar(10)
select @strRecoveryModelDesc = recovery_model_desc
from sys.databases where name = @strDatabaseName

declare @strLogFilePercentageOfDataFile varchar(2) = cast(@fltLogFilePercentageOfDataFile * 100 as varchar(2))

if @strRecoveryModelDesc is null
	select 'Database ' + @strDatabaseName + ' does not exist!' as [--Error]

declare @strComment nvarchar(max) = ''

set @strComment = @strComment + '-- #. Verify high VLF count, missized log growth, or missized log file' + char(13) + char(10)
set @strComment = @strComment + '-- #. Disable scheduled full, diff, and xlog backups' + char(13) + char(10)
set @strComment = @strComment + '-- #. Disable scheduled index rebuilds and other SQL agent jobs that will conflict with the resize process' + char(13) + char(10)
set @strComment = @strComment + '-- #. Perform full backup' + char(13) + char(10)
set @strComment = @strComment + '-- #. Perform xlog backup' + char(13) + char(10)
set @strComment = @strComment + '-- #. Enable scheduled full, diff, and xlog backups' + char(13) + char(10)
set @strComment = @strComment + '-- #. Enable scheduled index rebuilds and other SQL agent jobs that you disabled earlier' + char(13) + char(10)

select @strComment as [--Steps]

declare @intCurrentVLFCount as bigint

/*
-- does not work w/SQL 2012
SELECT @intCurrentVLFCount = COUNT(l.database_id)
FROM sys.databases s
CROSS APPLY sys.dm_db_log_info(s.database_id) l
where s.name = @strDatabaseName
GROUP BY s.[name], s.database_id
*/

CREATE TABLE #stage(
 [recovery_unit_id] INT
 ,[file_id] INT
 ,[file_size] BIGINT
 ,[start_offset] BIGINT
 ,[f_seq_no] BIGINT
 ,[status] BIGINT
 ,[parity] BIGINT
 ,[create_lsn] NUMERIC(38)
);
INSERT INTO #stage EXECUTE (N'DBCC LogInfo WITH no_infomsgs');
SELECT @intCurrentVLFCount = COUNT(1) FROM #stage;
DROP TABLE #stage;

declare @intCurrentGrowthMB as bigint
select @intCurrentGrowthMB = cast(growth as bigint) * 8192 / power(2, 20)
from sys.master_files
where db_name(database_id) = @strDatabaseName

declare @intMDFSizeInMB bigint
select @intMDFSizeInMB = size/128.0 -- size in mb
from sys.master_files
where db_name(database_id) = @strDatabaseName
and type_desc = 'ROWS'

declare @intRecommendedMaxLogSize bigint = @intMDFSizeInMB * @fltLogFilePercentageOfDataFile

declare @intLogSizeInMB bigint
select @intLogSizeInMB = size/128.0 -- size in mb
from sys.master_files
where db_name(database_id) = @strDatabaseName
and type_desc = 'LOG'

declare @intCurrentLogFilePercentageOfDataFile bigint
set @intCurrentLogFilePercentageOfDataFile = ((0.0+@intLogSizeInMB) / @intMDFSizeInMB) * 100
declare @strCurrentLogFilePercentageOfDataFile varchar(6) = cast(@intCurrentLogFilePercentageOfDataFile as varchar(6))

declare @intAutogrowthIncrementsMB bigint
if @intMDFSizeInMB <= 256
	set @intAutogrowthIncrementsMB = 128
else if @intMDFSizeInMB <= 1024
	set @intAutogrowthIncrementsMB = 512
else if @intMDFSizeInMB <= 10000 -- 10G
	set @intAutogrowthIncrementsMB = 1024
else if @intMDFSizeInMB <= 1000000 -- 1T
	set @intAutogrowthIncrementsMB = 4096
else
	set @intAutogrowthIncrementsMB = 8192

select '/*', @intMDFSizeInMB as [--Database Size In MB]
, @intLogSizeInMB as [--Current Log File Size MB]
, @strCurrentLogFilePercentageOfDataFile as [--Current Log Size %]
, @strLogFilePercentageOfDataFile as [--Recommended Log Size %]
, @intRecommendedMaxLogSize as [--Recommended Log Size MB]
, @intAutogrowthIncrementsMB as [--Recommended Autogrowth Increment MB]
, @intCurrentGrowthMB as [--Current Log File Growth MB]
, @intCurrentVLFCount as [--Current VLF Count]
, @strRecoveryModelDesc as [--Recovery Model]
, '*/'

declare @strRunResizeLDFProcess varchar(3) = 'No' -- assume we don't need to resize
if (@intLogSizeInMB > @intRecommendedMaxLogSize * 1.25
	or @intLogSizeInMB < @intRecommendedMaxLogSize * 0.75
	or @intCurrentVLFCount > 500
	or @intAutogrowthIncrementsMB < 0.9 * @intCurrentGrowthMB
	or @intAutogrowthIncrementsMB > 1.1 * @intCurrentGrowthMB
	)
begin
	set @strRunResizeLDFProcess = 'YES'
end

select '/* Time to resize log file?', @strRunResizeLDFProcess as [--Yes or No], '*/'

/*
if @strRecoveryModelDesc <> 'SIMPLE'
	select 'use [master]
go
alter database [' + @strDatabaseName + '] set recovery simple with no_wait
go' as [--Set database to simple recovery]
*/

if (select count(*) from sys.master_files where db_name(database_id) = @strDatabaseName and type_desc = 'LOG') > 1
begin
	select 'Note: more than 1 log file exists' as [--Note: > 1 log file]
end

-- handle the rare case of multiple log filenames
while @strLogFileLogicalName is null or exists(select name from sys.master_files where db_name(database_id) = @strDatabaseName and type_desc = 'LOG' and name > @strLogFileLogicalName)
begin
	if @strLogFileLogicalName is not null
		select top 1 @strLogFileLogicalName = name
		from sys.master_files
		where db_name(database_id) = @strDatabaseName
		and type_desc = 'LOG'
		and name > @strLogFileLogicalName
		order by name

	if @strLogFileLogicalName is null
		select top 1 @strLogFileLogicalName = name
		from sys.master_files
		where db_name(database_id) = @strDatabaseName
		and type_desc = 'LOG'
		order by name


select 'use [' + @strDatabaseName + ']
go
dbcc shrinkfile(''' + @strLogFileLogicalName + ''', 0)
go' as [--Shrink log file]

select 'use [master]
go
alter database [' + @strDatabaseName + '] modify file ( name = ''' + @strLogFileLogicalName + ''', filegrowth = ' + cast(@intAutogrowthIncrementsMB as varchar(12)) + 'MB )
go' as [--Set log file growth based on data file size]

set @intLogFileSizeDestinationMB = @fltLogFilePercentageOfDataFile * @intMDFSizeInMB
set @intAlterDatabaseSizeMB = 0
set @strAlterDatabaseCommands = ''

while @intAlterDatabaseSizeMB < @intLogFileSizeDestinationMB
begin
	set @intAlterDatabaseSizeMB = @intAlterDatabaseSizeMB + @intAutogrowthIncrementsMB
	set @strAlterDatabaseSizeMB = cast(@intAlterDatabaseSizeMB as varchar(12))
	set @strAlterDatabaseCommands = @strAlterDatabaseCommands + 'alter database [' + @strDatabaseName + '] modify file (name = ''' + @strLogFileLogicalName + ''', size = ' + @strAlterDatabaseSizeMB + 'MB); '
	set @strAlterDatabaseCommands = @strAlterDatabaseCommands + '-- ' + format((0.0 + @intAlterDatabaseSizeMB) / @intMDFSizeInMB * 100, 'N1') + '% of data file size'
	set @strAlterDatabaseCommands = @strAlterDatabaseCommands + char(13) + char(10) + 'go' + char(13) + char(10)
	if len(@strAlterDatabaseCommands) > 4000
	begin
		select @strAlterDatabaseCommands as [--AlterDatabaseCommands]
		set @strAlterDatabaseCommands = ''
	end
end
if len(@strAlterDatabaseCommands) > 0
	select @strAlterDatabaseCommands as [--AlterDatabaseCommands]

/*
if @strRecoveryModelDesc <> 'SIMPLE'
	select 'use [master]
go
alter database [' + @strDatabaseName + '] set recovery full
go' as [--Set database back to full recovery]
*/
end -- while

set @strComment = ''
set @strComment = @strComment + '-- #. Perform full backup (very important)' + char(13) + char(10)
set @strComment = @strComment + '-- #. Perform xlog backup' + char(13) + char(10)
set @strComment = @strComment + '-- #. Enable scheduled full, diff, and xlog backups' + char(13) + char(10)
set @strComment = @strComment + '-- #. Enable scheduled index rebuilds and other SQL agent jobs that you disabled earlier' + char(13) + char(10)

select @strComment as [--After running the commands above]
