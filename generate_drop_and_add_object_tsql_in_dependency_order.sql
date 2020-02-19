/*
The SQL functions (below) and command (at the very bottom)
enables you to output DROP and CREATE commands for all PKs, FKs, and
indexes in dependency order below a user-specified TABLE_NAME.
It does not execute the DROP or CREATE commands; it only generates them.
I used it to change datetime2 datatypes to datetime on a database with 11 levels of dependencies.

Function dbo.deps_it_depends:
Return a list of all database objects and dependencies.
Slightly expanded from Phil Factor's code. (His method of gathering the dependencies
is pretty ingenious!)

Function deps_generate_create_and_drop_index:
Given a schema and index name or PK name, return the code to drop and create the object.

Function deps_generate_create_and_drop_fk
Given a schema and FK name, return the code to drop and create the object.
*/

IF OBJECT_ID (N'dbo.deps_it_depends') IS NOT NULL
   DROP FUNCTION dbo.deps_it_depends
GO

CREATE FUNCTION dbo.deps_it_depends (@p_schema varchar(255), @ObjectName varchar(200), @ObjectsOnWhichItDepends bit)
RETURNS @References TABLE (
       ObjectPath VARCHAR(MAX), --the ancestor objects delimited by a '/'
       ObjectSchema VARCHAR(200),
       ObjectName VARCHAR(200),
       ObjectType VARCHAR(20),
       iteration INT
)

/**
summary:   >
 This Table function returns a a table giving the dependencies of the object whose name
 is supplied as a parameter.
 At the moment, only objects are allowed as a parameter, You can specify whether you
 want those objects that rely on the object, or those on whom the object relies.
compatibility: SQL Server 2005 - SQL Server 2012
 Revisions:
 - Author: Phil Factor
   Version: 1.1
Modified by William Meitzen
*/
AS
BEGIN
DECLARE   @DatabaseDependencies TABLE (
	   ObjectSchemaName varchar(255),
       ObjectName VARCHAR(200),
       ObjectType CHAR(5),
       DependencyType CHAR(4), -- hard or soft
       ReferredObjectSchema VARCHAR(200),
       ReferredObjectName VARCHAR(200),
       ReferredType CHAR(5)
)

