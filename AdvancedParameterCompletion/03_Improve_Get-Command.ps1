return

# Get-Command is an awesome cmdlet, but I don't like how some of the parameters aren't
# completed and/or if they are, they aren't always filtered based on other parameters
# that have been defined on the command line. That's OK, though, because custom completers
# can be registerd to override any command's default completion (unless a parameter is
# an enumeration or has a ValidateSet()
# 

#region Note about Get-Command's default completers
#
# Get-Command has partial completion out of the box in v5
#
# - Noun has an actual argument completer registered via an attribute. It looks like it only takes the -Module
#   parameter into account, though.
#
#   Try this:
#     PS> Get-Command -Noun <CTRL+SPACE>
#
#     -then-
#
#     PS> Get-Command -Module ISE -Noun <CTRL+SPACE>
#
# - These three parameters have hard coded completion behavior, i.e., completion code that runs if there aren't
#   any custom completers defined:
#     * Module
#     * Name (takes -Module into account)
#     * ParameterType
#
# - The -CommandType parameter takes an enumeration, so it has completion behavior that can't be overridden
#
#
# What doesn't work:
#   
#   PS> Get-Command -Module ISE -Verb <CTRL+SPACE>   # Verbs aren't filtered (they're not completed at all)
#   PS> Get-Command -Module ISE -Verb New -ParameterName <CTRL+SPACE>  # These aren't completed or filtered, either
#
#endregion

#region Helper functions: NewCompletionResult and ReregisterCompleter
# This is a helper function that will be called repeatedly as we try to update our custom completer scriptblock
function ReregisterCompleter {
    foreach ($ParameterName in echo Name, Verb, Noun, Module, FullyQualifiedModule, CommandType, ParameterName, ParameterType) {
        Register-ArgumentCompleter -CommandName Get-Command -ParameterName $ParameterName -ScriptBlock $Completer
    }
}

# Helper function make creating completion results much easier:
function NewCompletionResult {
    param(
        [Parameter(Mandatory, ValueFromPipeline)]
        [string] $CompletionText,
        [string] $ListItemText,
        [System.Management.Automation.CompletionResultType] $ResultType = 'ParameterValue',
        [string] $ToolTip,
        [switch] $NoQuotes,
        [AllowEmptyString()]
        [string] $FilterParameter = 'CompletionText'
    )

    process {
        if (-not $PSBoundParameters.ContainsKey('ListItemText')) {
            $ListItemText = $CompletionText
        }

        if (-not $PSBoundParameters.ContainsKey('ToolTip')) {
            $ToolTip = $CompletionText
        }

        if (($filterText = Get-Variable $FilterParameter -Scope 0 -ErrorAction SilentlyContinue -ValueOnly) -and ($wordToComplete = Get-Variable wordToComplete -Scope 1 -ErrorAction SilentlyContinue -ValueOnly)) {
            if ($filterText -notlike "${wordToComplete}*") { return }
        }

        # Modified version of the check from TabExpansionPlusPlus (I added the single quote escaping)
        if ($ResultType -eq [System.Management.Automation.CompletionResultType]::ParameterValue -and -not $NoQuotes) {
            # Add single quotes for the caller in case they are needed.
            # We use the parser to robustly determine how it will treat
            # the argument.  If we end up with too many tokens, or if
            # the parser found something expandable in the results, we
            # know quotes are needed.

            $tokens = $null
            $null = [System.Management.Automation.Language.Parser]::ParseInput("echo $CompletionText", [ref]$tokens, [ref]$null)
            if ($tokens.Length -ne 3 -or
                ($tokens[1] -is [System.Management.Automation.Language.StringExpandableToken] -and
                 $tokens[1].Kind -eq [System.Management.Automation.Language.TokenKind]::Generic))
            {
                $CompletionText = "'$($CompletionText -replace "'", "''")'"
            }
        }

        New-Object System.Management.Automation.CompletionResult $CompletionText, $ListItemText, $ResultType, $ToolTip
    }
}
#endregion

#region First try:

# One completer scriptblock will be used (notice the different logic depending on the current parameter):
$Completer = {
    param($commandName, $parameterName, $wordToComplete, $commandAst, $fakeBoundParameter)
    
    if ($commandName -ne 'Get-Command') {
        return
    }    

    # Modify the FBP so that whatever the user is working on automatically has a wildcard in it
    $fakeBoundParameter[$parameterName] = "${wordToComplete}*"
    $ValidCommands = Microsoft.PowerShell.Core\Get-Command @fakeBoundParameter

    switch ($parameterName) {

        ParameterName {
            $ValidCommands.Parameters.Keys | sort -Unique | NewCompletionResult
        }

        ParameterType {

            foreach ($ParamType in $ValidCommands.Parameters.Values.ParameterType.FullName | sort -Unique) {
                NewCompletionResult -CompletionText "([$ParamType])" -ListItemText $ParamType.Split('\.')[-1] -ToolTip $ParamType -NoQuotes
            }

        }

        default {
            $ValidCommands | select -ExpandProperty $parameterName | sort -Unique | NewCompletionResult
        }
    }
}

