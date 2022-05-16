
declare @fltCompressionMultiplier float
set @fltCompressionMultiplier = 0.5

SELECT /*top 10 percent*/
D.name
, @@version as [@@version]
,CONVERT(DECIMAL(10,2),sum((F.size * 8.00) / 1024.00 / 1024.00)) As UsedSpace_GB
,CONVERT(DECIMAL(10,2),sum((F.size * 8.00) / 1024.00)) As UsedSpace_MB
,case
	when @@version like '%2022%' then 1
	when @@version like '%2019%' then 1
	when @@version like '%2017%' then 1
	when @@version like '%2016%' and @@version like '%sp2%' then 1
	when @@version like '%enterprise%' then 1
	else 0
end as compression_available
,CONVERT(DECIMAL(10,2),sum((F.size * 8.00) / 1024.00 / 1024.00)
	* case
		when @@version like '%2022%' then @fltCompressionMultiplier
		when @@version like '%2019%' then @fltCompressionMultiplier
		when @@version like '%2017%' then @fltCompressionMultiplier
		when @@version like '%2016%' and @@version like '%sp2%' then @fltCompressionMultiplier
		when @@version like '%enterprise%' then @fltCompressionMultiplier
		else 1
	end) as approximate_compression_GB
,CONVERT(DECIMAL(10,2),sum((F.size * 8.00) / 1024.00)
	* case
		when @@version like '%2022%' then @fltCompressionMultiplier
		when @@version like '%2019%' then @fltCompressionMultiplier
		when @@version like '%2017%' then @fltCompressionMultiplier
		when @@version like '%2016%' and @@version like '%sp2%' then @fltCompressionMultiplier
		when @@version like '%enterprise%' then @fltCompressionMultiplier
		else 1
	end) as approximate_compression_MB
FROM master.sys.master_files as F
inner join sys.databases as D on F.database_id = D.database_id
where D.name not in ('tempdb')
group by D.name
order by sum(F.size) desc
