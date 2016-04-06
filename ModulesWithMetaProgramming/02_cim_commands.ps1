return

#region Notes
#
# This script will create a module that allows the creation of commands that can generate
# and run dynamic WQL against other computers. It has something that might be called a
# domain specific language that looks like this:
# 
#     CimCommand Get-CimService {
#         CimParameter string[] State
#         CimParameter string[] Name
#         CimClass Win32_Service
#     }
# 
#     CimCommand Get-CimService2 {
#         CimClass Win32_Service
#     }
# 
# Those commands would create two functions: Get-CimService and Get-CimService2. The first
# one will only have two properties available to filter on, and that will be returned. Since
# the second one doesn't have any properties defined, CimClassProperties will be obtained from
# Get-CimClass, and all properties will be added as valid function properties, and they will
# all be returned in the output.
#
#endregion

#region Build dynamic module
$DynamicModule = New-Module -Name DynamicCimCommands -ScriptBlock {

    # This will store command specific information, and the command scriptblock can look into
    # it's module's scope and get that info at runtime. In this example, the hash table will
    # store a parameter dictionary that the DynamicParam{} block will look up and return. You
    # can make it store whatever info you want, though:
    $__CommandInfo = @{}

    #region Reference scriptblock
    $ReferenceCommand = {
        [CmdletBinding()]
        param(
            [string[]] $ComputerName
        )

        DynamicParam {
            if (($Parameters = $__CommandInfo[$MyInvocation.MyCommand.Name]['Parameters'])) {
                $Parameters
            }
        }

        process {
            
            $GetCimInstanceParams = @{}
            $WhereConditions = New-Object System.Collections.Generic.List[string]
            $ClassName = $__CommandInfo[$MyInvocation.MyCommand.Name].CimClass

            foreach ($CurrentParameterName in $PSBoundParameters.Keys) {
                if ($CurrentParameterName -eq 'ComputerName') {
                    # This won't be added to query...this goes to the Get-CimInstanceParams
                    $GetCimInstanceParams['ComputerName'] = $PSBoundParameters['ComputerName']
                }
                elseif ($CurrentParameterName -in $__CommandInfo[$MyInvocation.MyCommand.Name].Parameters.Keys) {
                    # Figure out the operator and quoting rules based on the type:
                    switch ($PSBoundParameters[$CurrentParameterName].GetType()) {
                        { $_ -eq [string] -or ($_.IsArray -and $_.GetElementType() -eq [string]) } {
                            $Operator = 'LIKE'
                            $QuotesNeeded = $true
                        }

                        default {
                            $Operator = '=' # Default operator
                            $IsQuoted = $false
                        }
                    }
                    # Update WHERE conditions
                    $LocalConditions = foreach ($Value in $PSBoundParameters[$CurrentParameterName]) {
                        if ($IsQuoted) {
                            $Value = "'${Value}'"
                        }
                        '{0} {1} ''{2}''' -f $CurrentParameterName, $Operator, $Value
                    }
                    $WhereConditions.Add($LocalConditions -join ' OR ')
                }
            }

            # Time to build the WQL query:
            $SelectItems = $PSCmdlet.MyInvocation.MyCommand.Parameters.GetEnumerator() | where { $_.Value.IsDynamic } | select -ExpandProperty Key

            $QueryStringBuilder = New-Object System.Text.StringBuilder
            $null = $QueryStringBuilder.Append(("SELECT {0} FROM {1}" -f ($SelectItems -join ", "), $ClassName))
            
            if ($WhereConditions.Count) {
                $null = $QueryStringBuilder.Append((" WHERE {0}" -f ($WhereConditions -join " AND ")))
            }

            $GetCimInstanceParams['Query'] = $QueryStringBuilder.ToString()

            Write-Debug "Executing the following WQL query:`n$($QueryStringBuilder.ToString())"
            Get-CimInstance @GetCimInstanceParams
        }
    }
    #endregion

    #region domain specific language
    function CimCommand {
        [CmdletBinding()]
        param(
            [string] $CommandName,
            [scriptblock] $Definition,
            [ValidateSet('global','script','local')]
            [string] $Scope = 'script'
        )

        begin {
            # Another DSL keyword; this time for creating parameters
            function CimParameter {
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

<#
                    # Add a generic argument completer that checks for a ValueMaps:
                    $Attributes.Add((New-Object ArgumentCompleter {
                        param($commandName, $parameterName, $wordToComplete, $commandAst, $fakeBoundParameters)

                        $Module = Get-Command $commandName | select -ExpandProperty Module

                        if ($Module) {
                            & $Module {
                                param($commandName, $parameterName)

                                Get-CimClass -ClassName $__CommandInfo[$commandName].CimClass -Namespace $__CommandInfo[$commandName].CimNamespace | 
                                    select -ExpandProperty CimClassProperties | 
                                    where Name -eq $parameterName | 
                                    select -ExpandProperty Qualifiers | 
                                    where Name -eq ValueMap | 
                                    select -ExpandProperty Value
                            } $commandName $parameterName | where { $_ -like "${wordToComplete}*" } | ForEach-Object {
                                New-Object System.Management.Automation.CompletionResult ("'$_'", $_, 'ParameterValue', $_)
                            }
                        }
                    }))
#>

                    # Create a runtime defined parameter that the reference script block will use in the DynamicParam{} block
                    $MyCommandInfo['Parameters'][$ParameterName] = New-Object System.Management.Automation.RuntimeDefinedParameter (
                        $ParameterName,
                        $ParameterType,
                        $Attributes
                    )
                }
            }

            function CimClass {
                param(
                    [string] $ClassName,
                    [string] $Namespace = 'root/cimv2'
                )
                
                # $CommandName coming from parent scope:
                $__CommandInfo[$CommandName].CimClass = $ClassName
                $__CommandInfo[$CommandName].CimNamespace = $Namespace
            }
        }

        process {
            $__CommandInfo[$CommandName] = @{
                Parameters = New-Object System.Management.Automation.RuntimeDefinedParameterDictionary
            }

            & $Definition

            if (-not $__CommandInfo[$CommandName].ContainsKey('CimClass')) {
                Write-Error "Error creating '$CommandName': No CimClass was specified"
                return
            }

            try {
                $CimClassInfo = Get-CimClass -Namespace $__CommandInfo[$CommandName].CimNamespace -ClassName $__CommandInfo[$CommandName].CimClass -ErrorAction Stop
            }
            catch {
                Write-Error $_
                return
            }

            if ($__CommandInfo[$CommandName].Parameters.Count -eq 0) {
                foreach ($Parameter in $CimClassInfo.CimClassProperties) {
                    if (($ParamType = $Parameter.CimType.ToString() -as [type])) {
                        # Make them all arrays
                        if (-not $ParamType.IsArray) { $ParamType = "${ParamType}[]" -as [type] }
                        CimParameter -ParameterType $ParamType -ParameterName $Parameter.Name
                    }
                    else {
                        Write-Warning "Unable to add '$($Parameter.Name)' parameter: unable to convert CIM type '$($Parameter.CimType)' to .NET type"
                    }
                }                
            }

            $null = New-Item -Path function: -Name ${Scope}:${CommandName} -Value $ReferenceCommand -Force
            Export-ModuleMember -Function $CommandName
        }

    }
    #endregion

    #region Command definitions
    CimCommand Get-CimService {
        CimParameter string[] State
        CimParameter string[] Name
        CimClass Win32_Service
    }

    CimCommand Get-CimService2 {
        CimClass Win32_Service
    }

    CimCommand Get-CimProcess {
        CimClass Win32_Process
    }
    #endregion
}
#endregion
