# Pester 3.4 (bundled with Windows PowerShell 5.1).
# Static checks of Install.ps1. The installer is never run here: it would
# download from GitHub and write to the real module folder.

$projectRoot = Split-Path -Parent $PSScriptRoot
$installPath = Join-Path $projectRoot 'Install.ps1'
$modulePath  = Join-Path $projectRoot 'DonGrobione.Logging.psm1'

function Get-ScriptAst {
    param([string]$Path)
    $tokens      = $null
    $parseErrors = $null
    $ast = [System.Management.Automation.Language.Parser]::ParseFile($Path, [ref]$tokens, [ref]$parseErrors)
    [pscustomobject]@{ Ast = $ast; Errors = $parseErrors }
}

function Find-Ast {
    param($Ast, [scriptblock]$Predicate)
    @($Ast.FindAll($Predicate, $true))
}

# Parameter names of each function named in $Name, keyed by function name.
function Get-FunctionParameter {
    param($Ast, [string[]]$Name)
    $result = @{}
    $functions = Find-Ast $Ast { param($node) $node -is [System.Management.Automation.Language.FunctionDefinitionAst] }
    foreach ($function in $functions) {
        if ($Name -notcontains $function.Name) {
            continue
        }
        $parameters = if ($function.Body.ParamBlock) { $function.Body.ParamBlock.Parameters } else { $function.Parameters }
        $result[$function.Name] = @($parameters | ForEach-Object { $_.Name.VariablePath.UserPath }) -join ','
    }
    $result
}

$install = Get-ScriptAst $installPath
$module  = Get-ScriptAst $modulePath

Describe 'Installer' {
    It 'parses without errors' {
        $install.Errors.Count | Should Be 0
    }

    It 'never uses exit, which would close the shell under irm | iex' {
        (Find-Ast $install.Ast { param($node) $node -is [System.Management.Automation.Language.ExitStatementAst] }).Count | Should Be 0
    }

    It 'does not use Write-Host' {
        $calls = Find-Ast $install.Ast {
            param($node)
            $node -is [System.Management.Automation.Language.CommandAst] -and $node.GetCommandName() -eq 'Write-Host'
        }
        $calls.Count | Should Be 0
    }

    It 'supports ShouldProcess and validates -Scope' {
        $paramBlock = $install.Ast.ParamBlock
        $binding = @($paramBlock.Attributes | Where-Object { $_.TypeName.Name -eq 'CmdletBinding' })
        $binding.Count | Should Be 1
        $binding[0].Extent.Text | Should Match 'SupportsShouldProcess\s*=\s*\$true'

        $scope = @($paramBlock.Parameters | Where-Object { $_.Name.VariablePath.UserPath -eq 'Scope' })
        $scope.Count | Should Be 1
        $validateSet = @($scope[0].Attributes | Where-Object { $_.TypeName.Name -eq 'ValidateSet' })
        @($validateSet[0].PositionalArguments | ForEach-Object { $_.Value }) -join ',' | Should Be 'CurrentUser,AllUsers'
    }

    It 'has the same helper parameters as the module functions it copies' {
        $names = 'ConvertFrom-ManifestText', 'Confirm-ModuleVersionFolder', 'Install-ModulePackage'
        $fromInstall = Get-FunctionParameter $install.Ast $names
        $fromModule  = Get-FunctionParameter $module.Ast $names
        foreach ($name in $names) {
            $fromInstall[$name] | Should Not BeNullOrEmpty
            $fromInstall[$name] | Should Be $fromModule[$name]
        }
    }

    It 'lists the same legacy files as the module' {
        $installList = Find-Ast $install.Ast {
            param($node)
            $node -is [System.Management.Automation.Language.AssignmentStatementAst] -and $node.Left.Extent.Text -eq '$legacyFiles'
        }
        $moduleList = Find-Ast $module.Ast {
            param($node)
            $node -is [System.Management.Automation.Language.AssignmentStatementAst] -and $node.Left.Extent.Text -eq '$script:LegacyFiles'
        }
        $installList.Count | Should Be 1
        $moduleList.Count | Should Be 1
        $installList[0].Right.Extent.Text | Should Be ($moduleList[0].Right.Extent.Text -replace [regex]::Escape('$script:ModuleName'), '$moduleName')
    }
}