ReregisterCompleter
#endregion

#region Filter -ParameterName and -ParameterType
# First try works pretty well. One area that doesn't work: if you specify a -ParameterType, the -ParameterName
# variable isn't filtered on that type (or types). -ParameterName is filtered down to valid parameter names
# for commands that have that ParameterType. Let's fix that (and the reverse, so that specifying a ParameterType
# impacts the ParameterNames returned):
$Completer = {
    param($commandName, $parameterName, $wordToComplete, $commandAst, $fakeBoundParameter)
    
    if ($commandName -ne 'Get-Command') {
        return
    }    

    # Modify the FBP so that whatever the user is working on automatically has a wildcard in it
    $fakeBoundParameter[$parameterName] = "${wordToComplete}*"
    $ValidCommands = Microsoft.PowerShell.Core\Get-Command @fakeBoundParameter

    switch ($parameterName) {

        ParameterName {
            $ParamTypeFilter = { $true }
            if ($fakeBoundParameter['ParameterType']) {
                $ParamTypeFilter = { $_.ParameterType -in ($fakeBoundParameter['ParameterType'] -as [type[]])}
            }
            $ValidCommands.Parameters.Values.Where($ParamTypeFilter).Name | sort -Unique | NewCompletionResult
        }

        ParameterType {

            $ParamNameFilter = { $true }
            if ($fakeBoundParameter['ParameterName']) {
                $ParamNameFilter = { foreach ($CurrentName in $fakeBoundParameter['ParameterName']) { if ($_.Name -like $CurrentName) { $true; break; } } }
            }
            foreach ($ParamType in $ValidCommands.Parameters.Values.Where($ParamNameFilter).ParameterType.FullName | sort -Unique) {
                NewCompletionResult -CompletionText "([$ParamType])" -ListItemText $ParamType.Split('\.')[-1] -ToolTip $ParamType -NoQuotes -FilterParameter ListItemText
            }
        }

        default {
            $ValidCommands | select -ExpandProperty $parameterName | sort -Unique | NewCompletionResult
        }
    }
}
ReregisterCompleter
#endregion

#region Add ParameterName and ParameterType counts to completion results
$Completer = {
    param($commandName, $parameterName, $wordToComplete, $commandAst, $fakeBoundParameter)
    
    if ($commandName -ne 'Get-Command') {
        return
    }    

    $ParamSortRegex = '!(\<|\>)?$'
    if ($parameterName -in 'ParameterName', 'ParameterType' -and $wordToComplete -match $ParamSortRegex) {
        $wordToComplete = $wordToComplete -replace $ParamSortRegex

        $ParamSortArgs = @{
            Property = 'Count'
            Descending = $Matches[1] -eq '<'
        }
    }
    else {
        $ParamSortArgs = @{
            Property = 'Name'
        }
    }

    # Modify the FBP so that whatever the user is working on automatically has a wildcard in it
    $fakeBoundParameter[$parameterName] = "${wordToComplete}*"
    $ValidCommands = Microsoft.PowerShell.Core\Get-Command @fakeBoundParameter

    switch ($parameterName) {

        ParameterName {
            $ParamTypeFilter = { $true }
            if ($fakeBoundParameter['ParameterType']) {
                $ParamTypeFilter = { $_.ParameterType -in ($fakeBoundParameter['ParameterType'] -as [type[]])}
            }
            $ValidCommands.Parameters.Values.Where($ParamTypeFilter).Name | Group-Object -NoElement | sort @ParamSortArgs | % {
                NewCompletionResult -CompletionText $_.Name -ListItemText "$($_.Name) [$($_.Count)]" -ToolTip "$($_.Name) [$($_.Count) instances]"
            }
        }

        ParameterType {
            $ParamNameFilter = { $true }
            if ($fakeBoundParameter['ParameterName']) {
                $ParamNameFilter = { foreach ($CurrentName in $fakeBoundParameter['ParameterName']) { if ($_.Name -like $CurrentName) { $true; break; } } }
            }
            foreach ($ParamType in $ValidCommands.Parameters.Values.Where($ParamNameFilter).ParameterType.FullName | Group-Object -NoElement | sort @ParamSortArgs) {
                NewCompletionResult -CompletionText "([$($ParamType.Name)])" -ListItemText ('{0} [{1}]' -f $ParamType.Name.Split('\.')[-1], $ParamType.Count) -ToolTip ('{0} [{1}]' -f $ParamType.Name.Split('\.')[-1], $ParamType.Count) -NoQuotes -FilterParameter ListItemText
            }
        }

        default {
            $ValidCommands | select -ExpandProperty $parameterName | sort -Unique | NewCompletionResult
        }
    }
}
ReregisterCompleter

# Now you can try something like this this:
Get-Command -Verb convert* -ParameterName #CTRL + SPACE HERE
Get-Command -Verb convert* -ParameterName !< #CTRL + SPACE HERE
Get-Command -Verb convert* -ParameterName !> #CTRL + SPACE HERE
#endregion
