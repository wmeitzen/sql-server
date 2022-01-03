USE DBAdmin;
GO

IF OBJECT_ID('[dbo].[DBA_CustomDBCC_CheckTableStatus]', 'U') IS NULL

CREATE TABLE [dbo].[DBA_CustomDBCC_CheckTableStatus](
	[checkTableID] [bigint] IDENTITY(1,1) NOT NULL,
	[databaseName] [nvarchar](128) NOT NULL,
	[schemaName] [nvarchar](128) NOT NULL,
	[tableName] [nvarchar](128) NOT NULL,
	[command] [nvarchar](1024) NULL,
	[procFlag] [bit] NULL,
	[startDate] [datetime] NULL,
	[endDate] [datetime] NULL,
	[elapsed_sec] [bigint] NULL,
	[elapsed_desc] [varchar](64) NULL,
	[error_number] [int] NULL,
	[error_message] [nvarchar](max) NULL
)

go

if (SELECT OBJECTPROPERTY(OBJECT_ID(N'dbo.DBA_CustomDBCC_CheckTableStatus'),'TableHasPrimaryKey')) = 0
begin
	create nonclustered index nc_DBA_CheckTableStatus on DBA_CustomDBCC_CheckTableStatus (startDate)
end

