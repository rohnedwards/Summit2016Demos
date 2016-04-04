return

#region  Notes
# Native completers provide a way to register a single completer for all function 
# parameters (even parameters that aren't defined). The only problem, besides the
# fact that this probably isn't what native completers were intended to do, is
# that it doesn't give you the same information, i.e., no $parameterName, 
# $commandName, or $fakeBoundParameters
#
# Also, aliases won't work with a native completer unless the completer was also 
# registered with the alias.
# 
# Since you are given the AST, you can actually figure out the rest of the info yourself
# below is a very rudimentary helper function that tries to help do that when given the
# command AST and the cursor position (it still needs work, though)
#endregion

#region Helper functions and debug log setup
function ParseParameters {

    [CmdletBinding(DefaultParameterSetName="ParamSet1")]
    param(
        [System.Management.Automation.Language.CommandAst] $CommandAst,
        [int] $CursorPosition = 0
    )


    $CommandName = $CommandAst.GetCommandName()

    $AvailableParams = @{}
    try {
        Get-Command $CommandName -ErrorAction Stop | select -ExpandProperty Parameters | ForEach-Object GetEnumerator | ForEach-Object {
            $AvailableParams[$_.Key] = $_.Value
        }
    }
    catch {
        Write-Warning "Error getting parameter information for '$CommandName': $_"
    }

    $NamedArguments = [ordered] @{}
    $UnknownNamedArguments = [ordered] @{}
    $UnnamedArguments = New-Object System.Collections.Generic.List[object]
    $CurrentParameterName = $null
    $BindingErrors = New-Object System.Collections.Generic.List[string]
    $CursorOnParameter = $null
    # Get arguments...

    for ($i = 1; $i -lt $CommandAst.CommandElements.Count; $i++) {

        $CurrentCommandElement = $CommandAst.CommandElements[$i]

        # Not the best way to handle this, but trying to figure where cursor is in relation to tokens
        $IsCursorOnThisElement = $CurrentCommandElement.Extent.StartOffset -lt $CursorPosition

        if ($CurrentCommandElement -is [System.Management.Automation.Language.CommandParameterAst]) {
            # We found a parameter name (something like '-param'). Let's see if we can find its definition:

            $CurrentParameterName = $CurrentCommandElement.ParameterName

            $PotentialMatches = foreach ($Parameter in $AvailableParams.GetEnumerator()) {
                if ($Parameter.Key -match "^$CurrentParameterName" -or $Parameter.Value.Aliases -match "^$CurrentParameterName") {
                    $Parameter.Key
                }
            }

            # We have the param name (partial, full, or alias), now try to find the value.
            $CurrentParameterArgumentValue = if ($CurrentCommandElement.Argument) {
                # First, check to see if the $CurrentArgument contains a value for 'Argument' in the following format:
                #  -param1:argument
                $CurrentCommandElement.Argument.SafeGetValue()
            }
            else {
                # Next, look ahead to the next CommandElement to see if it's an argument
                $NextArgument = if ($i -lt ($CommandAst.CommandElements.Count - 1)) {
                    $CommandAst.CommandElements[$i + 1]
                }

                if ($NextArgument -ne $null -and $NextArgument -isnot [System.Management.Automation.Language.CommandParameterAst]) {
                    $NextArgument.SafeGetValue()

                    $i++  # for loop gets to skip this element
                }
                else {
                    # Must not have been a next argument, or it must have been a parameter name. In this instance, assume
                    # param is a switch and set it to true
                    $true #{$true}.Ast.Find({$args[0] -is [System.Management.Automation.Language.ExpressionAst]}, $false)
                }
            }

            if ($PotentialMatches.Count -eq 1) {
                # Found matching parameter
                $NamedArguments[$PotentialMatches] = $CurrentParameterArgumentValue
                $null = $AvailableParams.Remove($PotentialMatches)  # This parameter won't be available anymore
            }
            else {
                # Couldn't find a matching parameter, or more than one potential match found (ambigious parameter). Either
                # way, add this parameter to the unknown named parameters
                $UnknownNamedArguments[$CurrentParameterName] = $CurrentParameterArgumentValue
                
                if ($PotentialMatches.Count -eq 0) {
                    $BindingErrors.Add("Unknown named parameter: $CurrentParameterName")
                }
                else {
                    $BindingErrors.Add("Multiple parameter founds that match '$CurrentParameterName': $PotentialMatches")
                }
            }

            if ($IsCursorOnThisElement) { $CursorOnParameter = $CurrentParameterName }
        }
        else {
            # Because of the way the previous check works, this should only happen to positional
            # arguments. Add them here, and we'll try to match them up later...
            if ($IsCursorOnThisElement) { $CursorOnParameter = $UnknownNamedArguments.Count }

            [void] $UnnamedArguments.Add($CurrentCommandElement.SafeGetValue())

        }
    }

    # Try to bind positional parameters:
    $AvailableParams.GetEnumerator() | select @{N='Name'; E={$_.Key}}, @{N='Position'; E={$_.Value.Attributes.Position}} | ? Position -ge 0 | sort position | ForEach-Object {
        if ($UnnamedArguments.Count -gt 0) {
            
            if ($CursorOnParameter -is [int]) {
                # The cursor is in/on a positional parameter. Is it this one?
                if ($CursorOnParameter -eq 0) {
                    $CursorOnParameter = $_.Name
                }
                else {
                    $CursorOnParameter--
                }
            }

            $NamedArguments[$_.Name] = $UnnamedArguments[0]
            $null = $UnnamedArguments.RemoveAt(0)
        }
    }

    $Properties = [ordered] @{}
    $Properties.NamedArguments = $NamedArguments
    $Properties.UnknownNamedArguments = $UnknownNamedArguments
    $Properties.UnknownPositionalArguments = $UnnamedArguments
    $Properties.BindingErrors = $BindingErrors
    $Properties.ParameterInUse = $CursorOnParameter

    $FakeBoundParameters = [ordered] @{}
    foreach ($Key in $UnknownNamedArguments.Keys) {
        $FakeBoundParameters[$Key] = $UnknownNamedArguments[$Key]
    }

    foreach ($Key in $NamedArguments.Keys) {
        $FakeBoundParameters[$Key] = $NamedArguments[$Key]
    }

    for ($i = 0; $i -lt $UnnamedArguments.Count; $i++) {
        $FakeBoundParameters["__unknown${i}"] = $UnnamedArguments[$i]
    }
    $Properties.FakeBoundParameters = $FakeBoundParameters

    [PSCustomObject] $Properties

}