INSERT  INTO @DatabaseDependencies ( ObjectSchemaName, ObjectName, ObjectType, DependencyType, ReferredObjectSchema, ReferredObjectName, ReferredType )
              -- tables that reference UDTs
        SELECT  object_schema_name(o.object_id), o.name, o.type, 'hard', object_schema_name(c.object_id), ty.name, 'UDT'
        FROM    sys.objects o
                INNER JOIN sys.columns AS c ON c.object_id = o.object_id
                INNER JOIN sys.types ty ON ty.user_type_id = c.user_type_id
        WHERE   is_user_defined = 1
        UNION ALL
              -- udtts that reference UDTTs
        SELECT  object_schema_name(tt.type_table_object_id), tt.name, 'UDTT', 'hard', object_schema_name(c.object_id), ty.name, 'UDT'
        FROM    sys.table_types tt
                INNER JOIN sys.columns AS c ON c.object_id = tt.type_table_object_id
                INNER JOIN sys.types ty ON ty.user_type_id = c.user_type_id
        WHERE   ty.is_user_defined = 1
         UNION ALL
              --tables/views that reference triggers         
        SELECT  object_schema_name(o.object_id), o.name, o.type, 'hard', object_schema_name(t.object_id), t.name, t.type
        FROM    sys.objects t
                INNER JOIN sys.objects AS o ON o.parent_object_id = t.object_id
        WHERE   o.type = 'TR'
        UNION ALL
              -- tables that reference defaults via columns (only default objects)
        SELECT  object_schema_name(clmns.object_id), object_name(clmns.object_id), 'U', 'hard', object_schema_name(o.object_id), o.name, o.type
        FROM    sys.objects o
                INNER JOIN sys.columns AS clmns ON clmns.default_object_id = o.object_id
        WHERE   o.parent_object_id = 0
        UNION ALL
              -- types that reference defaults (only default objects)
        SELECT  object_schema_name(o.object_id), o.name, 'UDT', 'hard', object_schema_name(o.object_id), types.name, o.type
        FROM    sys.objects o
                INNER JOIN sys.types AS types ON types.default_object_id = o.object_id
        WHERE   o.parent_object_id = 0
        UNION ALL
              -- tables that reference rules via columns
        SELECT  object_schema_name(clmns.object_id), object_name(clmns.object_id), 'U', 'hard', object_schema_name(o.object_id), o.name, o.type
        FROM    sys.objects o
                INNER JOIN sys.columns AS clmns ON clmns.rule_object_id = o.object_id
        UNION ALL          
              -- types that reference rules
        SELECT  object_schema_name(o.object_id), types.name, 'UDT', 'hard', object_schema_name(o.object_id), o.name, o.type
        FROM    sys.objects o
                INNER JOIN sys.types AS types ON types.rule_object_id = o.object_id
        UNION ALL
              -- tables that reference XmlSchemaCollections
        SELECT  object_schema_name(clmns.object_id), object_name(clmns.object_id), 'U', 'hard', object_schema_name(clmns.object_id), xml_schema_collections.name, 'XMLC'
        FROM    sys.columns clmns --should we eliminate views?
                INNER JOIN sys.xml_schema_collections ON xml_schema_collections.xml_collection_id = clmns.xml_collection_id
        UNION ALL
              -- table types that reference XmlSchemaCollections
        SELECT  object_schema_name(clmns.object_id), object_name(clmns.object_id), 'UDTT', 'hard', object_schema_name(clmns.object_id), xml_schema_collections.name, 'XMLC'
        FROM    sys.columns AS clmns
                INNER JOIN sys.table_types AS tt ON tt.type_table_object_id = clmns.object_id
                INNER JOIN sys.xml_schema_collections ON xml_schema_collections.xml_collection_id = clmns.xml_collection_id
        UNION ALL
              -- procedures that reference XmlSchemaCollections
        SELECT  object_schema_name(params.object_id), o.name, o.type, 'hard', object_schema_name(params.object_id), xml_schema_collections.name, 'XMLC'
        FROM    sys.parameters AS params
                INNER JOIN sys.xml_schema_collections ON xml_schema_collections.xml_collection_id = params.xml_collection_id
                INNER JOIN sys.objects o ON o.object_id = params.object_id
