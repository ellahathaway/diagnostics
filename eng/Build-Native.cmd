@if not defined _echo @echo off
setlocal EnableDelayedExpansion EnableExtensions

:: Define a prefix for most output progress messages that come from this script. That makes
:: it easier to see where these are coming from. Note that there is a trailing space here.
set "__MsgPrefix=BUILD: "

echo %__MsgPrefix%Starting Build at %TIME%
set __ThisScriptFull="%~f0"
set __ThisScriptDir="%~dp0"

call "%__ThisScriptDir%"\setup_vs_tools.cmd
if NOT '%ERRORLEVEL%' == '0' exit /b 1

if defined VS150COMNTOOLS (
  set "__VSToolsRoot=%VS150COMNTOOLS%"
  set "__VCToolsRoot=%VS150COMNTOOLS%\..\..\VC\Auxiliary\Build"
  set __VSVersion=vs2017
) else (
  set "__VSToolsRoot=%VS140COMNTOOLS%"
  set "__VCToolsRoot=%VS140COMNTOOLS%\..\..\VC"
  set __VSVersion=vs2015
)

:: Work around Jenkins CI + msbuild problem: Jenkins sometimes creates very large environment
:: variables, and msbuild can't handle environment blocks with such large variables. So clear
:: out the variables that might be too large.
set ghprbCommentBody=

:: Note that the msbuild project files (specifically, dir.proj) will use the following variables, if set:
::      __BuildArch         -- default: x64
::      __BuildType         -- default: Debug
::      __BuildOS           -- default: Windows_NT
::      __ProjectDir        -- default: directory of the dir.props file
::      __SourceDir         -- default: %__ProjectDir%\src\
::      __RootBinDir        -- default: %__ProjectDir%\artifacts\
::      __BinDir            -- default: %__RootBinDir%\bin\%__BuildOS%.%__BuildArch.%__BuildType%\
::      __IntermediatesDir  -- default: %__RootBinDir%\obj\%__BuildOS%.%__BuildArch.%__BuildType%\
::      __LogDir            -- default: %__RootBinDir%\log\%__BuildOS%.%__BuildArch.%__BuildType%\
::
:: Thus, these variables are not simply internal to this script!

:: Set the default arguments for build

set __BuildArch=x64
if /i "%PROCESSOR_ARCHITECTURE%" == "amd64" set __BuildArch=x64
if /i "%PROCESSOR_ARCHITECTURE%" == "x86" set __BuildArch=x86
set __BuildType=Debug
set __BuildOS=Windows_NT
set __Build=0
set __Test=0
set __Verbosity=minimal
set __TestArgs=

:: Set the various build properties here so that CMake and MSBuild can pick them up
set "__ProjectDir=%~dp0"
:: remove trailing slash 
if %__ProjectDir:~-1%==\ set "__ProjectDir=%__ProjectDir:~0,-1%"
set "__ProjectDir=%__ProjectDir%\.."
set "__SourceDir=%__ProjectDir%\src"
set "__PackagesDir=%DotNetRestorePackagesPath%"
if [%__PackagesDir%]==[] set "__PackagesDir=%__ProjectDir%\packages"
set "__RootBinDir=%__ProjectDir%\artifacts"

:: __UnprocessedBuildArgs are args that we pass to msbuild (e.g. /p:__BuildArch=x64)
set "__args=%*"
set processedArgs=
set __UnprocessedBuildArgs=

:Arg_Loop
if "%1" == "" goto ArgsDone

if /i "%1" == "-?"    goto Usage
if /i "%1" == "-h"    goto Usage
if /i "%1" == "-help" goto Usage
if /i "%1" == "--help" goto Usage

if /i "%1" == "-build"               (set __Build=1&set processedArgs=!processedArgs! %1&shift&goto Arg_Loop)
if /i "%1" == "-test"                (set __Test=1&set processedArgs=!processedArgs! %1&shift&goto Arg_Loop)
if /i "%1" == "-configuration"       (set __BuildType=%2&set processedArgs=!processedArgs! %1 %2&shift&shift&goto Arg_Loop)
if /i "%1" == "-architecture"        (set __BuildArch=%2&set processedArgs=!processedArgs! %1 %2&shift&shift&goto Arg_Loop)
if /i "%1" == "-verbosity"           (set __Verbosity=%2&set processedArgs=!processedArgs! %1 %2&shift&shift&goto Arg_Loop)
:: These options are passed on to the common build script when testing
if /i "%1" == "-ci"                  (set __TestArgs=!__TestArgs! %1&set processedArgs=!processedArgs! %1&shift&goto Arg_Loop)
if /i "%1" == "-solution"            (set __TestArgs=!__TestArgs! %1 %2&set processedArgs=!processedArgs! %1&shift&shift&goto Arg_Loop)
:: These options are ignored for a native build
if /i "%1" == "-rebuild"             (set processedArgs=!processedArgs! %1&shift&goto Arg_Loop)
if /i "%1" == "-sign"                (set processedArgs=!processedArgs! %1&shift&goto Arg_Loop)
if /i "%1" == "-restore"             (set processedArgs=!processedArgs! %1&shift&goto Arg_Loop)
if /i "%1" == "-pack"                (set processedArgs=!processedArgs! %1&shift&goto Arg_Loop)
if /i "%1" == "-preparemachine"      (set processedArgs=!processedArgs! %1&shift&goto Arg_Loop)

