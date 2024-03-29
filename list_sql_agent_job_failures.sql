
/*
Purpose:
Show recent sql agent job errors in a more readable format than the sql job history (IMO).

Variables:
@sql_jobs_errors_after: how far back to look for sql agent job errors
@show_sql_jobs_in_progress: whether to include jobs that are currently running
*/

declare @sql_jobs_errors_after datetime = dateadd(hour, -24, current_timestamp)
declare @show_sql_jobs_in_progress bit = 0 -- 1=show sql server agent jobs that are running right now

set nocount on
begin try
	drop table #job_history
end try begin catch end catch

print 'Showing SQL job agent failures on server: ' + @@servername
print ''

;with cteJobHistory as (
	select
	job_id
	,run_status
	,step_id
	,step_name
	,[message]
	,max(msdb.dbo.agent_datetime(run_date, run_time)) as job_step_timestamp
	,max(instance_id) as instance_id
	from msdb.dbo.sysjobhistory
	group by job_id, run_status, step_id, step_name, [message]
)
select top 100
H.[server] as [server_name]
,J.[name] as [job_name]
,J.job_id
,H.instance_id
,J.[enabled] as [job_enabled]
,H.step_id as [job_step_number]
,H.step_name as [job_step_name]
,H.[message]
,H.run_status
,H.run_duration as [job_step_duration_sec]
,CONVERT(varchar, DATEADD(second, H.run_duration, 0), 8) as job_step_duration_hms
,J.[description]
,msdb.dbo.agent_datetime(H.run_date, H.run_time) as job_step_timestamp
into #job_history
from msdb.dbo.sysjobhistory as H
inner join cteJobHistory as CTEJH on H.job_id = CTEJH.job_id and H.instance_id = CTEJH.instance_id
inner join msdb.dbo.sysjobs as J on H.job_id = J.job_id
where (H.run_status in (0, 2, 3)
	or (@show_sql_jobs_in_progress = 1 and H.run_status in (0, 2, 3, 4))
	)
and H.step_id = 0
and msdb.dbo.agent_datetime(H.run_date, H.run_time) > @sql_jobs_errors_after

alter table #job_history add processed bit
update #job_history set processed = 0

declare @job_id uniqueidentifier
declare @previous_job_id uniqueidentifier
declare @instance_id int
declare @previous_instance_id int
declare @run_status varchar(1)
declare @v varchar(8000)

set @previous_job_id = null
while exists(select * from #job_history where processed = 0)
begin
	select top 1
	@instance_id = instance_id
	,@job_id = job_id
	from #job_history
	where processed = 0
	order by job_step_timestamp
	update #job_history set processed = 1 where instance_id = @instance_id
	if @previous_job_id is null or @previous_job_id <> @job_id
	begin
		if @previous_job_id is not null
			print '------'
		set @v = 'Job name: ' + (select [job_name] from #job_history where instance_id = @instance_id) print @v
	end
	set @previous_job_id = @job_id

	begin try
		drop table #job_steps
	end try begin catch end catch

	select *
		into #job_steps
		from msdb.dbo.sysjobhistory as H
		where H.job_id = @job_id
		and (H.run_status in (0, 2, 3)
			or (@show_sql_jobs_in_progress = 1 and H.run_status in (0, 2, 3, 4))
			)
		and H.step_id > 0
		and msdb.dbo.agent_datetime(H.run_date, H.run_time) > @sql_jobs_errors_after

	alter table #job_steps add processed bit
	update #job_steps set processed = 0
	set @previous_instance_id = null
	while exists(select * from #job_steps where processed = 0)
	begin
		select top 1
		@instance_id = instance_id
		from #job_steps
		where processed = 0
		order by msdb.dbo.agent_datetime(run_date, run_time)
		update #job_steps set processed = 1 where instance_id = @instance_id
		if @previous_instance_id is not null
			print ''
		set @previous_instance_id = @instance_id
		set @v = 'Job started at '
		set @v = @v + (select cast(msdb.dbo.agent_datetime(run_date, run_time) as varchar) from #job_steps where instance_id = @instance_id)
		set @v = @v + ' on job step #' + (select cast(step_id as varchar(4)) from #job_steps where instance_id = @instance_id)
		print @v
		set @v = 'Step name: (' + (select cast(step_id as varchar(4)) from #job_steps where instance_id = @instance_id) + ')'
		set @v = @v + ' ' + (select [step_name] from #job_steps where instance_id = @instance_id)
		print @v
		set @v = 'Duration (Hr:Min:Sec): ' + (select CONVERT(varchar, DATEADD(second, run_duration, 0), 8) from #job_steps where instance_id = @instance_id)
		print @v
		set @run_status = (select cast(run_status as varchar(4)) from #job_steps where instance_id = @instance_id)
		set @v = 'Reason: ' + @run_status
		set @v = @v + ' / ' + case
			when @run_status = 0 then 'Failed'
			when @run_status = 1 then 'Succeeded'
			when @run_status = 2 then 'Retried'
			when @run_status = 3 then 'Cancelled'
			when @run_status = 4 then 'In progress'
		end
		print @v
		set @v = 'Message: ' + (select [message] from #job_steps where instance_id = @instance_id) print @v
		if charindex('deadlock victim', @v) > 0
			print 'Note: may have been a deadlock victim'
	end
	
end