/*
        UNION ALL
              -- table references table - commented out b/c FK name is skipped
        SELECT  object_schema_name(tbl.object_id), tbl.name, tbl.type, 'hard', object_schema_name(referenced_object_id), object_name(referenced_object_id), 'U'
        FROM    sys.foreign_keys AS fk
                INNER JOIN sys.tables AS tbl ON tbl.object_id = fk.parent_object_id
*/

		-- begin FK
		union all
		-- fk_name -> referencING table (alter table [referencING] add constraint fk_name ... references [referencED])
		SELECT  object_schema_name(fk.object_id), fk.name, fk.type, 'hard', object_schema_name(tbl.object_id), tbl.name, 'FK'
		FROM    sys.foreign_keys AS fk
		INNER JOIN sys.tables AS tbl ON tbl.object_id = fk.parent_object_id
		-- referencED table -> fk_name (alter table [referencING] add constraint fk_name ... references [referencED])
		union all
		select object_schema_name(fkc.referenced_object_id), OBJECT_NAME(fkc.referenced_object_id), 'Ren', 'hard', object_schema_name(fk.object_id), fk.name, 'FR'
		from sys.foreign_key_columns as fkc
		inner join sys.foreign_keys as fk on fkc.constraint_object_id = fk.object_id
		group by fkc.referenced_object_id, fk.object_id, fk.name

		-- end FK

		-- begin indexes

		-- clustered index name and table name - cl index -> table
		union all
		select object_schema_name(IDX.[object_id]), IDX.name, 'CI', 'hard', object_schema_name(O.[object_id]), OBJECT_NAME(O.[object_id]), 'CI'
		from sys.indexes as IDX
		inner join sys.objects as O on IDX.[object_id] = O.[object_id]
		where O.type_desc = 'USER_TABLE'
		and IDX.type_desc = 'CLUSTERED'

		-- clustered index name and table name - table -> cl index
		union all
		select
		object_schema_name(O.[object_id]), OBJECT_NAME(O.[object_id])
		, 'CI', 'hard'
		, object_schema_name(IDX.[object_id]), IDX.name
		, 'CI'
		from sys.indexes as IDX
		inner join sys.objects as O on IDX.[object_id] = O.[object_id]
		where O.type_desc = 'USER_TABLE'
		and IDX.type_desc = 'CLUSTERED'

		-- nc index name and table name - nc index -> table
		union all
		--( ObjectSchemaName, ObjectName, ObjectType, DependencyType, ReferredObjectSchema, ReferredObjectName, ReferredType )
		--select object_schema_name(IDX.[object_id]), IDX.name, 'NCI', 'hard', object_schema_name(O.[object_id]), OBJECT_NAME(O.[object_id]), 'NCI'
		select object_schema_name(IDX.[object_id]), IDX.name, 'NCI', 'hard', object_schema_name(O.[object_id]), OBJECT_NAME(O.[object_id]), 'NCI'
		from sys.indexes as IDX
		inner join sys.objects as O on IDX.[object_id] = O.[object_id]
		where O.type_desc = 'USER_TABLE'
		and IDX.type_desc <> 'CLUSTERED'
		and IDX.name is not null -- filter out heaps

		-- nc index name and table name - table -> index
		union all
		select
		object_schema_name(O.[object_id]), OBJECT_NAME(O.[object_id])
		, 'NCI', 'hard'
		, object_schema_name(IDX.[object_id]), IDX.name
		, 'NCI'
		from sys.indexes as IDX
		inner join sys.objects as O on IDX.[object_id] = O.[object_id]
		where O.type_desc = 'USER_TABLE'
		and IDX.type_desc <> 'CLUSTERED'
		and IDX.name is not null -- filter out heaps

		-- end indexes

        UNION ALL                
               -- uda references types
        SELECT  object_schema_name(params.object_id), o.name, o.type, 'hard', object_schema_name(params.object_id), types.name, 'UDT'
        FROM    sys.parameters AS params
                INNER JOIN sys.types ON types.user_type_id = params.user_type_id
                INNER JOIN sys.objects o ON o.object_id = params.object_id
        WHERE   is_user_defined <> 0
        UNION ALL
               -- table,view references partition scheme
        SELECT  object_schema_name(o.object_id), o.name, o.type, 'hard', object_schema_name(idx.object_id), ps.name, 'PS'
        FROM    sys.indexes AS idx
                INNER JOIN sys.partitions p ON idx.object_id = p.object_id AND idx.index_id = p.index_id
                INNER JOIN sys.partition_schemes ps ON idx.data_space_id = ps.data_space_id
                INNER JOIN sys.objects AS o ON o.object_id = idx.object_id
        UNION ALL
              -- partition scheme references partition function
        SELECT  object_schema_name(o.object_id), ps.name, 'PS', 'hard', object_schema_name(o.object_id), o.name, o.type
        FROM    sys.partition_schemes ps
                INNER JOIN sys.objects AS o ON ps.function_id = o.object_id
        UNION ALL         
              -- plan guide references sp, udf, triggers
        SELECT  object_schema_name(o.object_id), pg.name, 'PG', 'hard', object_schema_name(o.object_id), o.name, o.type
        FROM    sys.objects o
                INNER JOIN sys.plan_guides AS pg ON pg.scope_object_id = o.object_id
        UNION ALL
               -- synonym refrences object
        SELECT  object_schema_name(o.object_id), s.name, 'SYN', 'hard', object_schema_name(o.object_id), o.name, o.type
        FROM    sys.objects o
                INNER JOIN sys.synonyms AS s ON object_id(s.base_object_name) = o.object_id
        UNION ALL                       
              --  sequences that reference uddts
        SELECT  object_schema_name(o.object_id), s.name, 'SYN', 'hard', object_schema_name(o.object_id), o.name, o.type
        FROM    sys.objects o
                INNER JOIN sys.sequences AS s ON s.user_type_id = o.object_id
        UNION ALL
        SELECT DISTINCT
                coalesce(object_schema_name(referencing_id), ''), object_name(referencing_id), referencer.type, 'soft'
				--,coalesce(referenced_schema_name, '') --likely schema name
				,object_schema_name(referencer.object_id)
				,coalesce(referenced_entity_name, ''), --very likely entity name
                referenced.type
        FROM    sys.sql_expression_dependencies
                INNER JOIN sys.objects referencer ON referencing_id = referencer.object_id
                INNER JOIN sys.objects referenced ON referenced_id = referenced.object_id
        WHERE   referencing_class = 1 AND referenced_class = 1 AND referencer.type IN ( 'v', 'tf', 'f', 'fk', 'fn', 'p', 'tr', 'u' )
 