if [!processedArgs!]==[] (
  set __UnprocessedBuildArgs=%__args%
) else (
  set __UnprocessedBuildArgs=%__args%
  for %%t in (!processedArgs!) do (
    set __UnprocessedBuildArgs=!__UnprocessedBuildArgs:*%%t=!
  )
)

:ArgsDone

:: Determine if this is a cross-arch build

if /i "%__BuildArch%"=="arm64" (
    set __DoCrossArchBuild=1
    set __CrossArch=x86
    )

if /i "%__BuildArch%"=="arm" (
    set __DoCrossArchBuild=1
    set __CrossArch=x64
    )

if /i "%__BuildType%"=="debug" set __BuildType=Debug
if /i "%__BuildType%"=="release" set __BuildType=Release

:: Set the remaining variables based upon the determined build configuration
set "__BinDir=%__RootBinDir%\bin\%__BuildOS%.%__BuildArch%.%__BuildType%"
set "__IntermediatesDir=%__RootBinDir%\obj\%__BuildOS%.%__BuildArch%.%__BuildType%"
set "__LogDir=%__RootBinDir%\log\%__BuildOS%.%__BuildArch%.%__BuildType%"
if "%__NMakeMakefiles%"=="1" (set "__IntermediatesDir=%__RootBinDir%\nmakeobj\%__BuildOS%.%__BuildArch%.%__BuildType%")

set "__PackagesBinDir=%__BinDir%\.nuget"
set "__CrossComponentBinDir=%__BinDir%"
set "__CrossCompIntermediatesDir=%__IntermediatesDir%\crossgen"

if NOT "%__CrossArch%" == "" set __CrossComponentBinDir=%__CrossComponentBinDir%\%__CrossArch%
set "__CrossGenCoreLibLog=%__LogDir%\CrossgenCoreLib_%__BuildOS%__%__BuildArch%__%__BuildType%.log"
set "__CrossgenExe=%__CrossComponentBinDir%\crossgen.exe"

:: Generate path to be set for CMAKE_INSTALL_PREFIX to contain forward slash
set "__CMakeBinDir=%__BinDir%"
set "__CMakeBinDir=%__CMakeBinDir:\=/%"

if not exist "%__BinDir%"           md "%__BinDir%"
if not exist "%__IntermediatesDir%" md "%__IntermediatesDir%"
if not exist "%__LogDir%"           md "%__LogDir%"

echo %__MsgPrefix%Commencing diagnostics repo build

:: Set the remaining variables based upon the determined build configuration

echo %__MsgPrefix%Checking prerequisites
:: Eval the output from probe-win1.ps1
for /f "delims=" %%a in ('powershell -NoProfile -ExecutionPolicy ByPass "& ""%__ProjectDir%\eng\probe-win.ps1"""') do %%a

REM =========================================================================================
REM ===
REM === Start the build steps
REM ===
REM =========================================================================================

@if defined _echo @echo on

REM Parse the optdata package versions out of msbuild so that we can pass them on to CMake
set DotNetCli=%__ProjectDir%\.dotnet\dotnet.exe
if not exist "%DotNetCli%" (
    echo %__MsgPrefix%Assertion failed: dotnet.exe not found at path "%DotNetCli%"
    exit /b 1
)
set MSBuildPath=%__ProjectDir%\.dotnet\sdk\2.1.300-rc1-008673\msbuild.dll

REM =========================================================================================
REM ===
REM === Build the native code
REM ===
REM =========================================================================================

