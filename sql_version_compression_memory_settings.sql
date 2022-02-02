
SELECT 
CASE 
     WHEN CONVERT(VARCHAR(128), SERVERPROPERTY ('productversion')) like '8%' THEN 'SQL 2000'
     WHEN CONVERT(VARCHAR(128), SERVERPROPERTY ('productversion')) like '9%' THEN 'SQL 2005'
     WHEN CONVERT(VARCHAR(128), SERVERPROPERTY ('productversion')) like '10.0%' THEN 'SQL 2008'
     WHEN CONVERT(VARCHAR(128), SERVERPROPERTY ('productversion')) like '10.5%' THEN 'SQL 2008 R2'
     WHEN CONVERT(VARCHAR(128), SERVERPROPERTY ('productversion')) like '11%' THEN 'SQL 2012'
     WHEN CONVERT(VARCHAR(128), SERVERPROPERTY ('productversion')) like '12%' THEN 'SQL 2014'
     WHEN CONVERT(VARCHAR(128), SERVERPROPERTY ('productversion')) like '13%' THEN 'SQL 2016'     
     WHEN CONVERT(VARCHAR(128), SERVERPROPERTY ('productversion')) like '14%' THEN 'SQL 2017' 
     WHEN CONVERT(VARCHAR(128), SERVERPROPERTY ('productversion')) like '15%' THEN 'SQL 2019' 
     ELSE 'unknown'
  END AS MajorVersion,
  SERVERPROPERTY('ProductLevel') AS ProductLevel,
  SERVERPROPERTY('Edition') AS Edition,
  SERVERPROPERTY('ProductVersion') AS ProductVersion
,case
	when @@version like '%2022%' then 1
	when @@version like '%2019%' then 1
	when @@version like '%2017%' then 1
	when @@version like '%2016%' and (@@version like '%(sp2)%' or @@version like '%(sp3)%') then 1
	when @@version like '%enterprise%' then 1
	else 0
end as backup_compression_available
,(select cast(value_in_use as bigint) FROM sys.configurations where name = 'backup compression default') as backup_compression_setting
,case
	when case
			when @@version like '%2022%' then 1
			when @@version like '%2019%' then 1
			when @@version like '%2017%' then 1
			when @@version like '%2016%' and (@@version like '%(sp2)%' or @@version like '%(sp3)%') then 1
			when @@version like '%enterprise%' then 1
			else 0
		end = 1 
		and (select cast(value_in_use as bigint) FROM sys.configurations where name = 'backup compression default') = 0 then 'enable default backup compression'
	else 'no change'
end as enable_default_backup_compression
,(select cast(value_in_use as bigint) FROM sys.configurations where name = 'max server memory (MB)') as max_server_memory_mb_setting
,(select [total_physical_memory_kb] / 1024 FROM [master].[sys].[dm_os_sys_memory]) as [server_physical_memory_mb]
,cast((select cast(value_in_use as bigint) FROM sys.configurations where name = 'max server memory (MB)')
	/ (select [total_physical_memory_kb] / 1024.0 FROM [master].[sys].[dm_os_sys_memory]) * 100 as numeric(32, 1))
	as ratio_max_mem_to_server_ram
,case
	when (select cast(value_in_use as bigint) FROM sys.configurations where name = 'max server memory (MB)')
	/ (select [total_physical_memory_kb] / 1024.0 FROM [master].[sys].[dm_os_sys_memory]) * 100 between 85 and 95 then 'no change'
	else 'Adjust max_memory'
end as max_server_memory_setting_needs_adjustment
--order by 2 desc


