
;with cteJobInfo as (
select
jv.name AS job_name
,jh.step_name AS job_step_name
,case when jh.step_name = '(Job outcome)' then 1 else 0 end as is_job_outcome
-- job columns
,case when jh.step_name = '(Job outcome)' then msdb.dbo.AGENT_DATETIME(jh.run_date, jh.run_time) else null end as job_start_time
,case when jh.step_name = '(Job outcome)' then dateadd(second, (jh.run_duration/10000)*24*60*60 + (jh.run_duration/100%100)*60 + jh.run_duration%100, msdb.dbo.AGENT_DATETIME(jh.run_date, jh.run_time)) else null end AS job_end_time
,case when jh.step_name = '(Job outcome)' then jh.run_duration/10000 else null end as job_hours
,case when jh.step_name = '(Job outcome)' then jh.run_duration/100%100 else null end as job_minutes
,case when jh.step_name = '(Job outcome)' then jh.run_duration%100 else null end as job_seconds
,case when jh.step_name = '(Job outcome)' then (jh.run_duration/10000)*24*60*60 + (jh.run_duration/100%100)*60 + jh.run_duration%100 else null end as job_total_seconds
,case when jh.step_name = '(Job outcome)' then 
	case
	when (jh.run_duration/10000)*24*60*60 + (jh.run_duration/100%100)*60 + jh.run_duration % 100 > 60*60 -- > 1 hr, hr + min
	then cast(jh.run_duration/10000 as varchar) + ' hr '
		+ cast(floor(jh.run_duration/100%100 + ((jh.run_duration%100)+30)/60) as varchar) + ' min'
	when (jh.run_duration/10000)*24*60*60 + (jh.run_duration/100%100)*60 + jh.run_duration % 100 >= 15*60 -- > 15 min, show min only
	then cast(floor(jh.run_duration/100%100 + (jh.run_duration%100+30)/60) as varchar) + ' min'
	when (jh.run_duration/10000)*24*60*60 + (jh.run_duration/100%100)*60 + jh.run_duration % 100 >= 1*60 -- > 1 min, show min + sec
	then cast(jh.run_duration/100%100 as varchar) + ' min '
		+ cast(jh.run_duration%100 as varchar) + ' sec'
	else cast(jh.run_duration%100 as varchar) + ' sec' -- show seconds only
	end 
end as job_elapsed_desc

-- job step columns
,case when jh.step_name <> '(Job outcome)' then msdb.dbo.AGENT_DATETIME(jh.run_date, jh.run_time) else null end AS job_step_start_time
,case when jh.step_name <> '(Job outcome)' then dateadd(second, (jh.run_duration/10000)*24*60*60 + (jh.run_duration/100%100)*60 + jh.run_duration%100, msdb.dbo.AGENT_DATETIME(jh.run_date, jh.run_time)) else null end AS job_step_end_time
,case when jh.step_name <> '(Job outcome)' then jh.run_duration/10000 else null end as job_step_hours
,case when jh.step_name <> '(Job outcome)' then jh.run_duration/100%100 else null end as job_step_minutes
,case when jh.step_name <> '(Job outcome)' then jh.run_duration%100 else null end as job_step_seconds
,case when jh.step_name <> '(Job outcome)' then (jh.run_duration/10000)*24*60*60 + (jh.run_duration/100%100)*60 + jh.run_duration % 100 else null end as job_step_total_seconds
,case when jh.step_name <> '(Job outcome)' then 
	case
	when (jh.run_duration/10000)*24*60*60 + (jh.run_duration/100%100)*60 + jh.run_duration % 100 > 60*60 -- > 1 hr, hr + min
	then cast(jh.run_duration/10000 as varchar) + ' hr '
		+ cast(floor(jh.run_duration/100%100 + ((jh.run_duration%100)+30)/60) as varchar) + ' min'
	when (jh.run_duration/10000)*24*60*60 + (jh.run_duration/100%100)*60 + jh.run_duration % 100 >= 15*60 -- > 15 min, show min only
	then cast(floor(jh.run_duration/100%100 + (jh.run_duration%100+30)/60) as varchar) + ' min'
	when (jh.run_duration/10000)*24*60*60 + (jh.run_duration/100%100)*60 + jh.run_duration % 100 >= 1*60 -- > 1 min, show min + sec
	then cast(jh.run_duration/100%100 as varchar) + ' min '
		+ cast(jh.run_duration%100 as varchar) + ' sec'
	else cast(jh.run_duration%100 as varchar) + ' sec' -- show seconds only
	end 
end as job_step_elapsed_desc
-- in case you need to join on other columns
,jh.job_id
,jh.instance_id
from msdb.dbo.sysjobs_view as jv
inner join msdb.dbo.sysjobhistory jh ON jv.job_id = jh.job_id
)
select * from cteJobInfo
where
	is_job_outcome = 1 -- is_job_outcome = 1: show entire job; is_job_outcome = 0: show job steps
	--and job_name like 'ETL%'
	and job_start_time > dateadd(day, -7, current_timestamp) -- in last week
	--and job_total_seconds > 10*60 -- job took longer than 10 sec

