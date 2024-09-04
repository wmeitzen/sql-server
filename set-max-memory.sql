set nocount on
go

declare @intLeaveMBForOSMin bigint = 4 *1024
declare @intLeaveMBForOSMax bigint = 8 *1024
declare @intTotalPhysicalMemoryMB bigint
declare @intPercentage int = 85
declare @intPercentTotalPhysicalMemoryMB bigint
declare @intMaxServerMemorySettingMB bigint
declare @intRecommendedOSMemoryMB bigint

SELECT @intTotalPhysicalMemoryMB = [total_physical_memory_kb] / 1024 FROM [master].[sys].[dm_os_sys_memory]
SELECT @intPercentTotalPhysicalMemoryMB = ([total_physical_memory_kb] / 1024) * (@intPercentage / 100.0) FROM [master].[sys].[dm_os_sys_memory]
SELECT @intMaxServerMemorySettingMB = cast(value_in_use as bigint) FROM sys.configurations where name = 'max server memory (MB)'
set @intRecommendedOSMemoryMB = @intTotalPhysicalMemoryMB - @intPercentTotalPhysicalMemoryMB

print 'Server name: ' + @@servername
print 'Current Max Server Memory setting = ' + cast(@intMaxServerMemorySettingMB as varchar(15)) + ' MB'
print 'Total physical memory = ' + cast(@intTotalPhysicalMemoryMB as varchar(15)) + ' MB'
print cast(@intPercentage as varchar(2)) + '% of total physical memory = ' + cast(@intPercentTotalPhysicalMemoryMB as varchar(15)) + ' MB'
print 'Recommended Max Server Memory setting = ' + cast(@intPercentTotalPhysicalMemoryMB as varchar(15)) + ' MB'
print 'Remaining memory for OS (recommended) = ' + cast(@intRecommendedOSMemoryMB as varchar(6)) + ' MB'

if @intRecommendedOSMemoryMB < @intLeaveMBForOSMin
begin
	set @intRecommendedOSMemoryMB = @intLeaveMBForOSMin
	set @intPercentTotalPhysicalMemoryMB = @intTotalPhysicalMemoryMB - @intRecommendedOSMemoryMB
	print 'Remaining memory for OS is too low (less than ' + cast(@intLeaveMBForOSMin as varchar(6)) + ' MB)'
	print 'Corrected:'
	print 'Recommended Max Server Memory setting = ' + cast(@intPercentTotalPhysicalMemoryMB as varchar(15)) + ' MB'
	print 'Remaining memory for OS = ' + cast(@intRecommendedOSMemoryMB as varchar(6)) + ' MB'
end

if @intRecommendedOSMemoryMB > @intLeaveMBForOSMax
begin
	set @intRecommendedOSMemoryMB = @intLeaveMBForOSMax
	set @intPercentTotalPhysicalMemoryMB = @intTotalPhysicalMemoryMB - @intRecommendedOSMemoryMB
	print 'Remaining memory for OS is excessive (more than ' + cast(@intLeaveMBForOSMax as varchar(6)) + ' MB)'
	print 'Corrected:'
	print 'Recommended Max Server Memory setting = ' + cast(@intPercentTotalPhysicalMemoryMB as varchar(15)) + ' MB'
	print 'Remaining memory for OS = ' + cast(@intRecommendedOSMemoryMB as varchar(6)) + ' MB'
end

if @intMaxServerMemorySettingMB between @intPercentTotalPhysicalMemoryMB * 0.95 and @intPercentTotalPhysicalMemoryMB * 1.05
begin
	print 'Memory setting is ok'
end
else
begin
	print 'Memory setting is not ok. Commands:'
	print ''
	print 'EXEC sys.sp_configure N''show advanced options'', N''1'''
	print 'go'
	print 'RECONFIGURE WITH OVERRIDE'
	print 'go'
	print 'EXEC sys.sp_configure N''max server memory (MB)'', N''' + cast(@intPercentTotalPhysicalMemoryMB as varchar(15)) + ''' -- RAM is ' + cast(@intTotalPhysicalMemoryMB as varchar(15)) + ' MB'
	print 'go'
	print 'RECONFIGURE WITH OVERRIDE'
	print 'go'
end
