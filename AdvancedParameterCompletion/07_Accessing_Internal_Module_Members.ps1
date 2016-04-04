return

# For v5, you can bind the argument completer scriptblock to a module's scope so it
# has direct access to the module's internal commands/variables. With TabExpansionPlusPlus,
# you can try that, but it will remove the binding when it binds the scriptblock to it's
# module scope so you can use its helper functions. 
#
# Below are two ways of accessing a module's internal members: both should work for v5, and
# the last one should work when TabExpansionPlusPlus is used


#region Create dynamic module
$DynamicModule = New-Module -Name DateTimeConverter -ScriptBlock {
    function Show-DateTimeCompleter {
        param(
            [datetime]
            [ROE.TransformParameterAttribute({
                $_ | DateTimeConverter
            })]
            $DateTime1,
            [datetime[]]
            [ROE.TransformParameterAttribute({
                $_ | DateTimeConverter
            })]
            $DateTime2
        )

        $PSBoundParameters
    }
    Export-ModuleMember -Function Show-DateTimeCompleter

    function DateTimeConverter {

        [CmdletBinding(DefaultParameterSetName='NormalConversion')]
        param(
            [Parameter(ValueFromPipeline, Mandatory, Position=0, ParameterSetName='NormalConversion')]
            [AllowNull()]
            $InputObject,
            [Parameter(Mandatory, ParameterSetName='ArgumentCompleterMode')]
            [AllowEmptyString()]
            [string] $wordToComplete
        )

        begin {
            $RegexInfo = @{
                Intervals = echo Minute, Hour, Day, Week, Month, Year   # Regex would need to be redesigned if one of these can't be made plural with a simple 's' at the end
                Separators = echo \., \s, _  #, '\|' # Bad separator in practice, but maybe good for an example of how easy it is to add a separator and then get command completion and argument conversion to work
                Adverbs = echo Ago, FromNow
                GenerateRegex = {
                    $Definition = $RegexInfo
                    $Separator = '({0})?' -f ($Definition.Separators -join '|')   # ? makes separators optional
                    $Adverbs = '(?<adverb>{0})' -f ($Definition.Adverbs -join '|')
                    $Intervals = '((?<interval>{0})s?)' -f ($Definition.Intervals -join '|')
                    $Number = '(?<number>-?\d+)'

                    '^{0}{1}{2}{1}{3}$' -f $Number, $Separator, $Intervals, $Adverbs
                }
            }
            $DateTimeStringRegex = & $RegexInfo.GenerateRegex

            $DateTimeStringShortcuts = @{
                Now = { Get-Date }
                Today = { (Get-Date).ToShortDateString() }
                'This Month' = { $Now = Get-Date; Get-Date -Month $Now.Month -Day 1 -Year $Now.Year }
                'Last Month' = { $Now = Get-Date; (Get-Date -Month $Now.Month -Day 1 -Year $Now.Year).AddMonths(-1) }
                'Next Month' = { $Now = Get-Date; (Get-Date -Month $Now.Month -Day 1 -Year $Now.Year).AddMonths(1) }
            }
        }

        process {
            switch ($PSCmdlet.ParameterSetName) {
        
                NormalConversion {
                    if ($InputObject -eq $null) {
                        $InputObject = [System.DBNull]::Value
                    }

                    foreach ($DateString in $InputObject) {

                        if ($DateString -eq $null) {
                            # Let the DbReaderInfo transformer handle this
                            $null
                            continue
                        }
                        elseif ($DateString -as [datetime]) {
                            # No need to do any voodoo if it can already be coerced to a datetime
                            $DateString
                            continue
                        }

                        if ($DateString -match $DateTimeStringRegex) {
                            $Multiplier = 1  # Only changed if 'week' is used
                            switch ($Matches.interval) {
                                <#
                                    Allowed intervals: minute, hour, day, week, month, year

                                    Of those, only 'week' doesn't have a method, so handle it special. The
                                    others can be handled in the default{} case
                                #>

                                week {
                                    $Multiplier = 7
                                    $MethodName = 'AddDays'
                                }

                                default {
                                    $MethodName = "Add${_}s"
                                }

                            }

                            switch ($Matches.adverb) {
                                fromnow {
                                    # No change needed
                                }

                                ago {
                                    # Multiplier needs to be negated
                                    $Multiplier *= -1
                                }
                            }

                            try {
                                (Get-Date).$MethodName.Invoke($Multiplier * $matches.number)
                                continue
                            }
                            catch {
                                Write-Error $_
                                return
                            }
                        }
                        elseif ($DateTimeStringShortcuts.ContainsKey($DateString)) {
                            (& $DateTimeStringShortcuts[$DateString]) -as [datetime]
                            continue
                        }
                        else {
                            # Just return what was originally input; if this is used as an argument transformation, the binder will
                            # throw it's localized error message
                            $DateString
                        }
                    }

                }

                ArgumentCompleterMode {
                    $CompletionResults = New-Object System.Collections.Generic.List[System.Management.Automation.CompletionResult]

                    $DoQuotes = {
                        if ($args[0] -match '\s') {
                            "'{0}'" -f $args[0]
                        }
                        else {
                            $args[0]
                        }
                    }

                    # Check for any shortcut matches:
                    foreach ($Match in ($DateTimeStringShortcuts.Keys -like "*${wordToComplete}*")) {
                        $EvaluatedValue = & $DateTimeStringShortcuts[$Match]
                        $CompletionResults.Add((New-Object System.Management.Automation.CompletionResult (& $DoQuotes $Match), $Match, 'ParameterValue', "$Match [$EvaluatedValue]"))
                    }

                    # Check to see if they've typed anything that could resemble valid friedly text
                    if ($wordToComplete -match "^(-?\d+)(?<separator>$($RegexInfo.Separators -join '|'))?") {

                        $Length = $matches[1]
                        $Separator = " "
                        if ($matches.separator) {
                            $Separator = $matches.separator
                        }

                        $IntervalSuffix = 's'
                        if ($Length -eq '1') {
                            $IntervalSuffix = ''
                        }

                        foreach ($Interval in $RegexInfo.Intervals) {
                            foreach ($Adverb in $RegexInfo.Adverbs) {
    #                            $CompletedText = $DisplayText = "${Length}${Separator}${Interval}${IntervalSuffix}${Separator}${Adverb}"
    #                            if ($CompletedText -match '\s') {
    #                                $CompletedText = "'$CompletedText'"
    #                            }
                                $Text = "${Length}${Separator}${Interval}${IntervalSuffix}${Separator}${Adverb}"
                                if ($Text -like "*${wordToComplete}*") {
#                                    $CompletionResults.Add((NewCompletionResult -CompletionText $Text))
                                    $CompletionResults.Add((New-Object System.Management.Automation.CompletionResult (& $DoQuotes $Text), $Text, 'ParameterValue', $Text))
                                }
                            }
                        }
                    }


                    $CompletionResults
                }

                default {
                    # Shouldn't happen. Just don't return anything for now...
                }
            }
        }
    }

    Add-Type @'
    using System.Collections;    // Needed for IList
    using System.Management.Automation;
    using System.Collections.Generic;

    namespace ROE {
	    public sealed class TransformParameterAttribute : ArgumentTransformationAttribute {

            public string TransformScript {
                get { return _transformScript; }
                set { _transformScript = value; }
            }

            string _transformScript;
		    public TransformParameterAttribute(string transformScript) {
                _transformScript = string.Format(@"
    # Assign $_ variable
    $_ = $args[0]

    # The return value of this needs to match the C# return type so no coercion happens
    $FinalResult = New-Object System.Collections.ObjectModel.Collection[psobject]

    $ScriptResult = {0}

    # Add the result and emit the collection
    $FinalResult.Add((,$ScriptResult))  # (Nest result in one element array so it can survive the trip back out to PS environment)
    $FinalResult", transformScript);
            }

		    public override object Transform(EngineIntrinsics engineIntrinsics, object inputData) {

                var results = engineIntrinsics.InvokeCommand.InvokeScript(
                    _transformScript,
                    true,   // Run in its own scope
                    System.Management.Automation.Runspaces.PipelineResultTypes.None,  // Just return as PSObject collection
                    null,
                    inputData
                );

                if (results.Count > 0) { 
                    return results[0].ImmediateBaseObject;
                }
    //            return inputData;  // No transformation
                return null;
            }
	    }
    }
'@
}

# Show-DateTimeCompleter has a helper function that takes some friendly text strings
# and converts them to DateTime objects. Also, the function's parameters have a
# transformation attribute attached that will call the helper function to do the
# string -> DateTime conversions:
Show-DateTimeCompleter -DateTime1 Now -DateTime2 1.day.ago, '1 week fromnow'

#endregion

#region Creating a completer bound to the module
# If an argument completer was registered inside the module, you wouldn't have to worry
# about accessing internal module members. If you want to add completion after the fact,
# though, here's how you can handle it outside of the
# module's scope:

# First, define the completer scriptblock:
$UnboundCompleter = {
    DateTimeConverter -wordToComplete $args[2]
}

# This isn't going to work because DateTimeConverter exists inside the $DynamicModule scope:
Register-ArgumentCompleter -CommandName Show-DateTimeCompleter -ParameterName DateTime1 -ScriptBlock $UnboundCompleter

# Try it out and see that the completer for -DateTime1 doesn't return anything

# Let's create a new bound scriptblock and see what happens:
$BoundCompleter = $DynamicModule.NewBoundScriptBlock($UnboundCompleter)
Register-ArgumentCompleter -CommandName Show-DateTimeCompleter -ParameterName DateTime1 -ScriptBlock $BoundCompleter

# Now try it
#endregion

#region Using an unbound completer to access module scope

# If you're using TabExpansionPlusPlus, registering the argument completer will actually remove
# any binding the scriptblock has (it binds it to the TE++ module itself so it can use those
# helper functions). An alternative to binding the parameter is to do something like this:
Register-ArgumentCompleter -CommandName Show-DateTimeCompleter -ParameterName DateTime2 -ScriptBlock {
    param ($commandName, $parameterName, $wordToComplete, $commandAst, $fakeBoundParameters)

    $Module = Get-Command $commandName | ForEach-Object Module

    if ($Module) {
        & $Module { DateTimeConverter -wordToComplete $args[0] } $wordToComplete
    }
}

# Now -DateTime1 and -DateTime2 should behave the same way: they can both access internal module members
#endregion
