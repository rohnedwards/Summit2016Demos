return

# Building on the previous WPF example, let's make it so the -Name parameter automatically
# assigns the WPF elements to a variable. We don't want to pollute the global scope, so
# let's create a new dynamic module for each Window (this assumes that the only root
# element you'll ever use with this module is a Window)

#region Make -Name create module scoped variable
$SimpleWpfModuleWithVariables = New-Module -Name SimpleWpfModule -ScriptBlock {

    $__CommandNames = @{}
    $__EventParameterPrefix = 'On_'

    #region Reference Scriptblock
    $ReferenceSB = {

        [CmdletBinding()]
        param(
            [Parameter(Position=0)]
            # Takes either a hashtable or constructor arguments
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

            # If arguments are a hashtable, assume user wanted those splatted to the command:
            $null = $PSBoundParameters.Remove('ArgumentList')
            if ($ArgumentList -is [hashtable]) {
                return (& $PSCmdlet.MyInvocation.MyCommand @PSBoundParameters @ArgumentList)
            }

            try {
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

Write-Debug $BoundProperty
                        if ($BoundProperty -eq 'Name') {
                            if ($__WindowModuleScope) {
                                # Call Set-Variable in module scope:
Write-Debug 'Setting variable'
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

            Write-Debug "'${MyName}' object created, about to be returned..."
        
            $ReturnObject
        }
    }
    #endregion

    #region Register the commands (takes the place of a DSL):
    [System.AppDomain]::CurrentDomain.GetAssemblies().Where({-not $_.IsDynamic}).GetExportedTypes().Where({ 
        $_.IsPublic -and
        -not $_.IsAbstract -and
        (
            $_.IsSubclassOf([System.Windows.UIElement]) -or 
            $_.IsSubclassOf([System.Windows.Controls.DefinitionBase]) <# -or 
            $_.IsSubclassOf([System.Windows.Data.BindingBase]) -or 
            $_.IsSubclassOf([System.Windows.Threading.DispatcherObject]) -or 
            $_.IsSubclassOf([System.Windows.SetterBase]) #>
        )
    }) | ForEach-Object {
    
        $CommandName = $_.Name

        # We'll use this later
        if ($_ -eq [System.Windows.Window]) {
            $script:__WindowControlCommandName = $CommandName
        }

        $__CommandNames[$CommandName] = $_
        $null = New-Item function: -Name $_.Name -Value $ReferenceSB -Force
    }
    #endregion
}

#endregion

#region Same example as before, except TextBox uses -Name, and the Button's OnClick works with it

$Window = Window -Height 300 -Width 300 -Title 'Summit Demo (Simple WPF)' -Content {
    StackPanel -Children @(
        StackPanel -Orientation Horizontal -Children @(
            Label -Content 'Message:'
            TextBox -Width 200 -Name textbox
        )
        Button -Content 'Show Message' -Width 100  -On_Click {
            [System.Windows.MessageBox]::Show($textbox.Text)
        } -Margin '10' -IsDefault:$true
    )
}

# Where's the $textbox variable?
$textbox  # Not here
& $Window.PsModule { $textbox }   # It's inside this dynamic module

$Window.ShowDialog()

#endregion

#region Add default content property
$SimpleWpfModuleWithVariablesAndDefaultContentProperty = New-Module -Name SimpleWpfModule -ScriptBlock {

    $__CommandNames = @{}
    $__EventParameterPrefix = 'On_'

    #region Reference scriptblock
    $ReferenceSB = {

        [CmdletBinding()]
        param(
            [Parameter(Position=0)]
            # Takes either a hashtable or constructor arguments
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

            # If arguments are a hashtable, assume user wanted those splatted to the command:
            $null = $PSBoundParameters.Remove('ArgumentList')
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

            Write-Debug "'${MyName}' object created, about to be returned..."
        
            $ReturnObject
        }
    }
    #endregion

    #region Register the commands:
    [System.AppDomain]::CurrentDomain.GetAssemblies().Where({-not $_.IsDynamic}).GetExportedTypes().Where({ 
        $_.IsPublic -and
        -not $_.IsAbstract -and
        (
            $_.IsSubclassOf([System.Windows.UIElement]) -or 
            $_.IsSubclassOf([System.Windows.Controls.DefinitionBase]) 
        )
    }) | ForEach-Object {
    
        $CommandName = $_.Name

        # We'll use this later
        if ($_ -eq [System.Windows.Window]) {
            $script:__WindowControlCommandName = $CommandName
        }

        $__CommandNames[$CommandName] = $_
        $null = New-Item function: -Name $_.Name -Value $ReferenceSB -Force
    }
    #endregion
}

#endregion

#region Same example, but notice how -Content and -Children aren't needed anymore
Window -Height 300 -Width 300 -Title 'Summit Demo (Simple WPF)' {
    StackPanel -Children @(
        StackPanel -Orientation Horizontal {
            Label -Content 'Message:'
            TextBox -Width 200 -Name textbox
        }
        Button -Content 'Show Message' -Width 100  -On_Click {
            [System.Windows.MessageBox]::Show($textbox.Text)
        } -Margin '10' -IsDefault:$true
    )
} | tee -Variable window | % ShowDialog

#endregion 
