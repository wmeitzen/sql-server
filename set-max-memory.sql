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
--set @intTotalPhysicalMemoryMB = 1000 -- for testing - delete later
SELECT @intPercentTotalPhysicalMemoryMB = @intTotalPhysicalMemoryMB * (@intPercentage / 100.0)
SELECT @intMaxServerMemorySettingMB = cast(value_in_use as bigint) FROM sys.configurations where name = 'max server memory (MB)'
--print '@intTotalPhysicalMemoryMB = ' + cast(@intTotalPhysicalMemoryMB as varchar(32))
--print '@intPercentTotalPhysicalMemoryMB = ' + cast(@intPercentTotalPhysicalMemoryMB as varchar(32))
set @intRecommendedOSMemoryMB = @intTotalPhysicalMemoryMB - @intPercentTotalPhysicalMemoryMB
--print '@intRecommendedOSMemoryMB = ' + cast(@intRecommendedOSMemoryMB as varchar(32))
--print '@intLeaveMBForOSMin = ' + cast(@intLeaveMBForOSMin as varchar(32))
--print '@intLeaveMBForOSMax = ' + cast(@intLeaveMBForOSMax as varchar(32))

print 'Server name: ' + @@servername
print 'Current Max Server Memory setting = ' + cast(@intMaxServerMemorySettingMB as varchar(15)) + ' MB'
print 'Total physical memory = ' + cast(@intTotalPhysicalMemoryMB as varchar(15)) + ' MB'
print cast(@intPercentage as varchar(2)) + '% of total physical memory = ' + cast(@intPercentTotalPhysicalMemoryMB as varchar(15)) + ' MB'
print 'Recommended Max Server Memory setting = ' + cast(@intPercentTotalPhysicalMemoryMB as varchar(15)) + ' MB'
print 'Remaining memory for OS (recommended) = ' + cast(@intRecommendedOSMemoryMB as varchar(6)) + ' MB'

if @intRecommendedOSMemoryMB < @intLeaveMBForOSMin and @intTotalPhysicalMemoryMB > @intLeaveMBForOSMin
begin
	set @intRecommendedOSMemoryMB = @intLeaveMBForOSMin
	set @intPercentTotalPhysicalMemoryMB = @intTotalPhysicalMemoryMB - @intRecommendedOSMemoryMB
--	print '(1)'
	print 'Remaining memory for OS is too low (less than ' + cast(@intLeaveMBForOSMin as varchar(6)) + ' MB)'
	print 'Adjusting:'
	print 'Adjusting Max Server Memory setting to = ' + cast(@intPercentTotalPhysicalMemoryMB as varchar(15)) + ' MB'
	print 'So remaining memory for OS = ' + cast(@intRecommendedOSMemoryMB as varchar(6)) + ' MB'
end

if @intRecommendedOSMemoryMB > @intLeaveMBForOSMax  -- 3600 > 
begin
	set @intRecommendedOSMemoryMB = @intLeaveMBForOSMax
	set @intPercentTotalPhysicalMemoryMB = @intTotalPhysicalMemoryMB - @intRecommendedOSMemoryMB
--	print '(2)'
	print 'Remaining memory for OS is excessive (more than ' + cast(@intLeaveMBForOSMax as varchar(6)) + ' MB)'
	print 'Adjusting:'
	print 'Adjusting Max Server Memory setting to = ' + cast(@intPercentTotalPhysicalMemoryMB as varchar(15)) + ' MB'
	print 'So remaining memory for OS = ' + cast(@intRecommendedOSMemoryMB as varchar(6)) + ' MB'
end

if @intMaxServerMemorySettingMB between @intPercentTotalPhysicalMemoryMB * 0.95 and @intPercentTotalPhysicalMemoryMB * 1.05
begin
	print 'Memory setting is ok'
end
else
begin
	print 'Memory setting is not ideal. Commands:'
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
