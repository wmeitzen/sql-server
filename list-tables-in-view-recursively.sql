;with recurse_views_and_tables AS (
select V.[name] as parent_table_name,
SED.referenced_entity_name as table_name
from   sys.sql_expression_dependencies as SED
inner join sys.views as V ON SED.referencing_id = V.[object_id]
where  V.[name] = 'V_VIEW_NAME'
union all
select V.[name] as parent_table_name,
SED.referenced_entity_name as table_name
from   sys.sql_expression_dependencies as SED
inner join sys.views as V on SED.referencing_id = V.[object_id]
inner join recurse_views_and_tables as RCTE on RCTE.table_name = V.[name]
)
select distinct S.[name] as [schema], VT.table_name
, cast(round((sum(A.used_pages) / 128.0), 2) as numeric(36, 2)) as size_mb
from recurse_views_and_tables as VT
inner join sys.objects as O on VT.table_name = O.[name]
inner join sys.schemas as S on O.[schema_id] = S.[schema_id]
inner join sys.indexes as IDX ON O.[object_id] = IDX.[object_id]
inner join sys.partitions as P on IDX.[object_id] = P.[object_id] and IDX.index_id = P.index_id
inner join sys.allocation_units as A on P.[partition_id] = A.container_id
where O.[TYPE_DESC] = 'USER_TABLE'
group by S.[name], VT.table_name
