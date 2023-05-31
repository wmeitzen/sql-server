if exists(select * from sys.tables where name = 'DBA_CustomDBCC_CheckTableStatus')
	DROP TABLE [dbo].[DBA_CustomDBCC_CheckTableStatus]
GO

SET ANSI_NULLS ON
GO

SET QUOTED_IDENTIFIER ON
GO

CREATE TABLE [dbo].[DBA_CustomDBCC_CheckTableStatus](
	[checkTableID] [bigint] IDENTITY(1,1) NOT NULL,
	[databaseName] [nvarchar](128) NOT NULL,
	[schemaName] [nvarchar](128) NOT NULL,
	[tableName] [nvarchar](128) NOT NULL,
	[command] [nvarchar](1024) NULL,
	[objectWasChecked] [bit] NULL,
	[startDate] [datetime] NULL,
	[endDate] [datetime] NULL,
	[elapsed_sec] [bigint] NULL,
	[elapsed_desc] [varchar](64) NULL,
	[error_number] [int] NULL,
	[error_message] [nvarchar](max) NULL
)
GO

CREATE CLUSTERED INDEX [IX_DBA_CustomDBCC_CheckTableStatus] ON [dbo].[DBA_CustomDBCC_CheckTableStatus] (
	[checkTableID] ASC
)
GO
