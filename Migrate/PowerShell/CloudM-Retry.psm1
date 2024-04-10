function RetryCommand {
    [CmdletBinding()]
    param (
        [parameter(Mandatory, ValueFromPipeline)] 
        [ValidateNotNullOrEmpty()]
        [scriptblock] $ScriptBlock,
        [ValidateNotNullOrEmpty()]
        [string] $Context,
        [int] $RetryCount = 10,
        [int] $TimeoutInSeconds = 30,
        [System.Management.Automation.SwitchParameter] $OnFinalExceptionContinue
    )
        
    process {
        $attempts = 1
        $lastRetryException = $null
        do {
            try {
                Invoke-Command -ScriptBlock $ScriptBlock -OutVariable Result
                break;
            }
            catch {
                if ($attempts -le $retryCount) {
                    Write-Host "[$attempts/$retryCount] Failed to execute command '$context'. Retrying in $timeoutInSeconds seconds..." -ForegroundColor Yellow
                    Start-Sleep -Seconds $timeoutInSeconds
                    $attempts++
                }
                if ($attempts -eq $retryCount) {
                    Write-Host "Failed to execute command '$context'. Total retry attempts: $retryCount" -ForegroundColor Red
                    $lastRetryException = $_.exception.message
                }
            }
        } while ($attempts -le $retryCount)

        if ($attempts -ge $retryCount -and $OnFinalExceptionContinue -eq $false) {
            Write-Host "[Error Message] for '$context'. The message was: $($lastRetryException) `n" -ForegroundColor Red
            throw $lastRetryException
        }
    }
}

function CheckErrors {
    [CmdletBinding()]
    param (
        [System.Collections.ArrayList]$ErrorToProcess
    )
    process {
        $message = $null
        if ($errorToProcess.Count -ge 1) {
            foreach ($error in $errorToProcess) {
                if ($error.Exception.Message) {
                    $message = $error.Exception.Message
                    break
                }
            }
        
            $errorToProcess.Clear()
            if ($message) {
                throw($message)
            }
        }
    }
}
Export-ModuleMember -Function RetryCommand
Export-ModuleMember -Function CheckErrors