if %__Build% EQU 1 (
    rem Scope environment changes start {
    setlocal

    echo %__MsgPrefix%Commencing build of native components for %__BuildOS%.%__BuildArch%.%__BuildType%

    set __NativePlatformArgs=-platform=%__BuildArch%
    if not "%__ToolsetDir%" == "" ( set __NativePlatformArgs=-useEnv )

    if not "%__ToolsetDir%" == "" (
        :: arm64 builds currently use private toolset which has not been released yet
        :: TODO, remove once the toolset is open.
        call :PrivateToolSet
        goto GenVSSolution
    )

    :: Set the environment for the native build
    set __VCBuildArch=x86_amd64
    if /i "%__BuildArch%" == "x86" ( set __VCBuildArch=x86 )
    if /i "%__BuildArch%" == "arm" (
        set __VCBuildArch=x86_arm

        :: Make CMake pick the highest installed version in the 10.0.* range
        set ___SDKVersion="-DCMAKE_SYSTEM_VERSION=10.0"
    )
    if /i "%__BuildArch%" == "arm64" (
        set __VCBuildArch=x86_arm64

        REM Make CMake pick the highest installed version in the 10.0.* range
        set ___SDKVersion="-DCMAKE_SYSTEM_VERSION=10.0"
    )

    echo %__MsgPrefix%Using environment: "%__VCToolsRoot%\vcvarsall.bat" !__VCBuildArch!
    call                                 "%__VCToolsRoot%\vcvarsall.bat" !__VCBuildArch!
    @if defined _echo @echo on

    if not defined VSINSTALLDIR (
        echo %__MsgPrefix%Error: VSINSTALLDIR variable not defined.
        exit /b 1
    )
    if not exist "!VSINSTALLDIR!DIA SDK" goto NoDIA

:GenVSSolution
    if defined __SkipConfigure goto SkipConfigure

    echo %__MsgPrefix%Regenerating the Visual Studio solution

    set "__ManagedBinaryDir=%__RootBinDir%\%__BuildType%\bin"
    set "__ManagedBinaryDir=!__ManagedBinaryDir:\=/!"
    set __ExtraCmakeArgs=!___SDKVersion! "-DCLR_MANAGED_BINARY_DIR=!__ManagedBinaryDir!"

    pushd "%__IntermediatesDir%"
    call "%__ProjectDir%\eng\gen-buildsys-win.bat" "%__ProjectDir%" %__VSVersion% %__BuildArch% !__ExtraCmakeArgs!
    @if defined _echo @echo on
    popd

:SkipConfigure
    if defined __ConfigureOnly goto SkipNativeBuild

    if not exist "%__IntermediatesDir%\install.vcxproj" (
        echo %__MsgPrefix%Error: failed to generate native component build project!
        exit /b 1
    )

    set __BuildLogRootName=Native
    set __BuildLog="%__LogDir%\!__BuildLogRootName!.log"
    set __BuildWrn="%__LogDir%\!__BuildLogRootName!.wrn"
    set __BuildErr="%__LogDir%\!__BuildLogRootName!.err"
    set __MsbuildLog=/flp:Verbosity=normal;LogFile=!__BuildLog!
    set __MsbuildWrn=/flp1:WarningsOnly;LogFile=!__BuildWrn!
    set __MsbuildErr=/flp2:ErrorsOnly;LogFile=!__BuildErr!

    msbuild.exe %__IntermediatesDir%\install.vcxproj /v:!__Verbosity! !__MsbuildLog! !__MsbuildWrn! !__MsbuildErr! /p:Configuration=%__BuildType% /p:Platform=%__BuildArch% %__UnprocessedBuildArgs%

    if not !errorlevel! == 0 (
        echo %__MsgPrefix%Error: native component build failed. Refer to the build log files for details:
        echo     !__BuildLog!
        echo     !__BuildWrn!
        echo     !__BuildErr!
        exit /b 1
    )

:SkipNativeBuild
    rem } Scope environment changes end
    endlocal
)

REM =========================================================================================
REM ===
REM === Build Cross-Architecture Native Components (if applicable)
REM ===
REM =========================================================================================

