SELECT top 50 percent D.name, CONVERT(DECIMAL(10,2)
,sum((F.size * 8.00) / 1024.00 / 1024.00)) As UsedSpace_GB
FROM master.sys.master_files as F
inner join sys.databases as D on F.database_id = D.database_id
group by D.name
order by 2 desc
