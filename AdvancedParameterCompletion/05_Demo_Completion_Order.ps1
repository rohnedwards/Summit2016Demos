return

#region Precedence for argument completers:
#
#  1. ValidateSet/Enumeration
#  2. Normal argument completer registered with command and parameter names
#       2a. Lookup is performed for command/parameter name combo
#       2b. If combo isn't found, lookup is performed with just parameter name
#  3. [ArgumentCompleter({})] attribute
#  4. Hardcoded command completion behavior, e.g., Get-Command -Noun, -Name, etc
#  5. Native argument completer registered with command name
#  6. If no completions still provided, path completion is returned
#
#endregion

# In just a minute, TabExpansion2 is going to be setup to log all activity. That's going
# to affect performance for you whole session, so when you're done with the demo, either
# run this command to revert TabExpansion2 back to its original state (which is captured
# just before the function is modified), or close your PS session and start a new one
New-Item function:\TabExpansion2 -Value $TabExpansion2 -Force

#region Set up log and modified TabExpansion2 function
$ArgCompleterDebugLog = "$env:temp\argcompleter_debug.log"
New-Item $ArgCompleterDebugLog -Force -ItemType File
Start-Process powershell "Get-Content '$ArgCompleterDebugLog' -Wait"

$OutFileParams = @{
    FilePath = $ArgCompleterDebugLog
    Append = $true
}

# Save original for later
$TabExpansion2 = Get-Command TabExpansion2 | select -ExpandProperty Definition

function TabExpansion2 {

    <# Options include:
         RelativeFilePaths - [bool]
             Always resolve file paths using Resolve-Path -Relative.
             The default is to use some heuristics to guess if relative or absolute is better.

       To customize your own custom options, pass a hashtable to CompleteInput, e.g.
             return [System.Management.Automation.CommandCompletion]::CompleteInput($inputScript, $cursorColumn,
                 @{ RelativeFilePaths=$false } 
    #>

    [CmdletBinding(DefaultParameterSetName = 'ScriptInputSet')]
    Param(
        [Parameter(ParameterSetName = 'ScriptInputSet', Mandatory = $true, Position = 0)]
        [string] $inputScript,
    
        [Parameter(ParameterSetName = 'ScriptInputSet', Mandatory = $true, Position = 1)]
        [int] $cursorColumn,

        [Parameter(ParameterSetName = 'AstInputSet', Mandatory = $true, Position = 0)]
        [System.Management.Automation.Language.Ast] $ast,

        [Parameter(ParameterSetName = 'AstInputSet', Mandatory = $true, Position = 1)]
        [System.Management.Automation.Language.Token[]] $tokens,

        [Parameter(ParameterSetName = 'AstInputSet', Mandatory = $true, Position = 2)]
        [System.Management.Automation.Language.IScriptPosition] $positionOfCursor,
    
        [Parameter(ParameterSetName = 'ScriptInputSet', Position = 2)]
        [Parameter(ParameterSetName = 'AstInputSet', Position = 3)]
        [Hashtable] $options = $null
    )

    End
    {

        '' | Out-File @OutFileParams
        '-' * 50 | Out-File @OutFileParams
        "TabExpansion2 ($($PSCmdlet.ParameterSetName) ParameterSet)" | Out-File @OutFileParams

        'Bound parameters:' | Out-File @OutFileParams
        foreach ($Param in $PSBoundParameters.GetEnumerator()) {
            '  -> {0} = {1}' -f $Param.Key, $Param.Value | Out-File @OutFileParams
        }
        '-' * 50 | Out-File @OutFileParams
        '' | Out-File @OutFileParams

        if ($psCmdlet.ParameterSetName -eq 'ScriptInputSet')
        {
            return [System.Management.Automation.CommandCompletion]::CompleteInput(
                <#inputScript#>  $inputScript,
                <#cursorColumn#> $cursorColumn,
                <#options#>      $options)
        }
        else
        {
            return [System.Management.Automation.CommandCompletion]::CompleteInput(
                <#ast#>              $ast,
                <#tokens#>           $tokens,
                <#positionOfCursor#> $positionOfCursor,
                <#options#>          $options)
        }
    }
}

#endregion

#region Define function and 3 argument completer scriptblocks
# 
# Scriptblocks will all write to log file with no completions unless
# the -AllowCompletions switch is specified. The three completers
# defined will be:
#   1. [ArgumentCompleter()] attribute for -Parameter1
#   2. Argument completer for -Parameter1 registered for command name and parameter
#      name via Register-ArgumentCompleter
#   3. Native completer for Show-CustomCompleterArguments command via 
#      Register-ArgumentCompleter -Native
# 

function Show-CustomCompleterArguments {
    [CmdletBinding()]
    param(
        [ArgumentCompleter({
            param($commandName, $parameterName, $wordToComplete, $commandAst, $fakeBoundParameters)

            @"

------------------------------------
- [ArgumentCompleter()]
-
- PS> $commandAst
------------------------------------

"@ | Out-File @OutFileParams

            if ($fakeBoundParameters['AllowCompletions'] -eq $true) {
                New-Object System.Management.Automation.CompletionResult Value, Value, ParameterValue, ToolTip
            }
        })]
        $Parameter1,
        $Parameter2,
        $Parameter3,
        [switch] $AllowCompletions
    )
}

Register-ArgumentCompleter -CommandName Show-CustomCompleterArguments -ParameterName Parameter1 -ScriptBlock {
    param($commandName, $parameterName, $wordToComplete, $commandAst, $fakeBoundParameters)

    @"

------------------------------------
- Register-ArgumentCompleter (Command AND Parameter)
-
- PS> $commandAst
------------------------------------

"@ | Out-File @OutFileParams

    if ($fakeBoundParameters['AllowCompletions'] -eq $true) {
        New-Object System.Management.Automation.CompletionResult Value, Value, ParameterValue, ToolTip
    }
}

Register-ArgumentCompleter -CommandName Show-CustomCompleterArguments -Native -ScriptBlock {
    param($wordToComplete, $commandAst)

    @"

------------------------------------
- Register-ArgumentCompleter -Native
-
- PS> $commandAst
------------------------------------

"@ | Out-File @OutFileParams

}

#endregion
