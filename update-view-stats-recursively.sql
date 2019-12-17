-- update all table stats used by views
-- order by table size in descending order (update biggest tables 1st)
set nocount on
go
begin try
drop table #commands
end try
begin catch
end catch
go

;WITH deps AS (
SELECT v.name as parent,
sed.referenced_entity_name as child
FROM   sys.sql_expression_dependencies sed
INNER JOIN sys.views AS v ON sed.referencing_id = v.object_id
WHERE  v.name in ('VIEW_NAME_1', 'VIEW_NAME_2') -- list all views
UNION ALL
SELECT v.name as parent,
sed.referenced_entity_name as child
FROM   sys.sql_expression_dependencies sed
INNER JOIN sys.views AS v ON sed.referencing_id = v.object_id
INNER JOIN deps ON deps.child = v.name
)
, views_and_tables as (
SELECT   parent ,
child
FROM     deps
UNION -- add extra tables to update stats on
select '', 'TABLE_NAME_1'
UNION
select '', 'TABLE_NAME_2'
)
select distinct 'update statistics [' + S.name + '].[' + VT.child + '] with fullscan -- '
+ cast(CAST(ROUND((SUM(A.used_pages) / 128.00), 2) AS NUMERIC(36, 2)) as varchar(36)) + ' MB'
as exec_command
, SUM(A.used_pages) as used_pages, S.name as [schema], VT.child as [table_name]
into #commands
from views_and_tables as VT
inner join sys.objects as O on VT.child = O.name
inner join sys.schemas as S on O.[schema_id] = S.[schema_id]
inner join sys.indexes as IDX ON O.[object_id] = IDX.[object_id]
inner join sys.partitions as P on IDX.[object_id] = P.[object_id] and IDX.index_id = P.index_id
inner join sys.allocation_units as A on P.[partition_id] = A.container_id
where O.type_desc = 'USER_TABLE'
group by S.name, VT.child
--order by SUM(A.used_pages) desc, 1, S.name, VT.child
--order by SUM(A.used_pages) desc, S.name, VT.child
go

declare @strExec nvarchar(max)
while exists(select * from #commands)
begin
select top 1 @strExec = exec_command from #commands
order by used_pages desc, [schema], table_name
delete from #commands where exec_command = @strExec
print @strExec
execute sp_executesql @stmt = @strExec
end
