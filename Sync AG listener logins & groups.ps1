
<#
Sync logins, login settings, and login permissions on secondaries that match logins on the primary
#>

set-strictmode -version latest # - require variable declaration

# - define functions
function w {
    param (
        $string = $null
        ,$style = $null
    )
    if ($style -eq 'green') {
        write-output $string
    } elseif ($style -eq 'error') {
        write-output $string
    } elseif ($style -eq 'warning') {
        write-output $string
    } else {
        write-output $string
    }

}

function report_error {
    param (
        $err
        ,$warning
        ,[string] $message = ""
    )
    $strWarning = $warning.message
    $strWarning = $strWarning.replace('The running command stopped because the preference variable "WarningPreference" or common parameter is set to Stop', '')
    $strErr_Message = $err.Exception.Message
    $strErr_Message = $strErr_Message.replace('The running command stopped because the preference variable "WarningPreference" or common parameter is set to Stop', '')
    $strErr_ScriptStackTrace = ""
    if ((Get-Member -InputObject $err -Name ScriptStackTrace) -ne $null) {
        $strErr_ScriptStackTrace = $err.ScriptStackTrace
    }
    $strErr_PositionMessage = $err[0].InvocationInfo.PositionMessage
    $strErr_PositionMessage = $strErr_PositionMessage.replace('The running command stopped because the preference variable "WarningPreference" or common parameter is set to Stop', '')
    if ($message -ne "") { w -string $message }
    w -style 'warning' -string $strWarning
    w -style 'error' -string $strErr_Message
    #w -style 'error' -string $strErr_PositionMessage
    w -style 'error' -string $strErr_ScriptStackTrace
}

