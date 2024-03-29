
declare @fltCompressionMultiplier float
set @fltCompressionMultiplier = 0.5

SELECT /*top 10 percent*/
D.name
,cast(D.create_date as date) as date_created
, @@version as [@@version]
,CONVERT(DECIMAL(10,2),sum((F.size * 8.00) / 1024.00 / 1024.00)) As UsedSpace_GB
,CONVERT(DECIMAL(10,2),sum((F.size * 8.00) / 1024.00)) As UsedSpace_MB
,case
	when @@version like '%Express Edition%' then 0
	when @@version like '%Server 2022%' then 1
	when @@version like '%Server 2019%' then 1
	when @@version like '%Server 2017%' then 1
	when @@version like '%Server 2016%' and @@version like '%sp2%' then 1
	when @@version like '%Server 2005%' then 0
	when @@version like '%enterprise%' then 1
	else 0
end as compression_available
,CONVERT(DECIMAL(10,2),sum((F.size * 8.00) / 1024.00 / 1024.00)
	* case
		when @@version like '%Express Edition%' then 1
		when @@version like '%Server 2022%' then @fltCompressionMultiplier
		when @@version like '%Server 2019%' then @fltCompressionMultiplier
		when @@version like '%Server 2017%' then @fltCompressionMultiplier
		when @@version like '%Server 2016%' and @@version like '%sp2%' then @fltCompressionMultiplier
		when @@version like '%Server 2005%' then 1
		when @@version like '%enterprise%' then @fltCompressionMultiplier
		else 1
	end) as approximate_compression_GB
,CONVERT(DECIMAL(10,2),sum((F.size * 8.00) / 1024.00)
	* case
		when @@version like '%Express Edition%' then 1
		when @@version like '%Server 2022%' then @fltCompressionMultiplier
		when @@version like '%Server 2019%' then @fltCompressionMultiplier
		when @@version like '%Server 2017%' then @fltCompressionMultiplier
		when @@version like '%Server 2016%' and @@version like '%sp2%' then @fltCompressionMultiplier
		when @@version like '%Server 2005%' then 1
		when @@version like '%enterprise%' then @fltCompressionMultiplier
		else 1
	end) as approximate_compression_MB
FROM master.sys.master_files as F
inner join sys.databases as D on F.database_id = D.database_id
where D.name not in ('tempdb')
group by D.name, D.create_date
order by sum(F.size) desc
