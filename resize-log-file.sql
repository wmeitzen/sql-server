

/*
Given the database name and ratio of log file to data file (.ldf to .mdf),
show whether the log file needs to be resized,
and generate commands to resize the log file and growth characteristics.

This script outputs TSQL commands, but does not execute the commands.
I highly recommend running each TSQL command individually.

Set query results to text
Set Query / Query options / Results / Test / Max # of chars to 8000
Set @strDatabaseName to the database name
Set @fltLogFilePercentageOfDataFile to the ratio of log file to data file (.ldf to .mdf)
Run the script.
*/

declare @strDatabaseName sysname = 'msdb' -- set database name
declare @fltLogFilePercentageOfDataFile float = 0.2 -- set log file ratio - 0.2 = 20%, 0.25 = 25%, etc.

set nocount on

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
SELECT @intCurrentVLFCount = COUNT(l.database_id)
FROM sys.databases s
CROSS APPLY sys.dm_db_log_info(s.database_id) l
where s.name = @strDatabaseName
GROUP BY s.[name], s.database_id

declare @intCurrentGrowthMB as bigint
select @intCurrentGrowthMB = cast(growth as bigint) * 8192 / power(2, 20)
from sys.master_files
where db_name(database_id) = @strDatabaseName

declare @strLogFileLogicalName nvarchar(120)
select @strLogFileLogicalName = name
from sys.master_files
where db_name(database_id) = @strDatabaseName
and type_desc = 'LOG'

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

declare @intCurrentLogFilePercentageOfDataFile int
set @intCurrentLogFilePercentageOfDataFile = ((0.0+@intLogSizeInMB) / @intMDFSizeInMB) * 100
declare @strCurrentLogFilePercentageOfDataFile varchar(3) = cast(@intCurrentLogFilePercentageOfDataFile as varchar(3))

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

select 'use [' + @strDatabaseName + ']
go
dbcc shrinkfile(''' + @strLogFileLogicalName + ''', 0)
go' as [--Shrink log file]

select 'use [master]
go
alter database [' + @strDatabaseName + '] modify file ( name = ''' + @strLogFileLogicalName + ''', filegrowth = ' + cast(@intAutogrowthIncrementsMB as varchar(12)) + 'MB )
go' as [--Set log file growth based on data file size]

-- set log file to 20% of data file size
-- do so with a series of resize commands
declare @intLogFileSizeDestinationMB bigint = @fltLogFilePercentageOfDataFile * @intMDFSizeInMB
declare @intAlterDatabaseSizeMB bigint = 0
declare @strAlterDatabaseSizeMB varchar(12)
declare @strAlterDatabaseCommands nvarchar(max) = ''
while @intAlterDatabaseSizeMB < @intLogFileSizeDestinationMB
begin
	set @intAlterDatabaseSizeMB = @intAlterDatabaseSizeMB + @intAutogrowthIncrementsMB
	set @strAlterDatabaseSizeMB = cast(@intAlterDatabaseSizeMB as varchar(12))
	set @strAlterDatabaseCommands = @strAlterDatabaseCommands + 'alter database [' + @strDatabaseName + '] modify file (name = ''' + @strLogFileLogicalName + ''', size = ' + @strAlterDatabaseSizeMB + 'MB); '
	set @strAlterDatabaseCommands = @strAlterDatabaseCommands + '-- ' + format((0.0 + @intAlterDatabaseSizeMB) / @intMDFSizeInMB * 100, 'N1') + '% of data file size'
	set @strAlterDatabaseCommands = @strAlterDatabaseCommands + char(13) + char(10) + 'go' + char(13) + char(10)
end
select @strAlterDatabaseCommands as [--AlterDatabaseCommands]

/*
if @strRecoveryModelDesc <> 'SIMPLE'
	select 'use [master]
go
alter database [' + @strDatabaseName + '] set recovery full
go' as [--Set database back to full recovery]
*/

set @strComment = ''
set @strComment = @strComment + '-- #. Perform full backup (very important)' + char(13) + char(10)
set @strComment = @strComment + '-- #. Perform xlog backup' + char(13) + char(10)
set @strComment = @strComment + '-- #. Enable scheduled full, diff, and xlog backups' + char(13) + char(10)
set @strComment = @strComment + '-- #. Enable scheduled index rebuilds and other SQL agent jobs that you disabled earlier' + char(13) + char(10)

select @strComment as [--After running the commands above]
