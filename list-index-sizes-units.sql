SELECT top 10
tn.[name] AS [Table name], ix.[name] AS [Index name]
,SUM(sz.[used_page_count]) * 8192 as [Index size (bytes)]
,case
                when SUM(sz.[used_page_count]) * 8192 >= 15.0 * POWER(CAST(10 AS BIGINT), 12) then format(SUM(sz.[used_page_count]) * 8192. / power(CAST(10 AS BIGINT), 12), 'N0') + ' TB'
                when SUM(sz.[used_page_count]) * 8192 >= 1.0 * POWER(CAST(10 AS BIGINT), 12) AND SUM(sz.[used_page_count]) * 8192. < 15.0 * power(CAST(10 AS BIGINT), 12) then format(SUM(sz.[used_page_count]) * 8192. / power(CAST(10 AS BIGINT), 12), 'N1') + ' TB'
                when SUM(sz.[used_page_count]) * 8192 >= 15.0 * POWER(10, 9) then format(SUM(sz.[used_page_count]) * 8192. / power(10, 9), 'N0') + ' GB'
                when SUM(sz.[used_page_count]) * 8192 >= 1.0 * POWER(10, 9) AND SUM(sz.[used_page_count]) * 8192. < 15.0 * power(10, 9) then format(SUM(sz.[used_page_count]) * 8192. / power(10, 9), 'N1') + ' GB'
                when SUM(sz.[used_page_count]) * 8192 >= 15.0 * power(10, 6) then format(SUM(sz.[used_page_count]) * 8192. / power(10, 6), 'N0') + ' MB'
                when SUM(sz.[used_page_count]) * 8192 >= 1.0 * POWER(10, 6) AND SUM(sz.[used_page_count]) * 8192. < 15.0 * power(10, 6) then format(SUM(sz.[used_page_count]) * 8192. / power(10, 6), 'N1') + ' MB'
                else format(SUM(sz.[used_page_count]) * 8192. / power(10, 3), 'N0') + ' kb'
end as [Index Size]
FROM sys.dm_db_partition_stats AS sz
INNER JOIN sys.indexes AS ix ON sz.[object_id] = ix.[object_id] AND sz.[index_id] = ix.[index_id]
INNER JOIN sys.tables tn ON tn.[object_id] = ix.[object_id]
GROUP BY tn.[name], ix.[name]
order by SUM(sz.[used_page_count]) DESC