if /i "%__DoCrossArchBuild%"=="1" (
    rem Scope environment changes start {
    setlocal

    echo %__MsgPrefix%Commencing build of cross architecture native components for %__BuildOS%.%__BuildArch%.%__BuildType%

    :: Set the environment for the native build
    set __VCBuildArch=x86_amd64
    if /i "%__CrossArch%" == "x86" ( set __VCBuildArch=x86 )

    echo %__MsgPrefix%Using environment: "%__VCToolsRoot%\vcvarsall.bat" !__VCBuildArch!
    call                                 "%__VCToolsRoot%\vcvarsall.bat" !__VCBuildArch!
    @if defined _echo @echo on

    if not exist "%__CrossCompIntermediatesDir%" md "%__CrossCompIntermediatesDir%"
    if defined __SkipConfigure goto SkipConfigureCrossBuild

    set __CMakeBinDir=%__CrossComponentBinDir%
    set "__CMakeBinDir=!__CMakeBinDir:\=/!"

    set "__ManagedBinaryDir=%__RootBinDir%\%__BuildType%\bin"
    set "__ManagedBinaryDir=!__ManagedBinaryDir:\=/!"
    set __ExtraCmakeArgs="-DCLR_MANAGED_BINARY_DIR=!__ManagedBinaryDir!" "-DCLR_CROSS_COMPONENTS_BUILD=1" "-DCLR_CMAKE_TARGET_ARCH=%__BuildArch%" "-DCMAKE_SYSTEM_VERSION=10.0"

    pushd "%__CrossCompIntermediatesDir%"
    call "%__ProjectDir%\eng\gen-buildsys-win.bat" "%__ProjectDir%" %__VSVersion% %__CrossArch% !__ExtraCmakeArgs!
    @if defined _echo @echo on
    popd

:SkipConfigureCrossBuild
    if not exist "%__CrossCompIntermediatesDir%\install.vcxproj" (
        echo %__MsgPrefix%Error: failed to generate cross-arch components build project!
        exit /b 1
    )

    if defined __ConfigureOnly goto SkipCrossCompBuild

    set __BuildLogRootName=Native.Cross
    set __BuildLog="%__LogDir%\!__BuildLogRootName!.log"
    set __BuildWrn="%__LogDir%\!__BuildLogRootName!.wrn"
    set __BuildErr="%__LogDir%\!__BuildLogRootName!.err"
    set __MsbuildLog=/flp:Verbosity=normal;LogFile=!__BuildLog!
    set __MsbuildWrn=/flp1:WarningsOnly;LogFile=!__BuildWrn!
    set __MsbuildErr=/flp2:ErrorsOnly;LogFile=!__BuildErr!

    msbuild.exe %__CrossCompIntermediatesDir%\install.vcxproj /v:!__Verbosity! !__MsbuildLog! !__MsbuildWrn! !__MsbuildErr! /p:Configuration=%__BuildType% /p:Platform=%__CrossArch% %__UnprocessedBuildArgs%

    if not !errorlevel! == 0 (
        echo %__MsgPrefix%Error: cross-arch components build failed. Refer to the build log files for details:
        echo     !__BuildLog!
        echo     !__BuildWrn!
        echo     !__BuildErr!
        exit /b 1
    )

:SkipCrossCompBuild
    rem } Scope environment changes end
    endlocal
)

REM =========================================================================================
REM ===
REM === All builds complete!
REM ===
REM =========================================================================================

echo %__MsgPrefix%Repo successfully built. Finished at %TIME%
echo %__MsgPrefix%Product binaries are available at !__BinDir!

:: test components
if %__Test% EQU 1 (
    powershell -ExecutionPolicy ByPass -command "& """%__ProjectDir%\eng\common\Build.ps1""" -test -configuration %__BuildType% -verbosity %__Verbosity% %__TestArgs%"
    exit /b %ERRORLEVEL
)
exit /b 0

REM =========================================================================================
REM ===
REM === Helper routines
REM ===
REM =========================================================================================

:Usage
echo.
echo Build the Diagnostics repo.
echo.
echo Usage:
echo     build-native.cmd [option1] [option2]
echo.
echo All arguments are optional. The options are:
echo.
echo.-? -h -help --help: view this message.
echo -build - build native components
echo -test - test components
echo -architecture <x64|x86|arm|arm64>
echo -configuration <debug|release>
echo -verbosity <q[uiet]|m[inimal]|n[ormal]|d[etailed]|diag[nostic]>
exit /b 1

:PrivateToolSet

echo %__MsgPrefix%Setting up the usage of __ToolsetDir:%__ToolsetDir%

if /i "%__ToolsetDir%" == "" (
    echo %__MsgPrefix%Error: A toolset directory is required for the Arm64 Windows build. Use the toolset_dir argument.
    exit /b 1
)

if not exist "%__ToolsetDir%"\buildenv_arm64.cmd goto :Not_EWDK
call "%__ToolsetDir%"\buildenv_arm64.cmd
exit /b 0

:Not_EWDK
set PATH=%__ToolsetDir%\VC_sdk\bin;%PATH%
set LIB=%__ToolsetDir%\VC_sdk\lib\arm64;%__ToolsetDir%\sdpublic\sdk\lib\arm64
set INCLUDE=^
%__ToolsetDir%\VC_sdk\inc;^
%__ToolsetDir%\sdpublic\sdk\inc;^
%__ToolsetDir%\sdpublic\shared\inc;^
%__ToolsetDir%\sdpublic\shared\inc\minwin;^
%__ToolsetDir%\sdpublic\sdk\inc\ucrt;^
%__ToolsetDir%\sdpublic\sdk\inc\minwin;^
%__ToolsetDir%\sdpublic\sdk\inc\mincore;^
%__ToolsetDir%\sdpublic\sdk\inc\abi;^
%__ToolsetDir%\sdpublic\sdk\inc\clientcore;^
%__ToolsetDir%\diasdk\include
exit /b 0
