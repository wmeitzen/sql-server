SELECT 
R.session_id
,R.command
,D.name as [database_name]
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
,T.[text] as sql_command
FROM sys.dm_exec_requests as R
inner join sys.databases as D on R.database_id=D.database_id
cross apply sys.dm_exec_sql_text(R.[sql_handle]) as T
WHERE R.percent_complete > 0
