
SELECT
jv.name AS job_name
,jh.step_name AS job_step_name
-- job columns
,case when jh.step_name = '(Job outcome)' then msdb.dbo.AGENT_DATETIME(jh.run_date, jh.run_time) else null end AS job_start_time
,case when jh.step_name = '(Job outcome)' then dateadd(second, (jh.run_duration/10000)*24*60*60 + (jh.run_duration/100%100)*60 + jh.run_duration%100, msdb.dbo.AGENT_DATETIME(jh.run_date, jh.run_time)) else null end AS job_end_time
,case when jh.step_name = '(Job outcome)' then jh.run_duration/10000 else null end as job_hours --hours
,case when jh.step_name = '(Job outcome)' then jh.run_duration/100%100 else null end as job_minutes --minutes
,case when jh.step_name = '(Job outcome)' then jh.run_duration%100 else null end as job_seconds --seconds
,case when jh.step_name = '(Job outcome)' then (jh.run_duration/10000)*24*60*60 + (jh.run_duration/100%100)*60 + jh.run_duration%100 else null end as job_total_seconds
,case when jh.step_name = '(Job outcome)' then 
	case
	when (jh.run_duration/10000)*24*60*60 + (jh.run_duration/100%100)*60 + (jh.run_duration%100) > 60*60 -- > 1 hr, hr + min
	then cast(jh.run_duration/10000 as varchar) + ' hr '
		+ cast(floor(jh.run_duration/100%100 + ((jh.run_duration%100)+30)/60) as varchar) + ' min'
	when (jh.run_duration/10000)*24*60*60 + (jh.run_duration/100%100)*60 + (jh.run_duration%100) >= 15*60 -- > 15 min, show min only
	then cast(floor(jh.run_duration/100%100 + (jh.run_duration%100+30)/60) as varchar) + ' min'
	when (jh.run_duration/10000)*24*60*60 + (jh.run_duration/100%100)*60 + (jh.run_duration%100) >= 1*60 -- > 1 min, show min + sec
	then cast(jh.run_duration/100%100 as varchar) + ' min '
		+ cast(jh.run_duration%100 as varchar) + ' sec'
	else cast(jh.run_duration%100 as varchar) + ' sec' -- show sec
	end 
end as job_elapsed_desc

-- job step columns
,case when jh.step_name <> '(Job outcome)' then msdb.dbo.AGENT_DATETIME(jh.run_date, jh.run_time) else null end AS job_step_start_time
,case when jh.step_name <> '(Job outcome)' then dateadd(second, (jh.run_duration/10000)*24*60*60 + (jh.run_duration/100%100)*60 + jh.run_duration%100, msdb.dbo.AGENT_DATETIME(jh.run_date, jh.run_time)) else null end AS job_step_end_time
,case when jh.step_name <> '(Job outcome)' then jh.run_duration/10000 else null end as job_step_hours --hours
,case when jh.step_name <> '(Job outcome)' then jh.run_duration/100%100 else null end as job_step_minutes --minutes
,case when jh.step_name <> '(Job outcome)' then jh.run_duration%100 else null end as job_step_seconds --seconds
,case when jh.step_name <> '(Job outcome)' then (jh.run_duration/10000)*24*60*60 + (jh.run_duration/100%100)*60 + (jh.run_duration%100) else null end as job_step_total_seconds
,case when jh.step_name <> '(Job outcome)' then 
	case
	when (jh.run_duration/10000)*24*60*60 + (jh.run_duration/100%100)*60 + (jh.run_duration%100) > 60*60 -- > 1 hr, hr + min
	then cast(jh.run_duration/10000 as varchar) + ' hr '
		+ cast(floor(jh.run_duration/100%100 + ((jh.run_duration%100)+30)/60) as varchar) + ' min'
	when (jh.run_duration/10000)*24*60*60 + (jh.run_duration/100%100)*60 + (jh.run_duration%100) >= 15*60 -- > 15 min, show min only
	then cast(floor(jh.run_duration/100%100 + (jh.run_duration%100+30)/60) as varchar) + ' min'
	when (jh.run_duration/10000)*24*60*60 + (jh.run_duration/100%100)*60 + (jh.run_duration%100) >= 1*60 -- > 1 min, show min + sec
	then cast(jh.run_duration/100%100 as varchar) + ' min '
		+ cast(jh.run_duration%100 as varchar) + ' sec'
	else cast(jh.run_duration%100 as varchar) + ' sec' -- show sec
	end 
end as job_step_elapsed_desc
FROM msdb.dbo.sysjobs_view as jv
INNER JOIN msdb.dbo.sysjobhistory jh ON jv.job_id = jh.job_id
where /*jh.step_name = '(Job outcome)' and*/ jv.name = 'DBA - fake job - WTM'