$ArgCompleterDebugLog = "$env:temp\argcompleter_debug.log"
New-Item $ArgCompleterDebugLog -Force -ItemType File
Start-Process powershell "Get-Content '$ArgCompleterDebugLog' -Wait"
#endregion

#region Demo native completer with parsed command AST information
function Show-NativeCompleterExtraInfo {
    [CmdletBinding()]
    param(
        $Parameter1,
        $Parameter2
    )
}
Register-ArgumentCompleter -CommandName Show-NativeCompleterExtraInfo -Native -ScriptBlock {
    param ($wordToComplete, $commandAst, $cursorPosition)

    $commandName = $commandAst.GetCommandName()
    $parsedParams = ParseParameters $commandAst $cursorPosition

    $parameterName = $parsedParams.ParameterInUse
    $fakeBoundParameters = $parsedParams.FakeBoundParameters

    "" | Out-File @OutFileParams
    '-' * 50 | Out-File @OutFileParams
    "$commandName parameter completer (NATIVE)" | Out-File @OutFileParams
    "" | Out-File @OutFileParams
    'PS> {0}' -f $commandAst.ToString() | Out-File @OutFileParams

    echo commandName, parameterName, wordToComplete, commandAst, fakeBoundParameters | ForEach-Object {
        "`nArgument ${_}:" | Out-File @OutFileParams
        "  -> Type: $($_.GetType())" | out-file @OutFileParams
        "  -> Value: $(Get-Variable $_ -ValueOnly | out-string | % TrimEnd)" | out-file @OutFileParams
        $i++
    }
    '-' * 50 | Out-File @OutFileParams
    "" | Out-File @OutFileParams

    if ($fakeBoundParameters['AllowCompletions']) {
        foreach ($i in 1..10 ) {
            New-Object System.Management.Automation.CompletionResult "'$parameterName value $i'", "$parameterName value $i", ParameterValue, "Value $i"
        }
    }
}

# Try this:
Show-NativeCompleterExtraInfo -Parameter1 blah # TAB HERE AND WATCH LOG
Show-NativeCompleterExtraInfo -FakeParam HowIsThisHere # TAB HERE AND WATCH LOG
#endregion

