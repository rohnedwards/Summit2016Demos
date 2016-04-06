return

#region Notes 
#
# Let's think about the problem: We need to be able to pass parameters like -Grid.Row with a value. For now let's assume
# there's no easy way to know which commands will allow which parameters, so using DynamicParam {} to create parameters
# is out. 
# 
# First, if you knew you wanted to set an attached property, e.g., the row value of a parent grid, how would you do that?
#

$Button = Button
$Button.SetValue([System.Windows.Controls.Grid]::RowProperty, 2)

# For now, let's try to make it so that the command to do that would look like this:
# PS> Button -Grid.Row 2
# 
# How can we do that? Trying to get DynamicParam{} to create a parameter is a bad idea. Also, 'Grid.Row' wouldn't be
# a valid parameter anyway (the parser is going to see that as a parameter named grid with a value of '.Row', and a
# positional argument of 2.
# 
# Let's try to use 'ValueFromRemainingArguments'
# 


function Test {
    param(
        [Parameter(ValueFromRemainingArguments)]
        $Arguments,
        $Width,
        $Height
    )

    $Arguments
}

Test -Grid.Row 2 -Width 300 -Grid.Column 4 -Height 300

# That could work (we'll have to do some work to figure out what the user was asking). What about our positional scriptblock
# that allows the default content property? We could require it to be position 0, then any extra attached properties to come
# afterwards, but that seems like a silly requirement to put on users of the module. Using a parameter like this already puts
# us on the hook for doing some parsing and validation, so let's go ahead and make the $ArgumentList be the catch all parameter,
# and it can look for a scriptblock that doesn't have a corresponding parameter name and treat it as the default content property.
# This shouldn't hurt the hashtable capability b/c that's a simple check to see if the argument only contains a hash table.
# Let's see if we can create some code to handle this...
# 
#endregion