DECLARE @rowcount INT
DECLARE @ii INT
-- firstly we put in the object as a seed.
INSERT  INTO @References (ObjectPath, ObjectSchema, ObjectName, ObjectType, iteration) -- ( ThePath, TheFullEntityName, TheType, iteration )
        SELECT  coalesce(object_schema_name(object_id) + '.', '') + name -- ObjectPath: full path with "/"
		, coalesce(object_schema_name(object_id), ''), name, type, 1 -- original is "1"
        FROM    sys.objects
		WHERE object_schema_name(object_id) = @p_schema and name = @ObjectName
-- then we just pull out the dependencies at each level. watching out for
-- self-references and circular references
SELECT  @rowcount = @@ROWCOUNT
set @ii = 2 -- original
--set @ii = 1
IF @ObjectsOnWhichItDepends <> 0 --if we are looking for objects on which it depends
WHILE @ii < 50 AND @rowcount > 0
BEGIN
INSERT  INTO @References (ObjectPath, ObjectSchema, ObjectName, ObjectType, iteration) -- ( ThePath, TheFullEntityName, TheType, iteration )
            SELECT DISTINCT
                    PR.ObjectPath + '/' + DD.ReferredObjectSchema + '.' + DD.ReferredObjectName -- ObjectPath: full path with "/"
					, DD.ReferredObjectSchema, DD.ReferredObjectName, DD.ReferredType, @ii
            FROM    @DatabaseDependencies as DD
                    INNER JOIN @References as PR ON /*PR.TheFullEntityName = DD.EntityName*/
					-- @DatabaseDependencies ( ObjectSchemaName, ObjectName, ObjectType, DependencyType, ReferredObjectSchema, ReferredObjectName, ReferredType )
						PR.ObjectSchema = DD.ObjectSchemaName
						and PR.ObjectName = DD.ObjectName
						AND PR.iteration = @ii - 1
                     --WHERE TheReferredEntity <> DD.EntityName
					 WHERE DD.ObjectSchemaName+'.'+DD.ObjectName <> DD.ReferredObjectSchema+'.'+DD.ReferredObjectName
                     --AND TheReferredEntity NOT IN (SELECT TheFullEntityName FROM @References)
					 and DD.ReferredObjectSchema+'.'+DD.ReferredObjectName not in (select ObjectSchema+'.'+ObjectName from @References)
    SELECT  @rowcount = @@rowcount
    SELECT  @ii = @ii + 1
  END
ELSE --we are looking for objects that depend on it.
WHILE @ii < 50 AND @rowcount > 0
  BEGIN
    INSERT  INTO @References (ObjectPath, ObjectSchema, ObjectName, ObjectType, iteration) -- ( ThePath, TheFullEntityName, TheType, iteration )
            SELECT DISTINCT
                    PR.ObjectPath + '/' + DD.ObjectSchemaName + '.' + DD.ObjectName -- ObjectPath: full path with "/"
					, DD.ObjectSchemaName, DD.ObjectName, DD.ObjectType, @ii
            FROM    @DatabaseDependencies as DD
                    --INNER JOIN @References as PR ON PR.TheFullEntityName = TheReferredEntity
						INNER JOIN @References as PR ON
						PR.ObjectSchema = DD.ReferredObjectSchema
						and PR.ObjectName = DD.ReferredObjectName
					 AND PR.iteration = @ii - 1
                     --WHERE TheReferredEntity<>EntityName
					 WHERE DD.ReferredObjectSchema+'.'+DD.ReferredObjectName <> DD.ObjectSchemaName+'.'+DD.ObjectName
                     --AND EntityName NOT IN (SELECT TheFullEntityName FROM @References)
					 and DD.ObjectSchemaName+'.'+DD.ObjectName not in (select ObjectSchema+'.'+ObjectName from @References)
    SELECT  @rowcount = @@rowcount
    SELECT  @ii = @ii + 1
  END
