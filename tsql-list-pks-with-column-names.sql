select
        quotename(schema_name(TBL_OUTSIDE.[schema_id])) as [schema]
        ,quotename(TBL_OUTSIDE.name) as [table_name]
        ,quotename(I_OUTSIDE.name) as [pk_name]
        ,I_OUTSIDE.type_desc as [clustered_or_nonclustered]
        ,ltrim(stuff((
                select
                                        ', '
                                        +quotename(col_name(K_1.parent_object_id, IC_1.column_id))
                                        +' '
                                        +case when IC_1.is_descending_key=1 then 'desc' else 'asc' end
                from sys.tables AS TBL_1
                inner join sys.indexes AS I_1 ON I_1.index_id > 0 and I_1.is_hypothetical = 0 AND I_1.[object_id]=TBL_1.[object_id]
                inner join sys.index_columns AS IC_1 ON
                        IC_1.column_id > 0
                        and (IC_1.key_ordinal > 0 or IC_1.partition_ordinal = 0 or IC_1.is_included_column <> 0)
                        and IC_1.index_id=cast(I_1.index_id AS int)
                        and IC_1.[object_id]=I_1.[object_id]
                inner join sys.columns AS CLMNS_1 ON CLMNS_1.[object_id] = IC_1.[object_id] and CLMNS_1.column_id = IC_1.column_id
                left outer join sys.key_constraints AS K_1 ON K_1.parent_object_id = I_1.[object_id] and K_1.unique_index_id = I_1.index_id
                where
                        schema_name(TBL_OUTSIDE.[schema_id])=schema_name(TBL_1.[schema_id])
                        and I_OUTSIDE.name=I_1.name
                        and TBL_OUTSIDE.name=TBL_1.name
                order by IC_1.key_ordinal
                for xml path('')
        ), 1, len(', '), '')) as [csv_columns]
--        ,I_OUTSIDE.*
from sys.tables AS TBL_OUTSIDE
inner join sys.indexes AS I_OUTSIDE ON I_OUTSIDE.index_id > 0 and I_OUTSIDE.is_hypothetical = 0 AND I_OUTSIDE.[object_id]=TBL_OUTSIDE.[object_id]
where TBL_OUTSIDE.type_desc='USER_TABLE'
and TBL_OUTSIDE.name not in ('dtproperties','sysdiagrams')  -- list true user tables only
and I_OUTSIDE.is_primary_key=1
order by
        schema_name(TBL_OUTSIDE.[schema_id])
        ,TBL_OUTSIDE.name
        ,I_OUTSIDE.name