#region Create dynamic module
$WpfModuleWithAttachedProperties = New-Module -Name SimpleWpfModule -ScriptBlock {

    $__CommandNames = @{}
    $__EventParameterPrefix = 'On_'
    $__UsingTypes = New-Object System.Collections.Generic.List[type]

    #region Reference scriptblock
    $ReferenceSB = {

        [CmdletBinding()]
        param(
            [Parameter(Position=0, ValueFromRemainingArguments)]
            # This single parameter is getting a little ridiculous now. Can take hash table input that should be splatted back out and/or
            # default content scriptblock and attached properties
            [object] $ArgumentList
        )

        DynamicParam {

            $ParamDictionary = New-Object System.Management.Automation.RuntimeDefinedParameterDictionary

            $MyName = $PSCmdlet.MyInvocation.MyCommand.Name
            $MyType = $__CommandNames[$MyName]

            if (-not $MyType) { return }

            # Give a parameter for each public property that is settable or that has a simple Add()
            # method:
            foreach ($Property in ($MyType.GetProperties() | sort Name)) {

                $Type = $Property.PropertyType
                if ($Property.SetMethod -eq $null) { 

                    if (($AddMethods = $Property.PropertyType.GetMethods() | where Name -eq Add) -and $AddMethods.Count -eq 1 -and $AddMethods.GetParameters().Count -eq 1) {
                        $Type = ('{0}[]' -f $AddMethods.GetParameters().ParameterType) -as [type]
                    }
                    else {
                        continue 
                    }
                }

                $ParamDictionary[$Property.Name] = New-Object System.Management.Automation.RuntimeDefinedParameter (
                    $Property.Name,
                    $Type,
                    (New-Object Parameter)
                )
            }

            # Do the same thing for events, too:
            foreach ($Event in ($MyType.GetEvents() | sort Name)) {
                # Give each event a parameter, too
                $ParamName = '{0}{1}' -f $__EventParameterPrefix, $Event.Name

                $ParamDictionary[$ParamName] = New-Object System.Management.Automation.RuntimeDefinedParameter (
                    $ParamName,
                    [scriptblock[]],
                    (New-Object Parameter)
                )
            }

            return $ParamDictionary
        }

        end {

            if ($MyType -eq $null) {
                Write-Error "Unable to determine control type!"
                return
            }

            # Remove -ArgumentList so it doesn't get in the way later when we go through bound parameters
            $null = $PSBoundParameters.Remove('ArgumentList')

            $ParsedArgumentList = ParseAttachedPropertiesAndEvents ($ArgumentList -as [array])
            $ArgumentList = $null
            $AttachedMembers = foreach ($ParsedMember in $ParsedArgumentList) {
                if ($ParsedMember.NonAttachedProperty) {
                    # This isn't an attached member; assign it to $ArgumentList
                    # NOTE: If there's more than one of these, no error will be returned; the
                    # last one will win and be assigned to $ArgumentList. The others will be
                    # ignored.
                    $ArgumentList = $ParsedMember.NonAttachedProperty
                }
                else {
                    $ParsedMember
                }
            }

            if ($ArgumentList -is [hashtable]) {
                return (& $PSCmdlet.MyInvocation.MyCommand @PSBoundParameters @ArgumentList)
            }
            elseif ($ArgumentList -is [scriptblock]) {

                # Figure out what actual property this should be sent to:
                $ContentProperty = $MyType.GetCustomAttributes($true) | where { $_ -is [System.Windows.Markup.ContentPropertyAttribute] } | select -ExpandProperty Name

                if ($ContentProperty -eq $null) {
                    Write-Warning "Extra argument scriptblock was passed into '$($MyType.Name)' control, but ContentPropertyAttribute couldn't be found, so scriptblock will be ignored"
                }
                else {
                    # Evaluate whatever is in it:
                    Write-Verbose "Extra argument scriptblock was passed into '$($MyType.Name)' control; assigning scriptblock to '$ContentProperty' property"
                    $PSBoundParameters[$ContentProperty] = $ArgumentList
                }

                # Set it to null so the constructor won't be called with its value:
                $ArgumentList = $null
            }

            try {
                Write-Debug "Creating '$MyName' object..."
                $ReturnObject = New-Object $MyType.FullName $ArgumentList -ErrorAction Stop
            }
            catch {
                Write-Error "Error creating element: $_"
                return
            }

            if ($ReturnObject -is [System.Windows.Window]) {
                Write-Verbose 'Creating a new module scope for Window element'

                # New module scope:
                $__WindowModuleScope = New-Module -Name WpfWindowModuleScope {}

                $ReturnObject | Add-Member -NotePropertyName PsModule -NotePropertyValue $__WindowModuleScope
            }


            foreach ($Property in $PSBoundParameters.Keys) {
                if ($Property -in [System.Management.Automation.PSCmdlet]::CommonParameters) { continue }

                # Events can have an optional prefix, e.g., 'TextChanged' might have a parameter name of
                # 'On_TextChanged' if __EventParameterPrefix is defined as 'On_'. This gets rid of the
                # prefix if it exists. If a prefix has special regex characters, you'd want to escape it
                # before using it in this next line:
                $BoundProperty = $Property
                if ($Property -match "^${__EventParameterPrefix}") {
                    $Property = $Property -replace "^${__EventParameterPrefix}"
                }

                $MemberInfo = $ReturnObject | Get-Member -Name $Property
                switch ($MemberInfo.MemberType) {
                    Property {

                        # For the -Name to work properly, we need to defer creation
                        # of child elements. That means wrapping them inside scriptblock
                        # braces, {}, instead of array parenthesis, @()
                        # For that to work, we need to inspect whether or not the current
                        # property is a scriptblock, and if it is, we need to evaluate it
                        $EvaluatedProperty = $PSBoundParameters[$BoundProperty]
                        if ($EvaluatedProperty -is [scriptblock]) {
                            $EvaluatedProperty = & $EvaluatedProperty
                        }

                        if ($BoundProperty -eq 'Name') {
                            if ($__WindowModuleScope) {
                                # Call Set-Variable in module scope:
                                & $__WindowModuleScope { Set-Variable -Name $args[0] -Value $args[1] -Scope script } $PSBoundParameters[$BoundProperty] $ReturnObject
                            }
                            else {
                                Write-Warning ('Unable to find Window module scope, so can''t assign {0} element to variable ''${1}''' -f $MyType.Name, $PSBoundParameters[$Property])
                            }
                        }

                        try {
                            if ( ($ReturnObject | Get-Member -MemberType Properties -Name $Property).Definition -notmatch 'set;' -and (Get-Member -InputObject $ReturnObject.$Property -MemberType Method -Name Add)) {
                                Write-Verbose 'Add method present'
                                foreach ($CurrentValue in $EvaluatedProperty) {
                                    $null = $ReturnObject.$Property.Add.Invoke($CurrentValue)
                                }
                            }
                            else {
                                $ReturnObject.$Property = $EvaluatedProperty
                            }
                        }
                        catch {
                            Write-Warning "Unable to set '$BoundProperty' property on '$($MyType.Name)' control: $_"
                        }
                    }

                    Event {
                        foreach ($Delegate in $PSBoundParameters[$BoundProperty]) {

                            # If we can find the module scope, go ahead and bind the scriptblock to that scope
                            if ($__WindowModuleScope) {
                                $Delegate = $__WindowModuleScope.NewBoundScriptBlock($Delegate)
                            }

                            try {
                                $ReturnObject."add_${Property}".Invoke($Delegate)
                            }
                            catch {
                                Write-Warning "Unable to add '$BoundProperty' event handler '$($MyType.Name)' control: $_"
                            }
                        }
                    }

                    default {
                        Write-Warning "Unknown member type '$_' for property '$BoundProperty'"
                        continue
                    }
                }
            }

            foreach ($CurrentMember in $AttachedMembers) {
                $DebugFriendlyName = '{0}.{1}' -f $CurrentMember.DependencyObject.OwnerType.Name, $CurrentMember.DependencyObject.Name
                try {
                    switch ($CurrentMember.DependencyObject.GetType().Name) {
                        DependencyProperty {
                            Write-Debug "  Setting '$DebugFriendlyName' attached property to '$($CurrentMember.CoercedValue.ToString())'"
                            $ReturnObject.SetValue($CurrentMember.DependencyObject, $CurrentMember.CoercedValue)
                        }

                        RoutedEvent {
                            Write-Debug "  Adding '$DebugFriendlyName' attached event handler; delegate SB =  '$($CurrentMember.CoercedValue.ToString())'"

                            $ReturnObject.AddHandler($CurrentMember.DependencyObject, $CurrentMember.CoercedValue)
                        }
                        
                        default {
                            throw "Unknown attached member type: $_"
                        }
                    }
                }
                catch {
                    Write-Warning "Error adding '$($CurrentMember.DependencyObject.GetType().Name)' attached member information: $_"
                }
            }

            Write-Debug "  Returning $MyName object..."
        
            $ReturnObject
        }
    }
    #endregion 

    #region Helper functions
    function ParseAttachedPropertiesAndEvents {

        param(
            [System.Collections.IList] $ExtraParamList
        )

        $SupportedTypes = echo Property, Event
    <#
        # This will allow any of the following params/properties to be parsed as the same thing:
        #   -DockPanel.Dock
        #   -System.Windows.Controls.DockPanel.Dock
        #   -DockPanel::Dock
        #   -System.Windows.Controls.DockPanel::Dock
        #
        #             -- Opening dash
        #             |    
        #             |        
        #             |                 -- Type name can be alphanumeric with periods
        #             |                |   -- not greedy
        #             |                |   |  
        #             |                |   |    -- Mandatory separators: double colon or dot
        #             |                |   |    |                      -- not greedy
        #             |                |   |    |                      |                             -- Optional type can be specified (otherwise it will be figured out later)
        #             |                |   |    |                      |                             |                
        #             |                |   |    |                      |                             |               
        #             |                |   |    |                      |                             |                                                                             #>
        $TheRegex = "^-(?<typename>[\w\.]+?)(::|\.)(?<propertyname>\w+?)(?<objecttype>$($SupportedTypes -join '|'))?$"
        foreach ($CurrentParamName in $ExtraParamList) {

            if ($CurrentParamName -isnot [string]) {
                # Not an attached property! It will get special treatment in parent function. This might be the default content
                # scriptblock that's allowed
                [PSCustomObject] @{
                    NonAttachedProperty = $CurrentParamName
                }
                continue
            }

            $RawValue = if ($foreach.MoveNext()) {
                $foreach.Current
            }
            else {
                $null
            }

            if ($CurrentParamName -notmatch $TheRegex) {
                # This is perfectly normal. -DockPanel.Dock is not going to match this until you take the next 'parameter' into account
                Write-Verbose "'$CurrentParamName' doesn't match known regex; trying to see if property name was split"

                if ("${CurrentParamName}${RawValue}" -match $TheRegex) {
                    $CurrentParamName = "${CurrentParamName}${RawValue}"
                    $RawValue = if ($foreach.MoveNext()) {
                        $foreach.Current
                    }
                    else {
                        $null
                    }
                }
            }

            if ($CurrentParamName -match $TheRegex) {
                $RawTypeName = $matches.typename
                $PropertyName = $matches.propertyname

                $DependencyType = $RawTypeName -as [type]
                if (-not $DependencyType) {
                    # This is going to happen a lot because you're not going to want to use the full type name...

                    # First, try to cheat and look through the registered types
                    $DependencyType = $__UsingTypes | where Name -eq $RawTypeName | select -first 1
                }

                if (-not $DependencyType) {
                    # This is where you'd search through registered assemblies (starting with the normal WPF ones).
                    # Something like this: [System.AppDomain]::CurrentDomain.GetAssemblies().Where(-not {$_.IsDynamic}).GetExportedTypes().Where({$_.Name -eq 'Grid'})
                    # But you'd need to limit to WPF types.
                    # For now, just write a warning
                    Write-Warning "${CurrentParamName}: Can't determine type for '$RawTypeName'. Please use the fully qualified type name."
                    continue
                }

                $Type = $matches.objecttype

                if (-not $Type) {
                    # Unable to determine if it was an event or property, so let's try to figure it out

                    $ValidNames = foreach ($Type in $SupportedTypes) {
                        "${PropertyName}${Type}"
                    }
                    $PossibleMatches = $DependencyType | Get-Member -Static -Name $ValidNames | select -ExpandProperty Name

                    if ($PossibleMatches.Count -eq 1) {
                        $PropertyName = $PossibleMatches | select -first 1
                    }
                    elseif ($PossibleMatches.Count -gt 1) {
                        Write-Warning "Found multiple matches for '[$DependencyType]::$PropertyName': $($PossibleMatches -join ', '), so ignoring it. Please add a suffix, e.g., $($SupportedTypes -join ', '), to use this."
                        continue
                    }
                    else {
                        Write-Warning "Unable to find ${DependencyType}.${PropertyName}"
                        continue
                    }
                }
                else {
                    $PropertyName = '{0}{1}' -f $PropertyName, $Type
                }

                $DependencyProperty = $DependencyType::$PropertyName

                switch ($DependencyProperty.GetType().Name) {
                    DependencyProperty {
                        $ExpectedType = $DependencyProperty.PropertyType
                    }

                    RoutedEvent {
                        # This is what lets event handlers peek at the module scoped variables it creates...
                        if ($__WindowModuleScope) {
                            $RawValue = $__WindowModuleScope.NewBoundScriptBlock($RawValue)
                        }

                        $ExpectedType = $DependencyProperty.HandlerType
                    }

                    default {
                        # This shouldn't happen; if it does, set the expected type to [object] so no coercion is
                        # necessary
                        $ExpectedType = [object]
                    }
                }

                $CoercedValue = $RawValue -as $ExpectedType

                [PSCustomObject] @{
                    DependencyObject = $DependencyProperty
                    RawValue = $RawValue
                    CoercedValue = $CoercedValue
                }
            }
            else {
                Write-Warning "Unable to determine dependency property from '$CurrentParamName'. This property and its value ($RawValue) will be ignored."
            }
        }
    }
    #endregion

    #region Register the commands:
    [System.AppDomain]::CurrentDomain.GetAssemblies().Where({-not $_.IsDynamic}).GetExportedTypes().Where({ 
        $_.IsPublic -and
        (
            $_.IsSubclassOf([System.Windows.UIElement]) -or 
            $_.IsSubclassOf([System.Windows.Controls.DefinitionBase]) 
        )
    }) | ForEach-Object {
    
        $__UsingTypes.Add($_)

        if (-not $_.IsAbstract) {
            $CommandName = $_.Name

            # We'll use this later
            if ($_ -eq [System.Windows.Window]) {
                $script:__WindowControlCommandName = $CommandName
            }

            $__CommandNames[$CommandName] = $_
            $null = New-Item function: -Name $_.Name -Value $ReferenceSB -Force
        }
    }
    #endregion
}
#endregion

#region Example
Window {
    Grid -ColumnDefinitions @(
        ColumnDefinition
        ColumnDefinition -Width Auto
        ColumnDefinition
    ) {
        StackPanel -Grid.Column 0 {
            Label -Content Left
            ComboBox -Name comboBox -IsEditable:$true {
                1..10
            } -TextBoxBase.TextChanged { $rightLabel.Content = $comboBox.Text }
        }
        GridSplitter -HorizontalContentAlignment Right -VerticalAlignment Stretch -ResizeBehavior PreviousAndNext -Width 5 -Background '#FFBCBCBC' -Grid.Column 1 
        Label -Content Right -Grid.Column 2 -Name rightLabel
    }
} | % ShowDialog
#endregion