RETURN
END
go

/*
select * from deps_it_depends('dbo', 'TABLE_NAME', 1)
*/

IF OBJECT_ID (N'dbo.deps_generate_create_and_drop_index') IS NOT NULL
   DROP FUNCTION dbo.deps_generate_create_and_drop_index
GO


create function deps_generate_create_and_drop_index (@p_schema varchar(255), @p_index_name varchar(255))
RETURNS @sql_commands TABLE (
    ObjectSchema VARCHAR(200)
    ,ObjectTableName varchar(200)
    ,ObjectName VARCHAR(200)
    ,IsPrimaryKey bit
    ,TypeDesc varchar(200)
    ,create_command varchar(max)
    ,drop_command varchar(max)
)
as
begin

;with cte_index_column_names as (
SELECT
SCHEMA_NAME(tbl.schema_id) as [schema],
tbl.name as table_name, 
i.name AS index_name,
case when xi.xml_index_type_description is null then i.type_desc else xi.xml_index_type_description end as type_desc,
i.is_primary_key,
case when i.is_unique=1 then 'unique ' else '' end as [unique],
i.is_unique,
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
LEFT OUTER JOIN sys.data_spaces AS dstbl ON dstbl.data_space_id = t.filestream_data_space_id and i.index_id < 2
LEFT OUTER JOIN sys.filetable_system_defined_objects AS filetableobj ON i.[object_id] = filetableobj.[object_id]
LEFT OUTER JOIN sys.selective_xml_index_paths AS indexedpaths ON xi.[object_id] = indexedpaths.[object_id] AND xi.using_xml_index_id = indexedpaths.index_id AND xi.path_id = indexedpaths.path_id
)
, command_parts as (
select
	[schema] as unquoted_schema
	,quotename([schema]) as [schema]
    ,quotename([schema])+'.'+quotename(table_name) as qualified_table_name
    ,[schema]+'.'+table_name as unquoted_qualified_table_name
    ,table_name as unquoted_table_name
    ,quotename(index_name) as index_name
    ,index_name as unquoted_index_name
	,is_primary_key
	,[type_desc]
	,is_unique
    ,case
		when table_has_computed_columns=1 or [type_desc] in ('PRIMARY_XML', 'SECONDARY_XML') then 'set quoted_identifier on' else 'set quoted_identifier off'
    end
    as quoted_identifier_setting
    ,case
        when is_primary_key=1 then 'alter table '+quotename([schema])+'.'+quotename(table_name)+' add constraint '+quotename(index_name)+' primary key '+[type_desc]
        when is_unique=1 then 'alter table '+quotename([schema])+'.'+quotename(table_name)+' add constraint '+quotename(index_name)+' unique '+[type_desc]
        when [type_desc]='PRIMARY_XML' then 'create primary xml index '+quotename(index_name)+' on '+quotename([schema])+'.'+quotename(table_name)
        when [type_desc]='SECONDARY_XML' then 'create xml index '+quotename(index_name)+' on '+quotename([schema])+'.'+quotename(table_name)
        else 'create '+[unique]+[type_desc] collate database_default +' index '+quotename(index_name)+' on '+quotename([schema])+'.'+quotename(table_name)
    end as create_command_prefix
    ,case
        when type_desc in ('PRIMARY_XML', 'SECONDARY_XML') then csv_index_columns_without_order
        else csv_index_columns_with_order
    end as csv_index_columns
    ,case
		when type_desc='SECONDARY_XML' then 'using xml index '+quotename(parent_xml_index)+' for '+secondary_xml_type_desc collate database_default
    end as secondary_xml_index_using
    ,case when csv_include_columns is not null then 'include ('+csv_include_columns+')' end as include_clause
    ,case when filter_definition is not null then 'where '+filter_definition end as filter_definition
    ,case
        when is_primary_key=1 or is_unique=1 then 'alter table '+quotename([schema])+'.'+quotename(table_name)+' drop constraint '+quotename(index_name)
        when [type_desc]='PRIMARY_XML' then 'drop index '+quotename(index_name)+' on '+quotename([schema])+'.'+quotename(table_name)
        when [type_desc]='SECONDARY_XML' then 'drop index '+quotename(index_name)+' on '+quotename([schema])+'.'+quotename(table_name)
        else 'drop index '+quotename(index_name)+' on '+quotename([schema])+'.'+quotename(table_name)
    end as drop_command
from cte_index_column_names
)
insert into @sql_commands (
    ObjectSchema
	,ObjectTableName
    ,ObjectName
    ,IsPrimaryKey
    ,TypeDesc
    ,create_command
	,drop_command
)
select
	unquoted_schema
	,unquoted_table_name
	,unquoted_index_name
	,is_primary_key
	,[type_desc]
	,create_command_prefix + ' (' + csv_index_columns + ')'
	+ coalesce(' ' + secondary_xml_index_using, '')
	+ coalesce(' ' + include_clause, '')
	+ coalesce(' ' + filter_definition, '')
	as create_command
	,drop_command
