return

#region Your first argument completer

#region Notes
# Argument completers are actually quite simple. You associate a scriptblock with 
# a parameter and a command (the command name is actually optional, and excluding 
# it means that any parameter with that name that doesn't have another 
# command/parameter match will use that scriptblock (so be careful)).
#
# The scriptblock is invoked every time you press TAB, Ctrl+Space, or any other time 
# that Intellisense is called internally by PowerShell.
#
# The scriptblock takes five arguments as input, and is expected to output 
# 'CompletionResult' objects.
#
# You can actually create a scriptblock that doesn't take any of that into account, 
# though, and just outputs strings
#endregion

Register-ArgumentCompleter -CommandName DummyCommand -ParameterName Parameter -ScriptBlock {
    echo 'Hello World!',    
         "'Goodnight Moon!'"
}
function DummyCommand {
    [CmdletBinding()]
    param(
        [string] $Parameter
    )

    $PSBoundParameters
}

#region Notes
# There are a few problems with this scriptblock. For one, the results didn't just 
# pop up automatically after pressing space. Second, the familiar icon to the left
# of the value was missing. It does function, though. Those issues are related. Let's
# work on fixing that.

# The problem occurred because we were letting PowerShell coerce the string output
# in the CompletionResult objects. A completion result actually has 4 properties:
#
#    - CompletionText: This is what will actually be replaced on the command line
#
#    - ListItemText:   The text that is presented to the user in the Intellisense 
#                      drop down
#
#    - ResultType:     The most visible thing this is responsible for is the icon 
#                      shown to the left of the text in Intellisense (notice how 
#                      command name completion looks different than parameter name 
#                      and value completions)
#
#    - ToolTip:        The text that is displayed to the user when you hover over
#                      the Intellisense box
#
# When a string is coerced, ResultType is 'Text', and the other three properties 
# are all the original string. Let's output real completion results:
#
#endregion 

Register-ArgumentCompleter -CommandName DummyCommand -ParameterName Parameter -ScriptBlock {

    echo 'Hello World!', 'Goodnight Moon!' | ForEach-Object {
        $CompletionText = $_
        if ($CompletionText -match '\s') { $CompletionText = "'$CompletionText'" }

        New-Object System.Management.Automation.CompletionResult (
            $CompletionText,    # Completion text that will show up on the command line
            $_,                 # List item text that will show up in Intellisense box
            'ParameterValue',   # The type of the completion result
            "$_ (Tooltip)"      # Tooltip info that will show up in Intellisense box
            
        )
    }
}

#region Notes
#
# Notice that any partial text entered by the user isn't taken into account. Type 
# some gibberish as a parameter, then press TAB or Ctrl+Space...
#
# All of the completers are returned, and if you select one, your gibberish is 
# overwritten. That's because there's no logic in the argument completer to control 
# what's returned from it, so it's always returning the same completers.
#
#endregion

#endregion

#region What does an argument completer receive as input?
# NOTE: This information applies to regular completers (as opposed to 'Native' completers)

# This will set up a debug log that we can monitor (the argument completer will write to it)
$ArgCompleterDebugLog = "$env:temp\argcompleter_debug.log"
New-Item $ArgCompleterDebugLog -Force -ItemType File
Start-Process powershell "Get-Content '$ArgCompleterDebugLog' -Wait"

$OutFileParams = @{
    FilePath = $ArgCompleterDebugLog
    Append = $true
}

# Register completer for DummyCommand/Parameter combination that will write debug information
# to the log file creating above
Register-ArgumentCompleter -CommandName DummyCommand -ParameterName Parameter -ScriptBlock {

    '' | Out-File @OutFileParams
    '-' * 50 | Out-File @OutFileParams
    'DummyCommand:Parameter parameter completer' | Out-File @OutFileParams
    '' | Out-File @OutFileParams

    $i = 0
    $args | Foreach-Object {
        "`nArgument ${i}:" | Out-File @OutFileParams
        "  -> Type: $($_.GetType())" | out-file @OutFileParams
        "  -> Value: $($_ | out-string | % TrimEnd)" | out-file @OutFileParams
        $i++
    }
    '-' * 50 | Out-File @OutFileParams
    "" | Out-File @OutFileParams

}

#region Notes
#
# Argument info breaks down like this:
#   Argument 0: The command name
#   Argument 1: The parameter name
#   Argument 2: The word to complete
#   Argument 3: The command AST
#   Argument 4: A hash table of bound parameters (with limits)
#endregion
#endregion

#region Limiting the completion results returned
#
# Let's take a look at using what the user provided to limit the results:
#
Register-ArgumentCompleter -CommandName DummyCommand -ParameterName Parameter -ScriptBlock {
    param($commandName, $parameterName, $wordToComplete, $commandAst, $fakeBoundParameters)

    # Notice the where-object filter:
    echo 'Hello World!', 'Goodnight Moon!' | where { $_ -like "${wordToComplete}*" } | ForEach-Object {
        $CompletionText = $_
        if ($CompletionText -match '\s') { $CompletionText = "'$CompletionText'" }
        New-Object System.Management.Automation.CompletionResult (
            $CompletionText,
            $_,
            'ParameterValue',
            "$_ (Tooltip)"
        )
    }
}
#endregion
