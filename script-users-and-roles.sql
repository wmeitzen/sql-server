
set nocount on
go

use USER_DATABASE_NAME
go

select 'use [' + db_name() + ']
go
'
SELECT/*    roles.principal_id                            AS RolePrincipalID
    ,    roles.name                                    AS RolePrincipalName
    ,    database_role_members.member_principal_id    AS MemberPrincipalID
    ,    members.name                                AS MemberPrincipalName
,*/
--roles.*
--,
-- Step 1: recreate users in database
'drop USER [' + members.name + ']
GO
CREATE USER [' + members.name + '] FOR LOGIN [' + members.name + ']
GO
'
/*
-- Step 2: add roles to users
'ALTER ROLE [' + roles.name + '] ADD MEMBER [' + members.name + '];
go
'
*/
FROM sys.database_role_members AS database_role_members  
JOIN sys.database_principals AS roles ON database_role_members.role_principal_id = roles.principal_id  
JOIN sys.database_principals AS members ON database_role_members.member_principal_id = members.principal_id
where members.name not in ('dbo')
--and roles.name like 'db[_]%'
order by members.name
;  
GO