from command_parts
where
   unquoted_schema = @p_schema
   and unquoted_index_name = @p_index_name
;
return
end

go


IF OBJECT_ID (N'dbo.deps_generate_create_and_drop_fk') IS NOT NULL
   DROP FUNCTION dbo.deps_generate_create_and_drop_fk
GO


create function deps_generate_create_and_drop_fk (@p_schema varchar(255), @p_fk_name varchar(255))
RETURNS @sql_commands TABLE (
    ObjectSchema VARCHAR(200)
	,ObjectTableName varchar(200)
    ,ObjectName VARCHAR(200)
    ,create_command varchar(max)
	,drop_command varchar(max)
)
as
begin

;with command_parts as (
	SELECT QUOTENAME(fk.name) AS [const_name]
		,fk.name as unquoted_constraint_name
		,QUOTENAME(schParent.name) + '.' + QUOTENAME(OBJECT_NAME(fkc.parent_object_id)) AS [parent_obj]
		,schParent.name as unquoted_parent_schema
		,OBJECT_NAME(fkc.parent_object_id) as unquoted_parent_table_name
		,STUFF((
				SELECT ',' + QUOTENAME(COL_NAME(fcP.parent_object_id, fcP.parent_column_id))
				FROM sys.foreign_key_columns AS fcP
				WHERE fcP.constraint_object_id = fk.[object_id]
				FOR XML path('')
				), 1, 1, '') AS [parent_col_csv]
		,QUOTENAME(schRef.name) + '.' + QUOTENAME(OBJECT_NAME(fkc.referenced_object_id)) AS [ref_obj]
		,STUFF((
				SELECT ',' + QUOTENAME(COL_NAME(fcR.referenced_object_id, fcR.referenced_column_id))
				FROM sys.foreign_key_columns AS fcR
				WHERE fcR.constraint_object_id = fk.[object_id]
				FOR XML path('')
				), 1, 1, '') AS [ref_col_csv]
	FROM sys.foreign_key_columns AS fkc
	INNER JOIN sys.foreign_keys AS fk ON fk.[object_id] = fkc.constraint_object_id
	INNER JOIN sys.objects AS oParent ON oParent.[object_id] = fkc.parent_object_id
	INNER JOIN sys.schemas AS schParent ON schParent.[schema_id] = oParent.[schema_id]
	INNER JOIN sys.objects AS oRef ON oRef.[object_id] = fkc.referenced_object_id
	INNER JOIN sys.schemas AS schRef ON schRef.[schema_id] = oRef.[schema_id]
	GROUP BY fkc.parent_object_id
		,fkc.referenced_object_id
		,fk.name
		,fk.[object_id]
		,schParent.name
		,schRef.name
)
insert into @sql_commands (
    ObjectSchema
	,ObjectTableName
    ,ObjectName
	,drop_command
    ,create_command
)
select
CP.unquoted_parent_schema -- schema
,CP.unquoted_parent_table_name -- table name
,CP.unquoted_constraint_name -- fk name
,'alter table ' + CP.parent_obj + ' drop constraint ' + CP.const_name as drop_command
,'alter table ' + CP.parent_obj + ' add constraint ' + CP.const_name + ' foreign key (' + CP.parent_col_csv + ') references ' + CP.ref_obj + ' (' + CP.ref_col_csv + ')' as create_command
from command_parts as CP
where CP.unquoted_parent_schema = @p_schema
and CP.unquoted_constraint_name = @p_fk_name
return
end

