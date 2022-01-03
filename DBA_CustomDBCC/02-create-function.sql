USE DBAdmin;
GO

IF OBJECT_ID('dbo.DBA_CustomDBCC_CommaStringTable', 'TF') IS NULL
 EXEC('CREATE FUNCTION dbo.DBA_CustomDBCC_CommaStringTable (@p1 INT) RETURNS @t TABLE (id INT) AS BEGIN INSERT @t SELECT 0 RETURN END');
GO

ALTER FUNCTION [dbo].[DBA_CustomDBCC_CommaStringTable] ( @StringInput VARCHAR(MAX) )
RETURNS @temp TABLE ( [Value] VARCHAR(128) )
AS
BEGIN
 DECLARE @String    VARCHAR(128);

 -- Scrub the input string if necessary
 IF CHARINDEX(' , ', @StringInput) <> 0
  SET @StringInput = REPLACE(@StringInput, ' , ', ',');
  
 IF CHARINDEX(', ', @StringInput) <> 0
  SET @StringInput = REPLACE(@StringInput, ', ', ',');
  
 IF CHARINDEX(' ,', @StringInput) <> 0
  SET @StringInput = REPLACE(@StringInput, ' ,', ',');

 IF LEFT(@StringInput, 1) = ','
  SET @StringInput = SUBSTRING(@StringInput, 2, (LEN(@StringInput) - 1));

 IF RIGHT(@StringInput, 1) = ','
  SET @StringInput = SUBSTRING(@StringInput, 1, (LEN(@StringInput) - 1));

 -- Populate the table variable
 WHILE LEN(@StringInput) > 0
 BEGIN
  SET @String = LEFT(@StringInput, ISNULL(NULLIF(CHARINDEX(',', @StringInput) - 1, -1), LEN(@StringInput)));

  SET @StringInput = SUBSTRING(@StringInput, ISNULL(NULLIF(CHARINDEX(',', @StringInput), 0), LEN(@StringInput)) + 1, LEN(@StringInput));

  INSERT INTO @temp ( [Value] ) VALUES ( @String );
 END

 -- One more pass to remove extraneous spaces
 UPDATE @temp SET [Value] = LTRIM(RTRIM([Value]));

 RETURN;
END

GO
