
set nocount on
go

declare @intTotalPhysicalMemoryMB bigint
declare @int85PercentTotalPhysicalMemoryMB bigint
declare @intMaxServerMemorySettingMB bigint

SELECT @intTotalPhysicalMemoryMB = [total_physical_memory_kb] / 1024 FROM [master].[sys].[dm_os_sys_memory]
SELECT @int85PercentTotalPhysicalMemoryMB = ([total_physical_memory_kb] / 1024) * 0.85 FROM [master].[sys].[dm_os_sys_memory]
SELECT @intMaxServerMemorySettingMB = cast(value_in_use as bigint) FROM sys.configurations where name = 'max server memory (MB)'

print 'Server name: ' + @@servername
print 'Total physical memory = ' + cast(@intTotalPhysicalMemoryMB as varchar(15)) + ' MB'
print '85% of total physical memory = ' + cast(@int85PercentTotalPhysicalMemoryMB as varchar(15)) + ' MB'
print 'Max Server Memory setting = ' + cast(@intMaxServerMemorySettingMB as varchar(15)) + ' MB'

if @intMaxServerMemorySettingMB between @int85PercentTotalPhysicalMemoryMB * 0.95 and @int85PercentTotalPhysicalMemoryMB * 1.05
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
	print 'EXEC sys.sp_configure N''max server memory (MB)'', N''' + cast(@int85PercentTotalPhysicalMemoryMB as varchar(15)) + ''' -- set to 85% of ' + cast(@intTotalPhysicalMemoryMB as varchar(15)) + ' MB, ' + cast(@int85PercentTotalPhysicalMemoryMB as varchar(15)) + ' MB'
	print 'go'
	print 'RECONFIGURE WITH OVERRIDE'
	print 'go'
end