go


/*
The SQL command below generates DROP and CREATE commands for all PKs, FKs, and
indexes in dependency order below your specified TABLE_NAME.
It does not execute the DROP or CREATE commands; it only generates them.
I used it to change datetime2 datatypes to datetime on a database with 11 levels of dependencies.
It worked pretty well for me, but I still suggest you test it on a backup of your target database first.
You'll need to run the SELECT command twice: once to generate DROP commands, and once to generate CREATE commands.
I recommend generating/copying/pasting DROP commands, enter your dependency change
("alter table TABLE_NAME alter column DATATYPE not null"),
generating/copying/pasting CREATE commands, saving the file, all before running the script.
Step 1:
In SSMS / Query menu / Results to / Text.
In SSMS / Query menu / Query options / Results / Text / 3000 (this should be enough).
Step 2:
Replace the deps_it_depends TABLE_NAME parameter with the table containing the
dependendency (FK, PK, etc.) or datatype (int, datetime, varchar, etc.) you need to change.
Step 3:
Set the ID.iteration order to DESC if generating DROP commands.
Set the ID.iteration order to ASC if generating CREATE commands.
Step 4:
Set the case / ID.ObjectType order to DESC if generating DROP commands.
Set the case / ID.ObjectType order to ASC if generating CREATE commands.
Step 5:
Uncomment either the "create_command" or "drop_command" block.
Step 6:
Run the SELECT command.
*/
select
/*ID.ObjectPath, ID.ObjectSchema, ID.ObjectName, ID.ObjectType
, GCD.drop_command as drop_index, GCD.create_command as create_index
, GFK.drop_command as drop_fk, GFK.create_command as create_fk
*/

-- create_command
'-- ' + ID.ObjectPath + '
print ''' + cast(ID.iteration as varchar(5)) + ' / ' + replace(coalesce(GCD.create_command, GFK.create_command), '''', '''''') + '''
go
' + coalesce(GCD.create_command, GFK.create_command) + '
go

'
as create_command

/*
-- drop_command
'-- ' + ID.ObjectPath + '
print ''' + cast(ID.iteration as varchar(5)) + ' / ' + replace(coalesce(GCD.drop_command, GFK.drop_command), '''', '''''') + '''
go
' + coalesce(GCD.drop_command, GFK.drop_command) + '
go

'
as drop_command
*/
FROM dbo.deps_it_depends('dbo', 'TABLE_NAME', 1) as ID
outer apply dbo.deps_generate_create_and_drop_index(ID.ObjectSchema, ID.ObjectName) as GCD
outer apply dbo.deps_generate_create_and_drop_fk(ID.ObjectSchema, ID.ObjectName) as GFK
where (
	(GCD.ObjectSchema = ID.ObjectSchema and GCD.ObjectName = ID.ObjectName)
	or (GFK.ObjectSchema = ID.ObjectSchema and GFK.ObjectName = ID.ObjectName)
)
ORDER BY ID.iteration desc -- asc: drop order; desc: create order
,case
	when ID.ObjectType = 'NCI' then 1 -- non-clustered index
	when ID.ObjectType = 'CI' then 2 -- clustered index
	when ID.ObjectType = 'F' then 3 -- fk
end desc -- asc: drop order; desc: create order
,ID.ObjectPath

