#Requires -Modules Az.Accounts, Az.Resources
#Requires -Version 7

function Restore-Workspaces {
    [CmdletBinding()]

    param(
        [string]$AdminUpn=$null,
        [Parameter(Mandatory=$true)]
        [string]$WorkspaceIdsFilePath
    )

    $ErrorActionPreference = 'Stop'

    Set-StrictMode -Version Latest

    if ($WorkspaceIdsFilePath -ne $null -and (Test-Path -Path $WorkspaceIdsFilePath)) {
        $workspaceIds = Get-Content -Path $WorkspaceIdsFilePath
    }
    else {
        Write-Error "Workspace IDs file path is not provided or invalid. Please try again."
        return
    }

    if (($null -eq (Get-AzContext)) -or ((Get-AzContext).Account -like "MSI@*")) {
        Connect-AzAccount -UseDeviceAuthentication | Out-Null
    }

    if (-not $AdminUpn) { $AdminUpn = (Get-AzContext).Account.Id }

    $adminOid = (Get-AzADUser -UserPrincipalName $AdminUpn).Id

    $secureFabricToken = (Get-AzAccessToken -ResourceUrl 'https://api.fabric.microsoft.com').Token
    $ssPtr = [System.Runtime.InteropServices.Marshal]::SecureStringToBSTR($secureFabricToken)
    $plainTextFabricToken = [System.Runtime.InteropServices.Marshal]::PtrToStringBSTR($ssPtr)

    $h = @{ Authorization = "Bearer $plainTextFabricToken"; 'Content-Type' = 'application/json' }

    try {
        foreach ($wsId in $workspaceIds) {
            $numGetWorkspaceRetries = 0

            while ($true) {
                if ($numGetWorkspaceRetries -gt 5) {
                    Write-Warning "Maximum retry attempts reached. Skipping workspace $wsId."
                    $getSucceeded = $false
                    break
                }

                try {
                    $workspaceStatus = Invoke-RestMethod -Method GET -Uri "https://api.fabric.microsoft.com/v1/admin/workspaces/$wsId" -Headers $h
                    $getSucceeded = $true
                    break
                }
                catch {
                    $getSucceeded = $false
                    $numGetWorkspaceRetries++
                    $error_returned = $_.Exception.Response.StatusCode

                    if ($error_returned -ne 429) {
                        Write-Warning "Get Workspace API failed with error code ($error_returned)"
                        break
                    }
                    else {
                        $retryAfter = $_.Exception.Response.Headers.RetryAfter
                        if ($null -ne $retryAfter -and $null -ne $retryAfter.Delta) {
                            $retryAfterSeconds = [Math]::Ceiling($retryAfter.Delta.TotalSeconds)
                        }
                        else {
                            $retryAfterSeconds = 60
                        }

                        Write-Host "Throttled, waiting $retryAfterSeconds seconds before retrying to get workspace status again"
                        Start-Sleep -Seconds $retryAfterSeconds
                        continue
                    }
                }
            }

            if ($getSucceeded -eq $false) {
                continue
            }
            
            $workspaceDisplayName = $workspaceStatus.name
            $workspaceState = $workspaceStatus.state

            $intervalBetweenRequestsMilliseconds = 6000 # 1min/10 requests = 60s/10 requests = 6s/request = 6000ms/request

            if ($workspaceState -eq 'Deleted') {
                $body = @{ newWorkspaceAdminPrincipal = @{ id = $adminOid; type = 'User' }; 'newWorkspaceName' = "RestoredWorkspace_$($workspaceDisplayName)_$wsId" } | ConvertTo-Json -Depth 5
                
                # max 10 requests/min
                $numRestoreRetries = 0
                while ($true) {
                    if ($numRestoreRetries -gt 5) {
                        Write-Warning "Maximum retry attempts reached. Skipping workspace $wsId."
                        break
                    }
                    try {
                        # max 10 requests/min
                        Start-Sleep -Milliseconds $intervalBetweenRequestsMilliseconds
                        Invoke-RestMethod -Method POST -Uri "https://api.fabric.microsoft.com/v1/admin/workspaces/$wsId/restore" -Headers $h -Body $body
                        break
                    }
                    catch {
                        $error_returned = $_.Exception.Response.StatusCode
                        $numRestoreRetries++

                        if ($error_returned -ne 429) {
                            Write-Warning "Restore Workspace API failed with error code ($error_returned)"
                            break
                        }

                        $retryAfter = $_.Exception.Response.Headers.RetryAfter
                        if ($null -ne $retryAfter -and $null -ne $retryAfter.Delta) {
                            $retryAfterSeconds = [Math]::Ceiling($retryAfter.Delta.TotalSeconds)
                        }
                        else {
                            $retryAfterSeconds = 60
                        }

                        Write-Host "Throttled, waiting $retryAfterSeconds seconds before retrying to restore workspace again"
                        Start-Sleep -Seconds $retryAfterSeconds
                        continue
                    }
                }
                Write-Host "Restored inactive workspace, new workspace name: RestoredWorkspace_$($workspaceDisplayName)_$wsId"
            }
            elseif ($workspaceState -eq 'Removing') {
                Write-Host "Workspace $wsId is in 'Removing' state, cannot reliably restore workspace as it is in the process of being permanently deleted"
            }
        }
    }
    finally {
        $plainTextFabricToken = [System.Runtime.InteropServices.Marshal]::ZeroFreeBSTR($ssPtr)
        $h = $null
    }
}