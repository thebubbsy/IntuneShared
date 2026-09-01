BeforeAll {
    $modulePath = Resolve-Path (Join-Path $PSScriptRoot '..\IntuneShared.psd1')
    Import-Module $modulePath -Force
}

Describe 'IntuneShared Module Tests' {
    Context 'Module Structure' {
        It 'Exports all expected transport and diagnostic functions' {
            $expected = @('Invoke-ResilientGraphRest', 'Connect-GraphToken', 'Test-StagedNetwork', 'Out-AsciiQrCode', 'New-BuildManifest')
            foreach ($fn in $expected) {
                Get-Command -Module IntuneShared -Name $fn | Should -Not -BeNullOrEmpty
            }
        }
    }

    Context 'Test-StagedNetwork' {
        It 'Executes 7-stage network probe and returns structured diagnostic stages' {
            $probe = Test-StagedNetwork -TimeoutSeconds 2
            $probe | Should -Not -BeNullOrEmpty
            $probe.TotalStages | Should -Be 7
            $probe.Details.Count | Should -Be 7
            $probe.Details[0].Name | Should -Be 'Network Interface'
            $probe.Details[2].Name | Should -Be 'DNS Resolution'
        }
    }
}
