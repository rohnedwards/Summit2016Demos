return

#region Dynamic commands won't be visible outside of the module if they're created after module import time
$DynamicModule = New-Module -Name DynamicCommand -ScriptBlock {

    # Dynamic commands will share this definition:
    $ReferenceCommand = {
        [CmdletBinding()]
        param(
        )

        process {

            Write-Host "I'm the '" -NoNewline
            Write-Host $PSCmdlet.MyInvocation.MyCommand.Name -NoNewline -ForegroundColor Green
            Write-Host "' command!"

        }
    }

    # Create a function to allow new commands to be generated:
    function DynCommand {
        param(
            [string] $CommandName,
            [ValidateSet('global','script','local')]
            [string] $Scope = 'script'
        )

        $null = New-Item -Path function: -Name ${Scope}:${CommandName} -Value $ReferenceCommand -Force
        Export-ModuleMember -Function $CommandName
    }
}

#region Define some functions
# Try to create a command named 'Command1':
DynCommand Command1

# Notice that it shows up as an exported command from the module
$DynamicModule.ExportedCommands

# ...but not with Get-Command:
Get-Command -Name Command1

# Changing to global scope fixes it, but what if your module was going to be a nested module? In that
# case, commands shouldn't stomp on global scope, but hardcoding global in would cause that.

DynCommand Command2 -Scope global

# Not here...
$DynamicModule.ExportedCommands

# ...but is here...
Get-Command -Name Command2

#endregion
#endregion

#region Make dynamic commands visible in module scope
$DynamicModule = New-Module -Name DynamicCommand -ScriptBlock {

    # Dynamic commands will share this definition:
    $ReferenceCommand = {
        [CmdletBinding()]
        param(
        )

        process {

            Write-Host "I'm the '" -NoNewline
            Write-Host $PSCmdlet.MyInvocation.MyCommand.Name -NoNewline -ForegroundColor Green
            Write-Host "' command!"

        }
    }

    # Create a function to allow new commands to be generated:
    function DynCommand {
        param(
            [string] $CommandName,
            [ValidateSet('global','script','local')]
            [string] $Scope = 'script'
        )

        $null = New-Item -Path function: -Name ${Scope}:${CommandName} -Value $ReferenceCommand -Force
        Export-ModuleMember -Function $CommandName
    }

    # The difference is calling the command from inside the module while it's being created/imported:
    DynCommand Command1
    DynCommand AnotherCommand
}

# Everything looks good:
$DynamicModule.ExportedCommands
Get-Command Command1

# What's the difference here? In this example, the command creation is handled while the
# module is being created/imported. Some special scope magic happens at this time that
# doesn't happen after import time...

# Try to run the commands:
Command1
AnotherCommand
#endregion

#region Give commands parameters
# Let's make the commands do something else besides just write to the screen. Can we make them
# have a different command signature?
$DynamicModule = New-Module -Name DynamicCommand -ScriptBlock {

    # This will store command specific information, and the command scriptblock can look into
    # it's module's scope and get that info at runtime. In this example, the hash table will
    # store a parameter dictionary that the DynamicParam{} block will look up and return. You
    # can make it store whatever info you want, though:
    $__CommandInfo = @{}


    # This reference command will write the message to the screen, but it will also show
    # the parameters passed to it
    $ReferenceCommand = {
        [CmdletBinding()]
        param(
        )

        DynamicParam {
            if (($Parameters = $__CommandInfo[$MyInvocation.MyCommand.Name]['Parameters'])) {
                $Parameters
            }
        }

        process {

            Write-Host "I'm the '" -NoNewline
            Write-Host $PSCmdlet.MyInvocation.MyCommand.Name -NoNewline -ForegroundColor Green
            Write-Host "' command!"

            $PSBoundParameters
        }
    }

    # Add a -Definition parameter to allow command specific information to be passed:
    function DynCommand {
        [CmdletBinding()]
        param(
            [string] $CommandName,
            [scriptblock] $Definition,
            [ValidateSet('global','script','local')]
            [string] $Scope = 'script'
        )

        begin {
            # Another DSL keyword; this time for creating parameters
            function parameter {
                param(
                    [type] $ParameterType = [object],
                    [Parameter(Mandatory)]
                    [string] $ParameterName,
                    [System.Collections.ObjectModel.Collection[System.Attribute]] $Attributes = (New-Object parameter)
                )

                process {

                    # $CommandName coming from parent scope:
                    $MyCommandInfo = $__CommandInfo[$CommandName]

                    if ($MyCommandInfo -eq $null -or -not $MyCommandInfo.ContainsKey('Parameters')) {
                        Write-Error "Unable to find command definition for '$CommandName'"
                        return
                    }

                    # Create a runtime defined parameter that the reference script block will use in the DynamicParam{} block
                    $MyCommandInfo['Parameters'][$ParameterName] = New-Object System.Management.Automation.RuntimeDefinedParameter (
                        $ParameterName,
                        $ParameterType,
                        $Attributes
                    )
                }
            }
        }

        process {
            $__CommandInfo[$CommandName] = @{
                Parameters = New-Object System.Management.Automation.RuntimeDefinedParameterDictionary
            }

            & $Definition

            $null = New-Item -Path function: -Name ${Scope}:${CommandName} -Value $ReferenceCommand -Force
            Export-ModuleMember -Function $CommandName
        }

    }

    DynCommand Command1 {
        parameter string Parameter1
    }

    DynCommand Command2 {
        parameter int Id -Attributes (
            [Parameter] @{Mandatory = $true; ParameterSetName = 'ById'},
            (New-Object ValidateSet 1,2,3,4,5)
        )

        parameter string Name -Attributes (
            [Parameter] @{Mandatory = $true; ParameterSetName = 'ByName' }
        )

        parameter object Object
    }
}

# Notice the differences:
Get-Command Command1 -Syntax
Get-Command Command2 -Syntax

#endregion