try {
    $objInstances = Find-DbaInstance -ComputerName localhost `
        -WarningAction Stop -WarningVariable warning -ErrorAction stop -EnableException
} catch {
    report_error -err $_ -warning $warning -message "ERROR: Unable to find the instance on 'localhost'. Aborting."
    exit
}

$strCR = "`r`n"

$objInstances | ForEach-Object {
    $objInstance = $_

    try {
        #
        $objAGListeners = Get-DbaAgListener -SqlInstance $objInstance `
            -WarningAction Stop -WarningVariable warning -ErrorAction stop -EnableException
    } catch {
        report_error -err $_ -warning $warning -message "ERROR: Unable to find an availability group listener on '$objInstance'. Aborting."
        exit
    }

    #$objAGListeners | Select-Object -Property *

    #exit

    $objAGListeners | ForEach-Object {
        $objAGListener = $_

        #$objAGListener | Select-Object -Property Name, InstanceName, SqlInstance
        $strAGListenerName = [string] $objAGListener.Name
        #$strAGListenerName = 'goober' # - test for failure

        try {
            $primaryReplica = Get-DbaAgReplica -SqlInstance $strAGListenerName `
                -WarningAction Stop -WarningVariable warning -ErrorAction stop -EnableException `
                | Where Role -eq Primary | Sort-Object Name -Unique
        } catch {
            report_error -err $_ -warning $warning -message "ERROR: Unable to obtain the AG primary replica on listener '$strAGListenerName'. Aborting."
            exit
        }

        try {
            $secondaryReplicas = Get-DbaAgReplica -SqlInstance $strAGListenerName `
                -WarningAction Stop -WarningVariable warning -ErrorAction stop -EnableException `
                | Where Role -eq Secondary | Sort-Object Name -Unique
        } catch {
            report_error -err $_ -warning $warning -message "ERROR: Unable to obtain listener '$strAGListenerName' AG secondary replicas"
            exit
        }

        #$secondaryReplicas | Select-Object -Property *

        $strPrimaryReplica_Name = $primaryReplica.Name

        # primary replica logins
        try {
            $primaryLogins = Get-DbaLogin -Detailed -SqlInstance $primaryReplica.Name -ExcludeFilter '##*','NT *','BUILTIN*', '*$' `
                -WarningAction Stop -WarningVariable warning -ErrorAction stop -EnableException
        } catch {
            report_error -err $_ -warning $warning -message "ERROR: Unable to retrieve logins from primary replica '$primaryReplica'. Aborting."
            exit
        }

        try {
            $primaryReplicaServerRoles = Get-DbaServerRole -SqlInstance $primaryReplica.Name `
                -WarningAction Stop -WarningVariable warning -ErrorAction stop -EnableException
        } catch {
            report_error -err $_ -warning $warning -message "ERROR: Unable to retrieve server roles from primary replica '$primaryReplica'. Aborting."
            exit
        }
        #$primaryReplicaServerRoles | Select-Object -Property *

        #$bolPasswordsMatch = $true

        $secondaryReplicas | ForEach-Object {
            $objSecondaryReplica = $_
            $strSecondaryReplica_Name = $objSecondaryReplica.Name

            # secondary replica logins
            try {
                $secondaryLogins = Get-DbaLogin -Detailed -SqlInstance $strSecondaryReplica_Name -ExcludeFilter '##*','NT *','BUILTIN*', '*$' `
                    -WarningAction Stop -WarningVariable warning -ErrorAction stop -EnableException
            } catch {
                report_error -err $_ -warning $warning -message "ERROR: Unable to retrieve logins from secondary replica '$strSecondaryReplica_Name'. Aborting."
                exit
            }

            try {
                $secondaryReplicaServerRoles = Get-DbaServerRole -SqlInstance $strSecondaryReplica_Name `
                    -WarningAction Stop -WarningVariable warning -ErrorAction stop -EnableException
            } catch {
                report_error -err $_ -warning $warning -message "ERROR: Unable to retrieve server roles from secondary replica '$strSecondaryReplica_Name'. Aborting."
                exit
            }
            #$secondaryReplicaServerRoles | Select-Object -Property *

            # - sync login properties from primary to secondaries
            $objMatchPrimaryLogins = $primaryLogins | Where-Object Name -in ($secondaryLogins.Name)
            $objMatchSecondaryLogins = $secondaryLogins | Where-Object Name -in ($primaryLogins.Name)
            if ($objMatchPrimaryLogins) {
                $objMatchPrimaryLogins | ForEach-Object {
                    $objMatchPrimaryLogin = $_
                    #$objMatchPrimaryLogin | Select-Object -Property Name, PasswordHash, SID, DefaultDatabase, Language, PasswordExpirationEnabled
                    #if ($objMatchPrimaryLogin.Name -eq "test") { # - show info for a test login
                        #$objMatchPrimaryLogin | Select-Object -Property *
                    #}
                    $strPrimary_Name = $objMatchPrimaryLogin.Name
                    $strPrimary_PasswordHash = $objMatchPrimaryLogin.PasswordHash
                    $bolPrimary_PasswordPolicyEnforced = $objMatchPrimaryLogin.PasswordPolicyEnforced
                    $strPrimary_DefaultDatabase = $objMatchPrimaryLogin.DefaultDatabase
                    $strPrimary_Language = $objMatchPrimaryLogin.Language
                    $bolPrimary_PasswordExpirationEnabled = $objMatchPrimaryLogin.PasswordExpirationEnabled
                    $bolPrimary_IsEnabled = -not $objMatchPrimaryLogin.IsDisabled
                    $bolPrimary_GrantLogin = -not $objMatchPrimaryLogin.DenyWindowsLogin

                    $objMatchSecondaryLogins | ForEach-Object {
                        $objMatchSecondaryLogin = $_
                        $strSecondary_Name = $objMatchSecondaryLogin.Name
                        $strSecondary_PasswordHash = $objMatchSecondaryLogin.PasswordHash
                        $bolSecondary_PasswordPolicyEnforced = $objMatchSecondaryLogin.PasswordPolicyEnforced
                        $strSecondary_DefaultDatabase = $objMatchSecondaryLogin.DefaultDatabase
                        $strSecondary_Language = $objMatchSecondaryLogin.Language
                        $bolSecondary_PasswordExpirationEnabled = $objMatchSecondaryLogin.PasswordExpirationEnabled
                        $bolSecondary_IsEnabled = -not $objMatchSecondaryLogin.IsDisabled
                        $bolSecondary_GrantLogin = -not $objMatchSecondaryLogin.DenyWindowsLogin

                        # - update existing logins
                        if ($strPrimary_Name -eq $strSecondary_Name) {
                            # - login names match
                            if ($strPrimary_PasswordHash -ne $strSecondary_PasswordHash -and $bolPrimary_PasswordPolicyEnforced -eq $false -and $bolSecondary_PasswordPolicyEnforced -eq $false) {
                                # - password hashes don't match
                                $strSQLCommand = "alter login [$strSecondary_Name] with password = $strPrimary_PasswordHash hashed;"
                                #Write-Output "Command: $strSQLCommand$strCR"
                                try {
                                    Invoke-DbaQuery -SqlInstance $strSecondaryReplica_Name -Query $strSQLCommand `
                                        -WarningAction Stop -WarningVariable warning -ErrorAction stop -EnableException
                                    w -string "Login: [$strSecondary_Name] - Copied password hash from $strPrimaryReplica_Name to $strSecondaryReplica_Name"
                                } catch {
                                    report_error -err $_ -warning $warning -message "ERROR: Unable to set password hash for login '$strSecondary_Name' on secondary replica '$strSecondaryReplica_Name'"
                                }
                            }
                            if ($bolPrimary_PasswordPolicyEnforced -ne $bolSecondary_PasswordPolicyEnforced) {
                                # - password policies don't match
                                #w -string "PasswordPolicyEnforced"
                                try {
                                    set-dbalogin -SqlInstance "$strSecondaryReplica_Name" -Login $strSecondary_Name -PasswordPolicyEnforced:$bolPrimary_PasswordPolicyEnforced `
                                        -WarningAction Stop -WarningVariable warning -ErrorAction stop -EnableException
                                    w -string "Login: [$strSecondary_Name] - Copied PasswordPolicyEnforced from $strPrimaryReplica_Name to $strSecondaryReplica_Name"
                                } catch {
                                    report_error -err $_ -warning $warning -message "ERROR: Unable to set password policy for login '$strSecondary_Name' on secondary replica '$strSecondaryReplica_Name'"
                                }
                            }
                            if ($strPrimary_DefaultDatabase -ne $strSecondary_DefaultDatabase) {
                                # - default databases don't match
                                #w -string "Default database: $strSecondary_DefaultDatabase -> $strPrimary_DefaultDatabase"
                                try {
                                    set-dbalogin -SqlInstance $strSecondaryReplica_Name -Login $strSecondary_Name -DefaultDatabase $strPrimary_DefaultDatabase `
                                        -WarningAction Stop -WarningVariable warning -ErrorAction stop -EnableException
                                    w -string "Login: [$strSecondary_Name] - Copied default database setting from $strPrimaryReplica_Name to $strSecondaryReplica_Name"
                                } catch {
                                    report_error -err $_ -warning $warning -message "ERROR: Unable to set default database to '$strPrimary_DefaultDatabase' for login '$strSecondary_Name' on secondary replica '$strSecondaryReplica_Name'"
                                }
                            }
                            if ($strPrimary_Language -ne $strSecondary_Language) {
                                # - default languages don't match
                                #w -string "Default language"
                                $strSQLCommand = "alter login [$strSecondary_Name] with default_language = [$strPrimary_Language]; -- was [$strSecondary_Language]"
                                #Write-Output "Command: $strSQLCommand$strCR"
                                try {
                                    Invoke-DbaQuery -SqlInstance $strSecondaryReplica_Name -Query $strSQLCommand `
                                        -WarningAction Stop -WarningVariable warning -ErrorAction stop -EnableException
                                    w -string "Login: [$strSecondary_Name] - Copied default language setting from $strPrimaryReplica_Name to $strSecondaryReplica_Name"
                                } catch {
                                    report_error -err $_ -warning $warning -message "ERROR: Unable to set default language for login '$strSecondary_Name' on secondary replica '$strSecondaryReplica_Name'"
                                }
                            }
                            if ($bolPrimary_PasswordExpirationEnabled -ne $bolSecondary_PasswordExpirationEnabled) {
                                # - password expiration enabled settings don't match
                                #w -string "Password expiration enabled"
                                try {
                                    set-dbalogin -SqlInstance $strSecondaryReplica_Name -Login $strSecondary_Name -PasswordExpirationEnabled:$bolPrimary_PasswordExpirationEnabled `
                                        -WarningAction Stop -WarningVariable warning -ErrorAction stop -EnableException
                                    w -string "Login: [$strSecondary_Name] - Copied default password expiration enabled setting from $strPrimaryReplica_Name to $strSecondaryReplica_Name"
                                } catch {
                                    report_error -err $_ -warning $warning -message "ERROR: Unable to set password expiration enabled for login '$strSecondary_Name' on secondary replica '$strSecondaryReplica_Name'"
                                }
                            }
                            if ($bolPrimary_IsEnabled -ne $bolSecondary_IsEnabled) {
                                # - login enabled or disabled doesn't match
                                if ($bolPrimary_IsEnabled -eq $true) {
                                    #w -string "Enable login"
                                    try {
                                        set-dbalogin -SqlInstance $strSecondaryReplica_Name -Login $strSecondary_Name -Enable `
                                            -WarningAction Stop -WarningVariable warning -ErrorAction stop -EnableException
                                        w -string "Login: [$strSecondary_Name] - Copied Enable Login setting from $strPrimaryReplica_Name to $strSecondaryReplica_Name"
                                    } catch {
                                        report_error -err $_ -warning $warning -message "ERROR: Unable to enable login '$strSecondary_Name' on secondary replica '$strSecondaryReplica_Name'"
                                    }
                                } else {
                                    w -string "Disable login"
                                    try {
                                        set-dbalogin -SqlInstance $strSecondaryReplica_Name -Login $strSecondary_Name -Disable `
                                            -WarningAction Stop -WarningVariable warning -ErrorAction stop -EnableException
                                        w -string "Login: [$strSecondary_Name] - Copied Disable Login setting from $strPrimaryReplica_Name to $strSecondaryReplica_Name"
                                    } catch {
                                        report_error -err $_ -warning $warning -message "ERROR: Unable to disable login '$strSecondary_Name' on secondary replica '$strSecondaryReplica_Name'"
                                    }
                                }
                            }
                            if ($bolPrimary_GrantLogin -ne $bolSecondary_GrantLogin) {
                                # - login enabled or disabled doesn't match
                                if ($bolPrimary_GrantLogin -eq $true) {
                                    w -string "Grant login permissions to instance"
                                    try {
                                        set-dbalogin -SqlInstance $strSecondaryReplica_Name -Login $strSecondary_Name -GrantLogin `
                                            -WarningAction Stop -WarningVariable warning -ErrorAction stop -EnableException
                                        w -string "Login: [$strSecondary_Name] - Copied Grant Login to Instance setting from $strPrimaryReplica_Name to $strSecondaryReplica_Name"
                                    } catch {
                                        report_error -err $_ -warning $warning -message "ERROR: Unable to grant login '$strSecondary_Name' access to instance on secondary replica '$strSecondaryReplica_Name'"
                                    }
                                } else {
                                    w -string "Revoke login permissions from instance"
                                    try {
                                        set-dbalogin -SqlInstance $strSecondaryReplica_Name -Login $strSecondary_Name -DenyLogin `
                                            -WarningAction Stop -WarningVariable warning -ErrorAction stop -EnableException
                                        w -string "Login: [$strSecondary_Name] - Copied Deny Login to Instance setting from $strPrimaryReplica_Name to $strSecondaryReplica_Name"
                                    } catch {
                                        report_error -err $_ -warning $warning -message "ERROR: Unable to deny login '$strSecondary_Name' access to instance on secondary replica '$strSecondaryReplica_Name'"
                                    }
                                }
                            }

                        }
                    }
                }
            }

            # - copy new logins
            $objNewLogins = $primaryLogins | Where-Object Name -notin ($secondaryLogins.Name)
            if ($objNewLogins) {
                #w -string "Copying new logins"
                try {
                    #-Login ($objNewLogins.Name)
                    $strNewLogins = $objNewLogins.Name
                    Copy-DbaLogin -Source $strPrimaryReplica_Name -Destination $strSecondaryReplica_Name -Login $objNewLogins.Name `
                        -WarningAction Stop -WarningVariable warning -ErrorAction stop -EnableException
                    w -string "Logins: [$strNewLogins] - Copied new logins from $strPrimaryReplica_Name to $strSecondaryReplica_Name"
                } catch {
                    report_error -err $_ -warning $warning -message "ERROR: Unable to copy logins '$objNewLogins' from primary replica '$strPrimaryReplica_Name' to secondary replica '$strSecondaryReplica_Name'"
                }
            }

        }

        # - sync logins from primary to secondaries
        try {
            # -Login $primaryLogins.name
            # -Destination $secondaryReplicas.Name
            $strSecondaryReplicas_Name = $secondaryReplicas.Name
            $strPrimaryLogins_Name = $primaryLogins.name
            Sync-DbaLoginPermission -Source $strPrimaryReplica_Name -Destination $strSecondaryReplicas_Name -Login $strPrimaryLogins_Name `
                -WarningAction Stop -WarningVariable warning -ErrorAction stop -EnableException `
                | Out-Null
            w -string "Logins: [$strPrimaryLogins_Name] - Synced login permissions from $strPrimaryReplica_Name to $strSecondaryReplica_Name"
        } catch {
            report_error -err $_ -warning $warning -message "ERROR: Unable to sync logins '$primaryLogins' from primary replica '$strPrimaryReplica_Name' to secondary replica '$strSecondaryReplica_Name'"
        }
    }
}

