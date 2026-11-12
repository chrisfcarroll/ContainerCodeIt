Here are errors I got after cloning ContainerCodeIt to a new Win 11 machine, installing docker, and trying to run.

Fix them all. It's a bit disappointing. What else will go wrong on a new install?

---

./Code-It.ps1 'does this work' -agent claude
    Using container runtime: docker
    Using code agent: claude
    No code-it image or setup found; running Code-It-FirstRun.ps1.
  C:\Users\ITSCCARR\3rd\ContainerCodeIt\Code-It-Build.ps1 -interactive
Get-Command : The term 'pwsh' is not recognized as the name of a cmdlet, function, script file, or operable program.
Check the spelling of the name, or if a path was included, verify that the path is correct and try again.
At C:\Users\ITSCCARR\3rd\ContainerCodeIt\Code-It-FirstRun.ps1:91 char:19
+ ... shellExe = (Get-Command pwsh -CommandType Application -EA Stop | Sele ...
+                 ~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
    + CategoryInfo          : ObjectNotFound: (pwsh:String) [Get-Command], CommandNotFoundException
    + FullyQualifiedErrorId : CommandNotFoundException,Microsoft.PowerShell.Commands.GetCommandCommand


> Code-It-FirstRun.ps1

Join-Path : Cannot bind argument to parameter 'Path' because it is an empty string.
At C:\Users\ITSCCARR\3rd\ContainerCodeIt\Code-It-Build.ps1:117 char:24
+ $agentsDir = Join-Path $dockerfileDir 'agents'
+                        ~~~~~~~~~~~~~~
    + CategoryInfo          : InvalidData: (:) [Join-Path], ParameterBindingValidationException
    + FullyQualifiedErrorId : ParameterArgumentValidationErrorEmptyStringNotAllowed,Microsoft.PowerShell.Commands.Join
   PathCommand

Test-Path : Cannot bind argument to parameter 'Path' because it is null.
At C:\Users\ITSCCARR\3rd\ContainerCodeIt\Code-It-Build.ps1:118 char:27
+ if (-not (Test-Path -Path $agentsDir -PathType Container)) { $agentsD ...
+                           ~~~~~~~~~~
    + CategoryInfo          : InvalidData: (:) [Test-Path], ParameterBindingValidationException
    + FullyQualifiedErrorId : ParameterArgumentValidationErrorNullNotAllowed,Microsoft.PowerShell.Commands.TestPathCom
   mand

Join-Path : Cannot bind argument to parameter 'Path' because it is an empty string.
At C:\Users\ITSCCARR\3rd\ContainerCodeIt\Code-It-Build.ps1:119 char:28
+ $toolchainsDir = Join-Path $dockerfileDir 'toolchains'
+                            ~~~~~~~~~~~~~~
    + CategoryInfo          : InvalidData: (:) [Join-Path], ParameterBindingValidationException
    + FullyQualifiedErrorId : ParameterArgumentValidationErrorEmptyStringNotAllowed,Microsoft.PowerShell.Commands.Join
   PathCommand

Test-Path : Cannot bind argument to parameter 'Path' because it is null.
At C:\Users\ITSCCARR\3rd\ContainerCodeIt\Code-It-Build.ps1:120 char:27
+ if (-not (Test-Path -Path $toolchainsDir -PathType Container)) { $too ...
+                           ~~~~~~~~~~~~~~
    + CategoryInfo          : InvalidData: (:) [Test-Path], ParameterBindingValidationException
    + FullyQualifiedErrorId : ParameterArgumentValidationErrorNullNotAllowed,Microsoft.PowerShell.Commands.TestPathCom
   mand

Join-Path : Cannot bind argument to parameter 'Path' because it is an empty string.
At C:\Users\ITSCCARR\3rd\ContainerCodeIt\Code-It-Build.ps1:121 char:31
+ $packageCachesDir = Join-Path $dockerfileDir 'package-caches'
+                               ~~~~~~~~~~~~~~
    + CategoryInfo          : InvalidData: (:) [Join-Path], ParameterBindingValidationException
    + FullyQualifiedErrorId : ParameterArgumentValidationErrorEmptyStringNotAllowed,Microsoft.PowerShell.Commands.Join
   PathCommand

Test-Path : Cannot bind argument to parameter 'Path' because it is null.
At C:\Users\ITSCCARR\3rd\ContainerCodeIt\Code-It-Build.ps1:122 char:27
+ if (-not (Test-Path -Path $packageCachesDir -PathType Container)) { $ ...
+                           ~~~~~~~~~~~~~~~~~
    + CategoryInfo          : InvalidData: (:) [Test-Path], ParameterBindingValidationException
    + FullyQualifiedErrorId : ParameterArgumentValidationErrorNullNotAllowed,Microsoft.PowerShell.Commands.TestPathCom
   mand

Test-Path : Cannot bind argument to parameter 'Path' because it is an empty string.
At C:\Users\ITSCCARR\3rd\ContainerCodeIt\lib\CodeItCommon.ps1:67 char:31
+     if (-not (Test-Path -Path $dir -PathType Container)) { return ,@( ...
+                               ~~~~
    + CategoryInfo          : InvalidData: (:) [Test-Path], ParameterBindingValidationException
    + FullyQualifiedErrorId : ParameterArgumentValidationErrorEmptyStringNotAllowed,Microsoft.PowerShell.Commands.Test
   PathCommand

Test-Path : Cannot bind argument to parameter 'Path' because it is an empty string.
At C:\Users\ITSCCARR\3rd\ContainerCodeIt\lib\CodeItCommon.ps1:67 char:31
+     if (-not (Test-Path -Path $dir -PathType Container)) { return ,@( ...
+                               ~~~~
    + CategoryInfo          : InvalidData: (:) [Test-Path], ParameterBindingValidationException
    + FullyQualifiedErrorId : ParameterArgumentValidationErrorEmptyStringNotAllowed,Microsoft.PowerShell.Commands.Test
   PathCommand