---------- QUERY #1 OF 2

;with cte_index_column_names as (
SELECT
SCHEMA_NAME(tbl.schema_id) as [schema],
tbl.name as table_name, 
i.name AS index_name,
case when xi.xml_index_type_description is null then i.type_desc else xi.xml_index_type_description end as type_desc,
i.is_primary_key,
case when i.is_unique=1 then 'unique ' else '' end as [unique],
xi2.name as parent_xml_index,
xi.secondary_type_desc as secondary_xml_type_desc,
xi2.xml_index_type_description,
(
        ltrim(stuff((
                        SELECT
                        ', '
                        +quotename(clmns.name)
                        +' '
                        +CASE WHEN sub_ic.is_descending_key = 1 THEN 'desc' ELSE 'asc' END
                from sys.tables as sub_tbl
                inner join sys.indexes as sub_i on sub_i.index_id>0 and sub_i.is_hypothetical=0 and sub_i.[object_id]=sub_tbl.[object_id]
                inner join sys.index_columns as sub_ic on (sub_ic.column_id > 0 and (sub_ic.key_ordinal > 0 or sub_ic.partition_ordinal = 0)) AND (sub_ic.index_id=CAST(sub_i.index_id AS int) AND sub_ic.[object_id]=sub_i.[object_id])
                inner join sys.columns as clmns on clmns.[object_id]=sub_ic.[object_id] and clmns.column_id=sub_ic.column_id
                where sub_i.[object_id]=i.[object_id] and sub_i.index_id=i.index_id
                        and sub_ic.is_included_column=0
                order by sub_ic.key_ordinal
                FOR XML PATH('')
        ), 1, len(', '), ''))
) as csv_index_columns_with_order
,(
        ltrim(stuff((
                        SELECT
                        ', '
                        +quotename(clmns.name)
                from sys.tables as sub_tbl
                inner join sys.indexes as sub_i on sub_i.index_id>0 and sub_i.is_hypothetical=0 and sub_i.[object_id]=sub_tbl.[object_id]
                inner join sys.index_columns as sub_ic on (sub_ic.column_id > 0 and (sub_ic.key_ordinal > 0 or sub_ic.partition_ordinal = 0)) AND (sub_ic.index_id=CAST(sub_i.index_id AS int) AND sub_ic.[object_id]=sub_i.[object_id])
                inner join sys.columns as clmns on clmns.[object_id]=sub_ic.[object_id] and clmns.column_id=sub_ic.column_id
                where sub_i.[object_id]=i.[object_id] and sub_i.index_id=i.index_id
                        and sub_ic.is_included_column=0
                order by sub_ic.key_ordinal
                FOR XML PATH('')
        ), 1, len(', '), ''))
) as csv_index_columns_without_order
,(
        ltrim(stuff((
                        SELECT
                        ', '
                        +quotename(clmns.name)
                from sys.tables as sub_tbl
                inner join sys.indexes as sub_i on sub_i.index_id>0 and sub_i.is_hypothetical=0 and sub_i.[object_id]=sub_tbl.[object_id]
                inner join sys.index_columns as sub_ic on (sub_ic.column_id > 0 and (sub_ic.key_ordinal > 0 or sub_ic.partition_ordinal = 0 or sub_ic.is_included_column != 0)) AND (sub_ic.index_id=CAST(sub_i.index_id AS int) AND sub_ic.[object_id]=sub_i.[object_id])
                inner join sys.columns as clmns on clmns.[object_id]=sub_ic.[object_id] and clmns.column_id=sub_ic.column_id
                where sub_i.[object_id]=i.[object_id] and sub_i.index_id=i.index_id
                        AND sub_ic.is_included_column = 1
                order by sub_ic.key_ordinal
                FOR XML PATH('')
        ), 1, len(', '), ''))
) as csv_include_columns
,(
                select cast(count(*) as bit)
                from sys.columns as sub_c
                inner join sys.tables as sub_t on sub_c.[object_id]=sub_t.[object_id]
                where
                        sub_t.[object_id]=tbl.[object_id]
                        and sub_c.is_computed=1
) as table_has_computed_columns
,i.filter_definition
,indexedpaths.name AS indexed_xml_path_name
FROM sys.tables AS tbl
INNER JOIN sys.indexes AS i ON (i.index_id > 0 and i.is_hypothetical = 0) AND (i.[object_id]=tbl.[object_id])
LEFT OUTER JOIN sys.stats AS s ON s.stats_id = i.index_id AND s.[object_id] = i.[object_id]
LEFT OUTER JOIN sys.key_constraints AS k ON k.parent_object_id = i.[object_id] AND k.unique_index_id = i.index_id
LEFT OUTER JOIN sys.xml_indexes AS xi ON xi.[object_id] = i.[object_id] AND xi.index_id = i.index_id
LEFT OUTER JOIN sys.xml_indexes AS xi2 ON xi2.[object_id] = xi.[object_id] AND xi2.index_id = xi.using_xml_index_id
LEFT OUTER JOIN sys.spatial_indexes AS spi ON i.[object_id] = spi.[object_id] and i.index_id = spi.index_id
LEFT OUTER JOIN sys.spatial_index_tessellations as si ON i.[object_id] = si.[object_id] and i.index_id = si.index_id
LEFT OUTER JOIN sys.data_spaces AS dsi ON dsi.data_space_id = i.data_space_id
LEFT OUTER JOIN sys.tables AS t ON t.[object_id] = i.[object_id]
LEFT OUTER JOIN sys.data_spaces AS dstbl ON dstbl.data_space_id = t.Filestream_data_space_id and i.index_id < 2
LEFT OUTER JOIN sys.filetable_system_defined_objects AS filetableobj ON i.[object_id] = filetableobj.[object_id]
LEFT OUTER JOIN sys.selective_xml_index_paths AS indexedpaths ON xi.[object_id] = indexedpaths.[object_id] AND xi.using_xml_index_id = indexedpaths.index_id AND xi.path_id = indexedpaths.path_id
)
select
        quotename([schema])+'.'+quotename(table_name) as [{TABLE_NAME}]
        ,[schema]+'.'+table_name as [{UNQUOTED_TABLE_NAME}]
        ,quotename(index_name) as [{INDEX_NAME}]
        ,index_name as [{UNQUOTED_INDEX_NAME}]
        ,case
                when table_has_computed_columns=1 or type_desc in ('PRIMARY_XML', 'SECONDARY_XML') then 'set quoted_identifier on' else 'set quoted_identifier off'
        end
        as [{QUOTED_IDENTIFIER_COMMAND}]
        ,case
                when is_primary_key=1 then 'alter table '+quotename([schema])+'.'+quotename(table_name)+' add constraint '+quotename(index_name)+' primary key '+type_desc
                when type_desc='PRIMARY_XML' then 'create primary xml index '+quotename(index_name)+' on '+quotename([schema])+'.'+quotename(table_name)
                when type_desc='SECONDARY_XML' then 'create xml index '+quotename(index_name)+' on '+quotename([schema])+'.'+quotename(table_name)
                else 'create '+[unique]+type_desc collate database_default +' index '+quotename(index_name)+' on '+quotename([schema])+'.'+quotename(table_name)
        end as [{COMMAND_PREFIX}]
        ,case
                when type_desc in ('PRIMARY_XML', 'SECONDARY_XML') then csv_index_columns_without_order
                else csv_index_columns_with_order
        end as [{CSV_INDEX_COLUMNS}]
        ,case
                when type_desc='SECONDARY_XML' then 'using xml index '+quotename(parent_xml_index)+' for '+secondary_xml_type_desc collate database_default
        end as [{SECONDARY_XML_INDEX_USING}]
        ,case when csv_include_columns is not null then 'include ('+csv_include_columns+')' end as [{INCLUDE_CLAUSE}]
        ,case when filter_definition is not null then 'where '+filter_definition end as [{FILTER_DEFINITION}]
FROM
   cte_index_column_names
ORDER BY
   table_name
        ,case when lower(type_desc)='clustered' then 1 else 2 end -- create the clustered index first before nonclustered indexes
        ,case when lower(type_desc)='primary_xml' then 1 else 2 end -- create the primary xml index first before secondary xml indexes
   ,index_name
   
---------- QUERY #2 OF 2
   
-- For each row returned above, replace the value from each column into the template SQL code below:

print 'Creating {UNQUOTED_INDEX_NAME} on {UNQUOTED_TABLE_NAME}'
go

{QUOTED_IDENTIFIER_COMMAND}
go

{COMMAND_PREFIX}
({CSV_INDEX_COLUMNS})
{SECONDARY_XML_INDEX_USING}
{INCLUDE_CLAUSE}
{FILTER_DEFINITION}
go
