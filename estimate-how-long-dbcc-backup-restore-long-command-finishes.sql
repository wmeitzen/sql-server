SELECT
R.session_id
,R.command
,D.name as [database_name]
,T.[text] as sql_command
,case
	when R.percent_complete>0 then cast(cast(dateadd(millisecond, R.estimated_completion_time, getdate()) as date) as varchar(12))
	+' '+right('0'+cast(datepart(hour, dateadd(millisecond, R.estimated_completion_time, getdate())) as varchar(2)), 2)
	+':'+right('0'+cast(datepart(minute, dateadd(millisecond, R.estimated_completion_time, getdate())) as varchar(2)), 2)
end
as completion_datetime_to_minute
,case
when (R.estimated_completion_time + 30 *(60 *1000)) > 14 *(24 *60*60*1000)
	then '> 14 days'
when (R.estimated_completion_time + 30 *(60 *1000)) >= 2 *(24 *60*60*1000) then -- >= 2: show days (plural) + hr
	cast(floor((R.estimated_completion_time + 30 *(60 *1000)) / (24 *60*60*1000)) as varchar(2)) + ' days ' 
	+ cast(floor((R.estimated_completion_time + 30 *(60 *1000)) / (60 *60*1000)) % 24 as varchar(2)) + ' hr'
when (R.estimated_completion_time + 30 *(60 *1000)) >= 1 *(24 *60*60*1000) then -- >= 1: show day (singular) + hr
	cast(floor((R.estimated_completion_time + 30 *(60 *1000)) / (24 *60*60*1000)) as varchar(2)) + ' day ' 
	+ cast(floor((R.estimated_completion_time + 30 *(60 *1000)) / (60 *60*1000)) % 24 as varchar(2)) + ' hr'
when (R.estimated_completion_time + 30 *1000) >= 1 *(60 *60*1000) then -- >=1 hr, show hr + min
	cast(floor((R.estimated_completion_time + 30 *1000) / (60 *60*1000)) as varchar(2)) + ' hr ' 
	+ cast(floor((R.estimated_completion_time + 30 *1000) / (60 *1000)) % 60 as varchar(2)) + ' min'
when (R.estimated_completion_time) >= 15 *(60 *1000) then -- >= 15 min, show min only
	cast(floor((R.estimated_completion_time) / (60 *1000)) as varchar(2)) + ' min'
when (R.estimated_completion_time + 0.5 *1000) >= 1 *(60 *1000) then -- >= 1 min, show min + sec
	cast(floor((R.estimated_completion_time + 0.5 *1000) / (60 *1000)) % 60 as varchar(2)) + ' min ' 
	+ cast(floor((R.estimated_completion_time + 0.5 *1000) / 1000) % 60 as varchar(2)) + ' sec'
when (R.estimated_completion_time + 0.5 *1000) >= 1 *1000 then -- >= 1 sec, show sec only
	cast(floor((R.estimated_completion_time + 0.5 *1000) / 1000) % 60 as varchar(2)) + ' sec'
when R.percent_complete > 0 then '< 1 sec'
else null
end as remaining_desc
,round(R.percent_complete, 0) as percent_complete_int
,cast(R.percent_complete as numeric(20, 1)) as percent_complete_one_decimal_place
FROM sys.dm_exec_requests as R
inner join sys.databases as D on R.database_id=D.database_id
cross apply sys.dm_exec_sql_text(R.[sql_handle]) as T
WHERE 	R.session_id <> @@SPID
	and (
	lower(R.command) like '%dbcc%'
	or lower(T.[text]) like '%dbcc checkdb%'
	or lower(T.[text]) like '%dbcc table%'
	or lower(R.command) like '%backup%'
	or lower(R.command) like '%restore%'
	or lower(R.command) like '%rollback%'
	or lower(R.command) like '%killed%'
	)

