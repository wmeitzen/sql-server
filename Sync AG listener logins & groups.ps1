
<#
Copy and sync logins, groups, settings, and permissions from the primary to secondaries on an AG.

Known bugs and issues:
Unable to copy password hash if "Must change password at next login" is enabled on the primary.
#>

set-strictmode -version latest # - require variable declaration

# - define functions

# w - write to console
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

# - show errors, remove unneeded commentary
function report_error {
    param (
        $err
        ,$warning
        ,[string] $message = ""
    )
    $strWarning = ""
    if ((Get-Member -InputObject $warning -Name message) -ne $null) {
        $strWarning = $warning.message
    }
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

function install_powershell_modules {
	if (!(get-module -ListAvailable -name DBATools)) {
		w -string "DBATools powershell is missing - installing it now - it will take a moment - this should happen only once"
		try {
			Install-Module -name DBATools -Force | out-null
		} catch {
			report_error -err $_ -message "ERROR: Unable to install DBATools module."
		}
	}
	if (!(get-package -name DBATools)) {
    	try {
			Install-Package -name DBATools -Force | out-null
		} catch {
			report_error -err $_ -message "ERROR: Unable to install DBATools package."
		}
	}
}


install_powershell_modules

if (!(get-module -ListAvailable -name DBATools)) {
	w -string "DBATools powershell module is missing. Aborting."
    exit
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
            $objSecondaryReplica | Select-Object -Property *
            $strSecondaryReplica_Name = $objSecondaryReplica.Name

            # secondary replica logins
            #-SqlInstance $strSecondaryReplica_Name

            # - hard-code the port number - TEST
            if ($strSecondaryReplica_Name -eq 'SQL03\INSTANCE03') { $strSecondaryReplica_Name = $strSecondaryReplica_Name + ',50001' }

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
                    $bolPrimary_MustChangePassword = $objMatchPrimaryLogin.MustChangePassword
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
                        $bolSecondary_MustChangePassword = $objMatchSecondaryLogin.MustChangePassword
                        $bolSecondary_IsEnabled = -not $objMatchSecondaryLogin.IsDisabled
                        $bolSecondary_GrantLogin = -not $objMatchSecondaryLogin.DenyWindowsLogin

                        # - update existing logins
                        if ($strPrimary_Name -eq $strSecondary_Name) {
                            # - login names match
                            if ($strPrimary_PasswordHash -ne $strSecondary_PasswordHash) {
                                # - password hashes don't match
                                # - A HASHED password cannot be set for a login that has CHECK_POLICY turned on.
                                # - Need to disable it for the login on the destination replicas
                                #w -string "Set password policy prerequisites"
                                try {
                                    Set-DbaLogin -SqlInstance $strSecondaryReplica_Name -Login $strSecondary_Name `
                                        -PasswordPolicyEnforced:$false `
                                        -PasswordExpirationEnabled:$false `
                                        -WarningAction Stop -WarningVariable warning -ErrorAction stop -EnableException `
                                        | Out-Null
                                    $bolSecondary_PasswordPolicyEnforced = $false
                                    $bolSecondary_PasswordExpirationEnabled = $false
                                } catch {
                                    report_error -err $_ -warning $warning -message "ERROR: Prerequisite failed: Unable to enforce password policy on secondary replica '$strSecondaryReplica_Name' before changing password hash for login '$strSecondary_Name'"
                                }
                                $strSQLCommand = "alter login [$strSecondary_Name] with password = $strPrimary_PasswordHash hashed;"
                                #Write-Output "Command: $strSQLCommand$strCR"
                                #w -string "Set hashed password"
                                try {
                                    Invoke-DbaQuery -SqlInstance $strSecondaryReplica_Name -Query $strSQLCommand `
                                        -WarningAction Stop -WarningVariable warning -ErrorAction stop -EnableException
                                    w -string "Login: [$strSecondary_Name] - Copied password hash from $strPrimaryReplica_Name to $strSecondaryReplica_Name"
                                } catch {
                                    report_error -err $_ -warning $warning -message "ERROR: Unable to set password hash for login '$strSecondary_Name' on secondary replica '$strSecondaryReplica_Name'"
                                }
                            }
                            if (
                                $bolPrimary_PasswordPolicyEnforced -ne $bolSecondary_PasswordPolicyEnforced `
                                -or $bolPrimary_MustChangePassword -ne $bolSecondary_MustChangePassword `
                                -or $bolPrimary_PasswordExpirationEnabled -ne $bolSecondary_PasswordExpirationEnabled `
                                -or $strPrimary_DefaultDatabase -ne $strSecondary_DefaultDatabase `
                                -or $bolPrimary_IsEnabled -ne $bolSecondary_IsEnabled `
                                -or $bolPrimary_GrantLogin -ne $bolSecondary_GrantLogin `
                                -or $bolPrimary_PasswordPolicyEnforced -ne $bolSecondary_PasswordPolicyEnforced `
                                -or $bolPrimary_MustChangePassword -ne $bolSecondary_MustChangePassword
                                ) {
                                #w -string "bolPrimary_MustChangePassword: $bolPrimary_MustChangePassword"

                                # is login enabled?
                                if ($bolPrimary_IsEnabled -eq $true) {
                                    $Enable = @{ Enable = $true } # - enable login
                                    $Disable = @{ }
                                } else {
                                    $Enable = @{ }
                                    $Disable = @{ Disable = $true } # - disable login
                                }

                                # does login have access to the instance?
                                if ($bolPrimary_GrantLogin -eq $true) {
                                    $GrantLogin = @{ GrantLogin = $true } # - GrantLogin
                                    $DenyLogin = @{ }
                                } else {
                                    $GrantLogin = @{ }
                                    $DenyLogin = @{ DenyLogin = $true } # - DenyLogin
                                }

                                # must user change password at next login?
                                if ($bolPrimary_MustChangePassword -eq $true) {
                                    $MustChange = @{ MustChange = $true } # - MustChange
                                } else {
                                    $MustChange = @{ }
                                }
                                #w -string "Copy properties"
                                try {
                                    Set-DbaLogin -SqlInstance $strSecondaryReplica_Name -Login $strSecondary_Name `
                                        -DefaultDatabase $strPrimary_DefaultDatabase `
                                        -PasswordPolicyEnforced:$bolPrimary_PasswordPolicyEnforced `
                                        -PasswordExpirationEnabled:$bolPrimary_PasswordExpirationEnabled `
                                        @Enable @Disable @GrantLogin @DenyLogin @MustChange `
                                        -WarningAction Stop -WarningVariable warning -ErrorAction stop -EnableException `
                                        | Out-Null
                                    w -string "Login: [$strSecondary_Name] - Copied properties from $strPrimaryReplica_Name to $strSecondaryReplica_Name"
                                } catch {
                                    report_error -err $_ -warning $warning -message "ERROR: Unable to copy properties for login '$strSecondary_Name' to secondary replica '$strSecondaryReplica_Name'"
                                }
                            }
                            
                            if ($strPrimary_Language -ne $strSecondary_Language) {
                                # - default languages don't match
                                #w -string "Set default language"
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
                    Copy-DbaLogin -Source $strPrimaryReplica_Name -Destination $strSecondaryReplica_Name -Login $strNewLogins `
                        -WarningAction Stop -WarningVariable warning -ErrorAction stop -EnableException `
                        | Out-Null
                    w -string "Logins: [$strNewLogins] - Copied new logins from $strPrimaryReplica_Name to $strSecondaryReplica_Name"
                } catch {
                    report_error -err $_ -warning $warning -message "ERROR: Unable to copy logins '$objNewLogins' from primary replica '$strPrimaryReplica_Name' to secondary replica '$strSecondaryReplica_Name'"
                }
            }

        }

        # - sync login permissions from primary to secondaries
        #$strSecondaryReplicas_Name = $secondaryReplicas.Name
        #$strPrimaryLogins_Name = $primaryLogins.name
        try {
            Sync-DbaLoginPermission -Source $strPrimaryReplica_Name -Destination $strSecondaryReplica_Name -Login $strPrimaryLogins_Name `
                -WarningAction Stop -WarningVariable warning -ErrorAction stop -EnableException `
                | Out-Null
            w -string "Logins: [$strPrimaryLogins_Name] - Synced login permissions from $strPrimaryReplica_Name to $strSecondaryReplica_Name"
        } catch {
            report_error -err $_ -warning $warning -message "ERROR: Unable to sync logins '$primaryLogins' from primary replica '$strPrimaryReplica_Name' to secondary replica '$strSecondaryReplica_Name'"
        }
    }
}
