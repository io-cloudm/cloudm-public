function Retry {
    [CmdletBinding()]
    param (
        [parameter(Mandatory, ValueFromPipeline)] 
        [ValidateNotNullOrEmpty()]
        [scriptblock] $scriptBlock,
        [ValidateNotNullOrEmpty()]
        [string] $context,
        [int] $retryCount = 10,
        [int] $timeoutInSecs = 30,
        [bool] $throw = $true

    )
        
    process {
        $attempts = 1
        $lastRetryException = $null
        do {
            try {
                Invoke-Command -ScriptBlock $ScriptBlock -OutVariable Result
                Write-Host "$context executed successfully"              
                break;
            }
            catch {
                if ($attempts -le $retryCount) {
                    Write-Host "[$attempts/$retryCount] Failed to execute command '$context'. Retrying in $TimeoutInSecs seconds..." -ForegroundColor Yellow
                    Start-Sleep -Seconds $TimeoutInSecs
                    $attempts++
                }
                if ($attempts -eq $retryCount) {
                    Write-Host "Failed to execute command '$context'. Total retry attempts: $retryCount" -ForegroundColor Red
                    $lastRetryException = $_.exception.message
                }
            }
        } while ($attempts -le $retryCount)

        if ($attempts -ge $retryCount -and $throw -eq $true) {
            Write-Host "[Error Message] for '$context'. The message was: $($lastRetryException) `n" -ForegroundColor Red
            throw $lastRetryException
        }
    }
}

function CheckIfErrors ([System.Collections.ArrayList]$errorToProcess) {
    $message = $null
    if ($errorToProcess.Count -ge 1) {
        foreach ($error in $errorToProcess) {
            if ($error.Exception.Message) {
                $message = $error.Exception.Message
                Write-Host "The message was: $($message)" -ForegroundColor Red
                break
            }
        }
        
        $errorToProcess.Clear()
        if ($message) {
            throw($message)
        }
    }
}
Export-ModuleMember -Function Retry
Export-ModuleMember -Function CheckIfErrors
