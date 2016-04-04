return

#region Notes
# 'Native' completers are usually used for external, non-PowerShell commands, such
# as net.exe, ipconfig.exe, etc. You'll notice immediately that the completer
# scriptblock doesn't get the same parameters passed to it as a 'normal' completer.
# 
# Three parameters are passed to a native completer:
#  - $wordToComplete
#  - $commandAst
#  - $cursorPosition
#
# Below, we'll show what's passed like we did in the argument completer intro demo 
#
#endregion

#region Set up debug log
$ArgCompleterDebugLog = "$env:temp\argcompleter_debug.log"
New-Item $ArgCompleterDebugLog -Force -ItemType File
Start-Process powershell "Get-Content '$ArgCompleterDebugLog' -Wait"

$OutFileParams = @{
    FilePath = $ArgCompleterDebugLog
    Append = $true
}
#endregion

#region Native completer for ipconfig.exe
# Set up a completer for a native command that will write to the debug log:
# This completer will also provide some simple completion results:
Register-ArgumentCompleter -CommandName ipconfig.exe -Native -ScriptBlock {

    $commandAst = $args[1]

    "" | Out-File @OutFileParams
    '-' * 50 | Out-File @OutFileParams
    'Native parameter completer' | Out-File @OutFileParams
    "" | Out-File @OutFileParams
    'PS> {0}' -f $commandAst.ToString() | Out-File @OutFileParams

    $i = 0
    $args | Foreach-Object {
        "`nArgument ${i}:" | Out-File @OutFileParams
        "  -> Type: $($_.GetType())" | out-file @OutFileParams
        "  -> Value: $($_ | out-string | % TrimEnd)" | out-file @OutFileParams
        $i++
    }
    '-' * 50 | Out-File @OutFileParams
    "" | Out-File @OutFileParams

    $wordToComplete = $args[0]
    $ElementCount = $commandAst.CommandElements.Count

    if ([string]::IsNullOrEmpty($wordToComplete)) { $ElementCount++ }

    if ($ElementCount -eq 2) {
        echo all, renew, release, allcompartments, ? | where { "/$_" -like "*${wordToComplete}*" } | ForEach-Object {
            New-Object System.Management.Automation.CompletionResult "/$_", "/$_", ParameterValue, $_
        }
    }
    elseif ($ElementCount -eq 3) {
        $option1 = $commandAst.CommandElements[1].ToString()

        switch ($option1) {
            '/allcompartments' {
                New-Object System.Management.Automation.CompletionResult '/all', '/all', ParameterValue, 'all'
            }

            { $_ -in '/renew', '/release' } {
                New-Object System.Management.Automation.CompletionResult '/all', 'LOOKUP HERE', ParameterValue, 'all'
            }
        }
    }

}

# Notice that you have to use ipconfig.exe since that's what was registered. ipconfig
# isn't enough. The command will be called with the shorter ipconfig, but the completer
# won't get invoked. If you want the completer to work for both 'ipconfig.exe' and
# 'ipconfig', you'll have to treat each as a separate command do two registrations.

#endregion
