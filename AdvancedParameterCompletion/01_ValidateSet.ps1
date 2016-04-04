return

#region Very simple static ValidateSet()
function Show-StaticValidateSetExample {
    [CmdletBinding()]
    param(
        [ValidateSet('Folder1', 'Folder2', 'Folder3')]
        [string[]] $FolderName
    )

    $PSBoundParameters
}
#endregion

#region Simple dynamic ValidateSet()
# What if you don't know the ValidateSet() values until runtime? To allow
# that, you can use dynamic parameters

function Show-DynamicValidateSetExample {

    [CmdletBinding()]
    param()

    DynamicParam {

        # This is going to be the list of folders used
        $RootFolderNames = dir "$env:SystemDrive\" -Directory | select -ExpandProperty Name

        # DynamicParam{} block is expected to return a dictionary of the parameters that
        # are created. Let's create that dictionary:
        $ParamDictionary = New-Object System.Management.Automation.RuntimeDefinedParameterDictionary

        # In a little bit, we'll create the parameter. For now, though, it'll be easier to create
        # the [Parameter()] and [ValidateSet()] attributes that we'll add to it. 
        $ParamAttributes = New-Object System.Collections.ObjectModel.Collection[System.Attribute]
        $ParamAttributes.Add((New-Object Parameter))
        $ParamAttributes.Add((New-Object ValidateSet $RootFolderNames))

        # This generates the parameter and adds the attributes we created earlier. It also adds
        # it to the dictionary
        $ParameterName = 'FolderName'
        $ParamDictionary[$ParameterName] = New-Object System.Management.Automation.RuntimeDefinedParameter (
            $ParameterName,
            [string[]],
            $ParamAttributes
        )

        return $ParamDictionary
    }

    end {
        $PSBoundParameters
    }
}

#endregion

#region dynamic ValidateSet() with spaces/special characters (v3/v4 only)

#NOTE: This workaround is only needed for PS v3 and v4. Latest v5 build handles quoting
#      for you
function Show-DynamicValidateSetWithSpacesExample {
    [CmdletBinding()]
    param()

    DynamicParam {

        # This is going to be the list of folders used
        $RootFolderNames = dir "$env:SystemDrive\" -Directory | select -ExpandProperty Name

        # DynamicParam{} block is expected to return a dictionary of the parameters that
        # are created. Let's create that dictionary:
        $ParamDictionary = New-Object System.Management.Automation.RuntimeDefinedParameterDictionary

        # In a little bit, we'll create the parameter. For now, though, it'll be easier to create
        # the [Parameter()] and [ValidateSet()] attributes that we'll add to it. 
        $ParamAttributes = New-Object System.Collections.ObjectModel.Collection[System.Attribute]
        $ParamAttributes.Add((New-Object Parameter))

        # HERE'S THE FIX:
        $ShouldQuote = {
            $tokens = $null
            $Text = $args[0]
            $null = [System.Management.Automation.Language.Parser]::ParseInput("echo $Text", [ref]$tokens, [ref]$null)
            if ($tokens.Length -ne 3) {
                $true
            }
            else {
                $false
            }
        }
        $ValidateSetStrings = $RootFolderNames | ForEach-Object {
            if ($MyInvocation.CommandOrigin -eq 'Internal' -and (& $ShouldQuote $_)) {
                    "'$($_ -replace "'", "''")'"
            }
            else {
                $_
            }
        }

        $ParamAttributes.Add((New-Object ValidateSet $ValidateSetStrings))

        # This generates the parameter and adds the attributes we created earlier. It also adds
        # it to the dictionary
        $ParameterName = 'FolderName'
        $ParamDictionary[$ParameterName] = New-Object System.Management.Automation.RuntimeDefinedParameter (
            $ParameterName,
            [string[]],
            $ParamAttributes
        )

        return $ParamDictionary
    }

    process {
        $PSBoundParameters
    }

}

#endregion

#region Using ValidateSet() to give completion suggestions

# How about using ValidateSet as a suggestion, i.e., being able to type 'p*' and get all
# valid items that start with a p?
function Show-DynamicValidateSetSuggestion {

    [CmdletBinding()]
    param(
        [switch] $AllowUnknownFolderNames
    )

    DynamicParam {

        # This is going to be the list of folders used
        $RootFolderNames = dir "$env:SystemDrive\" -Directory | select -ExpandProperty Name

        # DynamicParam{} block is expected to return a dictionary of the parameters that
        # are created. Let's create that dictionary:
        $ParamDictionary = New-Object System.Management.Automation.RuntimeDefinedParameterDictionary

        # In a little bit, we'll create the parameter. For now, though, it'll be easier to create
        # the [Parameter()] and [ValidateSet()] attributes that we'll add to it. 
        $ParamAttributes = New-Object System.Collections.ObjectModel.Collection[System.Attribute]
        $ParamAttributes.Add((New-Object Parameter))

        if ($MyInvocation.CommandOrigin -eq 'Internal') {
            # For version 3/4, you'd want to modify the $ValidateSetStrings here so that quotes
            # are added as necessary
            $ParamAttributes.Add((New-Object ValidateSet $RootFolderNames))
        }
        else {
            # Do nothing (don't add a ValidateSet requirement)
        }

        # This generates the parameter and adds the attributes we created earlier. It also adds
        # it to the dictionary
        $ParameterName = 'FolderName'
        $ParamDictionary[$ParameterName] = New-Object System.Management.Automation.RuntimeDefinedParameter (
            $ParameterName,
            [string[]],
            $ParamAttributes
        )

        return $ParamDictionary
    }

    end {
        # A little work is necessary here to convert possible wildcards into real values:

        if ($PSBoundParameters.ContainsKey('FolderName')) {
            $PSBoundParameters.FolderName = foreach ($FolderName in $PSBoundParameters.FolderName) {
                if (($MatchingFolderNames = @($RootFolderNames) -like $FolderName)) {
                    $MatchingFolderNames
                }
                elseif ($AllowUnknownFolderNames) {
                    $FolderName
                }
                else {
                    throw "Invalid folder name '$FolderName'; valid folder names: $($RootFolderNames -join ', ')"
                }
            }
        }

        $PSBoundParameters.FolderName = $PSBoundParameters.FolderName | select -Unique

        $PSBoundParameters
    }
}

# Try these commands:
Show-DynamicValidateSetSuggestion -FolderName prog*
Show-DynamicValidateSetSuggestion -FolderName prog*, folderdoesntexist  # This will fail
Show-DynamicValidateSetSuggestion -FolderName prog*, folderdoesntexist -AllowUnknownFolderNames

#endregion
