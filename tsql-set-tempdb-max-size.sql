
set nocount on
go

DECLARE @DriveSizeGB INT          = 149 -- if windows says 149 GB, use 149 GB here - don't round up to 150 GB
        ,@FileCount  INT          = 9 -- 9 is best (8 data + 1 log)
        ,@DrivePath  VARCHAR(100) = 't:\sqltemp' -- set this in case we need to add tempdb files

-- used by script
declare @RowID      INT
        ,@FileSize   VARCHAR(10)
		,@DriveSizeMB int
		,@InitialFileSize VARCHAR(10);

/* Converts GB to MB */
set  @DriveSizeMB = @DriveSizeGB * 1024;

--print @DriveSizeMB

set @DriveSizeMB = @DriveSizeMB - (@DriveSizeMB * 0.15) -- alarm trips at 10%

/* Splits size by the files */
set  @FileSize = @DriveSizeMB / @FileCount;

set @InitialFileSize = @FileSize / @FileCount;

if right(@DrivePath, '1') <> '\'
	set @DrivePath = @DrivePath + '\'

/* Table to house requisite SQL statements that will modify the files to the standardized name, and size */
DECLARE @Command TABLE
(
    RowID    INT IDENTITY(1, 1)
    ,Command NVARCHAR(MAX)
);
INSERT INTO @Command (Command)
SELECT  'ALTER DATABASE tempdb MODIFY FILE (NAME = [' + f.name + ']'
		+ ', MAXSIZE = ' + @FileSize + ' MB);'
FROM    sys.master_files AS f
WHERE   f.database_id = DB_ID(N'tempdb');
select @RowID = count(*) from sys.master_files WHERE database_id = DB_ID(N'tempdb');

/* If there are less files than indicated in @FileCount, add missing lines as ADD FILE commands */
WHILE @RowID < @FileCount
BEGIN
	INSERT INTO @Command (Command)
	SELECT  'ALTER DATABASE tempdb ADD FILE (NAME = [temp' + CAST(@RowID AS VARCHAR) + '],' + ' FILENAME = ''' + @DrivePath + 'temp'+ CAST(@RowID AS VARCHAR)+'.mdf''' + ', SIZE = ' + @InitialFileSize + ' MB, MAXSIZE = ' + @FileSize + ' MB);'
	SET @RowID = @RowID + 1
END

/* Execute each line to process */
WHILE @RowID > 0
BEGIN
	DECLARE @WorkingSQL NVARCHAR(MAX)

	SELECT	@WorkingSQL = Command
	FROM	@Command
	WHERE	RowID = (@FileCount - @Rowid) + 1

	print @WorkingSQL
	--EXEC (@WorkingSQL)
	SET @RowID = @RowID - 1
END
