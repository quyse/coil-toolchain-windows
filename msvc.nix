{ pkgs
, lib ? pkgs.lib
, toolchain-windows
, toolchain-msvs
}:

{ version ? "17"
, buildConfig ? "Release"
}:

rec {
  components = toolchain-windows.runPackerStep {
    name = "msvcComponents-${version}";
    disk = ((toolchain-msvs.vsPackages {
      inherit version;
    }).resolve {
      product = "Microsoft.VisualStudio.Product.BuildTools";
      packageIds = [
        "Microsoft.VisualStudio.Workload.VCTools"
        "Microsoft.VisualStudio.ComponentGroup.NativeDesktop.Llvm.Clang"
      ];
      includeRecommended = true;
    }).disk;
    extraMount = "work";
    beforeScript = ''
      mkdir -p work/out
    '';
    provisioners = [
      {
        type = "powershell";
        inline = [
          ''
            $installationPath = & "''${env:ProgramFiles(x86)}\Microsoft Visual Studio\Installer\vswhere.exe" -prerelease -all -products * -property installationPath
            if ($installationPath -and (test-path "$installationPath\VC\Auxiliary\Build\vcvarsall.bat")) {
              & "''${env:COMSPEC}" /s /c "`"$installationPath\VC\Auxiliary\Build\vcvarsall.bat`" x64 >NUL && set" | foreach-object {
                $name, $value = $_ -split '=', 2
                set-content env:\"$name" "$value"
              }
            }
            Copy-Item -Path "''${installationPath}" -Destination "D:\out\msvc" -Recurse
            Copy-Item -Path "''${env:ProgramFiles(x86)}\Windows Kits" -Destination "D:\out\sdk" -Recurse
          ''
        ];
      }
    ];
    afterScript = ''
      # disarm ms telemetry: vctip.exe causes trouble
      find work/out -iname vctip.exe -exec rm '{}' +
      mv work/out $out
    '';
  };

  stdenv = pkgs.stdenvNoCC;

  buildEnv = stdenv.mkDerivation {
    name = "windowsBuildEnv";

    buildCommand = ''
      mkdir -p $out/nix-support
      ln -s ${pkgs.writeScript "windowsBuildEnv-setupHook" ''
        export PATH=${toolchain-windows.wine}/bin:$PATH
        ${toolchain-windows.initWinePrefix}
        export WINEPATH="${toolchain-windows.makeWinePaths [
          "${components}/msvc/VC/Tools/MSVC/*/bin/Hostx64/x64"
          "${components}/msvc/VC/Tools/Llvm/bin"
          "${components}/msvc/Common7/IDE/CommonExtensions/Microsoft/CMake/CMake/bin"
          "${components}/msvc/Common7/IDE/CommonExtensions/Microsoft/CMake/Ninja"
          ''"$(find ${components}/sdk/10/bin -iname '*.exe' -exec dirname {} \; | grep 'x64$' | sort -u)"''
        ]};C:\Windows\system32;C:\Windows;C:\Windows\System32\Wbem"
        export INCLUDE="${toolchain-windows.makeWinePaths [
          "${components}/msvc/VC/Tools/MSVC/*/include"
          "${components}/sdk/10/Include/*/*"
          "${components}/sdk/10/Include/*/ucrt"
          "${components}/sdk/10/Include/*/shared"
          "${components}/sdk/10/Include/*/um"
          "${components}/sdk/10/Include/*/winrt"
          "${components}/sdk/10/Include/*/cppwinrt"
        ]}"
        export LIB="${toolchain-windows.makeWinePaths [
          "${components}/msvc/VC/Tools/MSVC/*/lib/x64"
          "${components}/sdk/10/Lib/*/ucrt/x64"
          "${components}/sdk/10/Lib/*/um/x64"
        ]}"
        export LIBPATH="$LIB"

        export CMAKE_GENERATOR="Ninja"

        export CC=clang-cl
        export CXX=clang-cl
        export CFLAGS=-m64
        export CXXFLAGS=-m64

        # workaround for https://bugs.winehq.org/show_bug.cgi?id=21259
        wine start mspdbsrv.exe -start -spawn -shutdowntime -1
      ''} $out/nix-support/setup-hook
    '';
  };

  defaultBuildConfig = buildConfig;

  finalizePkg = { buildInputs }: ''
    mkdir -p $out/{bin,nix-support}
    echo 'if [[ "''${CMAKE_PREFIX_PATH:-}" != *'$out'* ]]; then export CMAKE_PREFIX_PATH=''${CMAKE_PREFIX_PATH:+''${CMAKE_PREFIX_PATH};}'$out'; fi' > $out/nix-support/setup-hook
    echo 'if [[ "''${WINEPATH:-}" != *'$out/bin'* ]]; then export WINEPATH=''${WINEPATH:+''${WINEPATH};}'$out/bin'; fi' >> $out/nix-support/setup-hook
    ${lib.concatStrings (map (dep: ''
      if [ -f ${dep}/nix-support/setup-hook ]
      then
        echo '. ${dep}/nix-support/setup-hook' >> $out/nix-support/setup-hook
      fi
      find -L ${dep} -iname '*.dll' -type f -exec ln -sf '{}' $out/bin/ \;
    '') buildInputs)}
  '';

  mkCmakePkg =
    { pname ? null
    , version ? null
    , name ? "${pname}-${version}"
    , src
    , sourceRoot ? null
    , buildInputs ? []
    , cmakeFlags ? []
    , sourceDir ? "."
    , buildDir ? "build"
    , buildConfig ? defaultBuildConfig
    , postPatch ? null
    , doCheck ? true
    , meta ? null
    }: pkgs.stdenvNoCC.mkDerivation {
    inherit pname version name src sourceRoot buildInputs postPatch doCheck meta;
    nativeBuildInputs = [
      buildEnv
    ];
    configurePhase = ''
      wine cmake -S ${sourceDir} -B ${buildDir} \
        -DCMAKE_BUILD_TYPE=${buildConfig} \
        -DCMAKE_INSTALL_PREFIX=$(winepath -w $out) \
        -DCMAKE_INSTALL_INCLUDEDIR=$(winepath -w $out/include) \
        -DBUILD_TESTING=${if doCheck then "ON" else "OFF"} \
        ${lib.escapeShellArgs cmakeFlags}
    '';
    buildPhase = ''
      wine cmake --build ${buildDir} --config ${buildConfig} -j ''$NIX_BUILD_CORES
    '';
    checkPhase = ''
      wine ctest --test-dir ${buildDir}
    '';
    installPhase = ''
      wine cmake --install ${buildDir} --config ${buildConfig}
      ${finalizePkg {
        inherit buildInputs;
      }}
    '';
  };
}
