return

#region Notes
#
# This takes the same concept as earlier, except no DSL is necessary because we'll use
# reflection to figure out valid parameters and what to do with them
#
#endregion

#region Build dynamic module
$SimpleWpfModule = New-Module -Name SimpleWpfModule -ScriptBlock {

    $__CommandNames = @{}
    $__EventParameterPrefix = ''  # See what happens if you add something here

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

            try {
                $ReturnObject = New-Object $MyType.FullName $ArgumentList -ErrorAction Stop
            }
            catch {
                Write-Error "Error creating element: $_"
                return
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

                        try {
                            if ( ($ReturnObject | Get-Member -MemberType Properties -Name $Property).Definition -notmatch 'set;' -and (Get-Member -InputObject $ReturnObject.$Property -MemberType Method -Name Add)) {
                                Write-Verbose 'Add method present'
                                foreach ($CurrentValue in $PSBoundParameters[$BoundProperty]) {
                                    $null = $ReturnObject.$Property.Add.Invoke($CurrentValue)
                                }
                            }
                            else {
                                $ReturnObject.$Property = $PSBoundParameters[$Property]
                            }
                        }
                        catch {
                            Write-Warning "Unable to set '$BoundProperty' property on '$($MyType.Name)' control: $_"
                        }
                    }

                    Event {
                        foreach ($Delegate in $PSBoundParameters[$BoundProperty]) {
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

#region Simple examples

# Look at how many commands are available:
Get-Command -Module $SimpleWpfModule | measure

# Import more WPF commands, like the WPF toolkit, then recreate the module
# and check out the count

Get-Command Button -Syntax

Window -Height 300 -Width 300 -Title 'Summit Demo (Simple WPF)' -Content (
    StackPanel -Children @(
        StackPanel -Orientation Horizontal -Children @(
            Label -Content 'Message:'
            ($textbox = TextBox -Width 200)
        )
        Button -Content 'Show Message' -Width 100  -On_Click {
            [System.Windows.MessageBox]::Show($textbox.Text)
        } -Margin '10' -IsDefault:$true
    )
) | tee -var window | % ShowDialog
#endregion

#region Problems
# 
#  Notice how you could put the event inline with the code. There are several issues with this simple
#  approach, though:
#    - Notice how we got a reference to $textbox up there. That shouldn't have to be done. In the
#      next version, we're going to treat the -Name parameter as an indication that a variable needs
#      to be set with that element as its value, so we could have just said 'TextBox -Name textbox' and
#      not worried about assigning anything to a variable explicitly.
# 
#    - Notice how I had to know that the Window took a -Content property, while the StackPanels had
#      -Children. In XAML, you don't have to do that...you can have an opening tag, and then the child
#      elements just work. It turns out WPF keeps that information available for each type. Try this:
#         PS> [System.Windows.Controls.StackPanel].GetCustomAttributes($true) | ? { $_ -is [System.Windows.Markup.ContentPropertyAttribute] } | % Name
# 
#      We'll fix this in the next version, too, so that you can just put the default value inside of
#      some braces and it will just work.
# 
#    - No attached properties. A grid might have been better than a StackPanel in the example, but we
#      wouldn't have had a way to bind the elements to rows or columns. In XAML, you would have been
#      able to use an attached property, which would look like 'Grid.Column' or 'Grid.Row'. That's
#      not going to work with the simple code above.
# 
#    - No Bindings in this version
# 
#    - I'm sure lots of other stuff that WPF experts would notice that I don't have a clue about since
#      I'm not even close to an expert.
#
#endregion
