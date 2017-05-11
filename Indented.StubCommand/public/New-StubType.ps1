using namespace System.Reflection

function New-StubType {
    <#
    .SYNOPSIS
        Generates a class or enum definition.
    .DESCRIPTION
        Builds a type definition which represents a class or type which is used to constrain a parameter.
    .INPUTS
        System.Type
    .EXAMPLE
        New-Stubtype ([IPAddress])

        Create a stub representing the System.Net.IPAddress class.
    .NOTES
        Change log:
            04/04/2017 - Chris Dent - Created.
    #>

    # This command does not change state.
    [System.Diagnostics.CodeAnalysis.SuppressMessage('PSUseShouldProcessForStateChangingFunctions', '')]
    [CmdletBinding()]
    [OutputType([String])]
    param (
        # Generate a stub of the specified type.
        [Parameter(ValueFromPipelineByPropertyName)]
        [Type]$Type,

        # If a type is flagged as secondary, member types are rewritten as object to end the type dependency chain.
        [Parameter(ValueFromPipelineByPropertyName, DontShow)]
        [Boolean]$IsPrimary = $true
    )

    begin {
        $definedTypes = @{}

        $script = New-Object ScriptBuilder

        $null = $script.AppendLine("Add-Type '")
    }

    process {
        if (-not $definedTypes.Contains($Type)) {
            $definedTypes.Add($Type, $null)

            if ($Type.Namespace -ne 'System') {
                $null = $script.AppendLine().
                                AppendFormat('namespace {0}', $Type.Namespace).
                                AppendLine().
                                AppendLine('{')
            }

            if ($Type.BaseType -eq [Enum]) {
                if ($Type.CustomAttributes.Count -gt 0 -and $Type.CustomAttributes.Where{ $_.AttributeType -eq [FlagsAttribute] }) {
                    $null = $script.AppendLine('[Flags]')
                }

                $underlyingType = [Enum]::GetUnderlyingType($Type)
                $typeName = switch ($underlyingType.Name) {
                    'Byte'   { 'byte' }
                    'SByte'  { 'sbyte' }
                    'Int16'  { 'short' }
                    'UInt16' { 'ushort' }
                    'Int32'  { 'int' }
                    'UInt32' { 'uint' }
                    'Int64'  { 'long' }
                    'UInt64' { 'ulong' }
                }

                $null = $script.AppendFormat('public enum {0} : {1}', $Type.Name, $typeName).
                                AppendLine().
                                AppendLine('{')

                $values = [Enum]::GetValues($Type)
                for ($i = 0; $i -lt $values.Count; $i++) {
                    $null = $script.AppendFormat('{0} = {1}', $values[$i].ToString(), [Convert]::ChangeType($values[$i], $underlyingType))
                    if ($i -ne $values.Count - 1) {
                        $null = $script.Append(',')
                    }
                    $null = $script.AppendLine()
                }

                $null = $script.AppendLine('}')
            } else {
                $null = $script.AppendFormat('public class {0}', $Type.Name).
                                AppendLine().
                                AppendLine('{')

                if ($IsPrimary) {
                    $members = $Type.GetMembers([BindingFlags]'Public,Instance') |
                        Where-Object MemberType -in 'Field', 'Constructor', 'Property' |
                        Group-Object MemberType |
                        Sort-Object {
                            switch ($_.Name) {
                                'Field'       { 1 }
                                'Constructor' { 2 }
                                'Property'    { 3 }
                            }
                        }

                    foreach ($memberSet in $members) {
                        $null = $script.AppendFormat('// {0}', $memberSet.Name).
                                        AppendLine()

                        $null = switch ($memberSet.Name) {
                            'Field' {
                                foreach ($field in $memberSet.Group) {
                                    $script.AppendFormat('public {0} {1};', $field.FieldType.FullName, $field.Name).
                                            AppendLine()
                                }
                                break
                            }
                            'Constructor' {
                                foreach ($constructor in $memberSet.Group) {
                                    $script.AppendFormat('public {0}', $Type.Name)
                                    $parameters = foreach ($parameter in $constructor.GetParameters()) {
                                        '{0} {1}' -f $parameter.ParameterType.FullName, $parameter.Name
                                    }
                                    $script.AppendFormat('({0}) {{ }}', $parameters -join ', ').
                                            AppendLine()
                                }
                                break
                            }
                            'Property' {
                                foreach ($property in $memberSet.Group) {
                                    $script.AppendFormat('public {0} {1}', $property.PropertyType.FullName, $property.Name).
                                            Append(' { get; set; }').
                                            AppendLine()
                                }
                                break
                            }
                        }
                        $null = $script.AppendLine()
                    }

                    # Parse and Create static methods
                    [MethodInfo[]]$methods = $Type.GetMethods([BindingFlags]'Public,Static') |
                        Where-Object { $_.Name -in 'Create', 'Parse' -and $_.ReturnType.Name -eq $Type.Name }
                    if ($methods.Count -gt 0) {
                        $null = $script.AppendLine('// Static methods')
                        foreach ($method in $methods) {
                            $null = $script.AppendFormat('public static {0} {1}', $method.ReturnType.FullName, $method.Name)
                            $parameters = foreach ($parameter in $method.GetParameters()) {
                                '{0} {1}' -f $parameter.ParameterType.FullName, $parameter.Name
                            }
                            $null = $script.AppendFormat('({0})', $parameters -join ', ').
                                            AppendLine().
                                            AppendLine('{').
                                            AppendFormat('return new {0}();', $Type.Name).
                                            AppendLine().
                                            AppendLine('}')
                        }
                        $null = $script.AppendLine()
                    }

                    # If the type does not implement a constructor which does not require arguments 
                    if (-not $Type.GetConstructor(@())) {
                        $null = $script.AppendLine('// Fabricated constructor').
                                        AppendFormat('private {0}() {{ }}', $Type.Name).
                                        AppendLine()
                        # Add a CreateTypeInstance static method
                        $null = $script.AppendFormat('public static {0} CreateTypeInstance()', $Type.Name).
                                        AppendLine().
                                        AppendLine('{').
                                        AppendFormat('return new {0}();', $Type.Name).
                                        AppendLine().
                                        AppendLine('}')
                    }
                } else {
                    $null = $script.AppendLine('public bool IsSecondaryStubType = true;').
                                    AppendLine().
                                    AppendFormat('public {0}() {{ }}', $Type.Name).
                                    AppendLine()
                }

                $null = $script.AppendLine('}')
            }

            if ($Type.Namespace -ne 'System') {
                $null = $script.AppendLine('}')
            }
        }
    }

    end {
        $null = $script.AppendLine("'")
        
        if ($definedTypes.Count -gt 0) {
            return $script.ToString()
        }
    }
}