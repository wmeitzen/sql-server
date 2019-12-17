
select top 1
S.session_id
,R.command
,case
	when lower(R.command) like 'restore%' then 'Restoring'
	when lower(R.command) like 'backup%' then 'Backing Up'
	else 'Unknown'
end as [backingup_or_restoring]
,case
	when R.percent_complete>0 and R.percent_complete<100 then
		case
			when lower(R.command) like 'restore%' then 'Restoring'
			when lower(R.command) like 'backup%' then 'Backing Up'
			else 'Unknown'
		end
	when R.percent_complete=100 then 'Running upgrade steps'
	else 'Zeroing destination files'
end as [state]
,R.percent_complete
--,getdate() as [current_time]
,case
	when R.percent_complete>0 then cast(cast(dateadd(millisecond, R.estimated_completion_time, getdate()) as date) as varchar(12))
	+' '+right('0'+cast(datepart(hour, dateadd(millisecond, R.estimated_completion_time, getdate())) as varchar(2)), 2)
	+':'+right('0'+cast(datepart(minute, dateadd(millisecond, R.estimated_completion_time, getdate())) as varchar(2)), 2)
end
as completion_datetime_to_minute
,case when (R.estimated_completion_time / (1000*60*60)) % 24>0 then
cast((R.estimated_completion_time / (1000*60*60)) % 24 as varchar(10))+' hr ' else '' end
+case when (R.estimated_completion_time / (1000*60*60)) % 24>0 or R.estimated_completion_time / (1000*60) % 60>0 then
cast(R.estimated_completion_time / (1000*60) % 60 as varchar(2))+' min ' else '' end
+case when R.estimated_completion_time <= 10 *60*1000 then cast(R.estimated_completion_time / 1000 % 60 as varchar(2))+' sec' else ''
end as completion_time_flex
,case when (R.estimated_completion_time / (1000*60*60)) % 24>0 then
cast((R.estimated_completion_time / (1000*60*60)) % 24 as varchar(10))+' hr ' else '' end
+case when (R.estimated_completion_time / (1000*60*60)) % 24>0 or R.estimated_completion_time / (1000*60) % 60>0 then
cast(R.estimated_completion_time / (1000*60) % 60 as varchar(2))+' min ' else '' end
+cast(R.estimated_completion_time / 1000 % 60 as varchar(2))+' sec'
as completion_time_hms
,cast(R.percent_complete as integer) as percent_complete_int
,cast(R.percent_complete as numeric(20, 1)) as percent_complete_one_decimal_place
,S.[program_name]
,D.name as database_name
,BS.server_name
,BMF.physical_device_name as backup_filename
,BS.backup_size as backup_file_size_bytes
,T.[text] as sql_command
--,BS.*
from sys.dm_exec_sessions as S
inner join sys.dm_exec_requests as R on S.session_id=R.session_id
cross apply sys.dm_exec_sql_text(R.[sql_handle]) as T
inner join sys.databases as D on R.database_id=D.database_id
left outer join msdb.dbo.backupset as BS on D.name=BS.database_name
left outer join msdb.dbo.backupmediafamily as BMF on BS.media_set_id=BMF.media_set_id
where (lower(R.command) like '%restore %' or lower(R.command) like '%backup %')
--and lower(T.[text]) not like '%select%'
order by BS.backup_start_date desc
