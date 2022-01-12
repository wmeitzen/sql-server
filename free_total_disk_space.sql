
SELECT distinct(volume_mount_point), 
  cast(total_bytes/power(2.0, 20) as numeric(32, 1)) as Size_in_MB, 
  cast(available_bytes/power(2.0, 20) as numeric(32, 1)) as Free_in_MB,
  cast(total_bytes/power(2.0, 30) as numeric(32, 1)) as Size_in_GB, 
  cast(available_bytes/power(2.0, 30) as numeric(32, 1)) as Free_in_GB,
  --(select ((available_bytes/1048576* 1.0)/(total_bytes/1048576* 1.0) *100)) as FreePercentage
  cast(available_bytes*1.0 / total_bytes * 100 as numeric(32, 1)) as FreePercentage
FROM sys.master_files AS f CROSS APPLY 
  sys.dm_os_volume_stats(f.database_id, f.file_id)
group by volume_mount_point
--, total_bytes/1048576
,total_bytes
--, available_bytes/1048576
,available_bytes
order by 1
