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
    extraMountIn = false;
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
            mkdir "D:\work\out"
            Copy-Item -Path "''${installationPath}" -Destination "D:\work\out\msvc" -Recurse
            Copy-Item -Path "''${env:ProgramFiles(x86)}\Windows Kits" -Destination "D:\work\out\sdk" -Recurse
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

  # needed for llvm
  python = pkgs.fetchzip {
    url = "https://www.python.org/ftp/python/3.13.2/python-3.13.2-embed-amd64.zip";
    stripRoot = false;
    hash = "sha256-uLtrqKeabAY0tjxCbg+h0Mv+kr1hw9rirLlVKvjGqb0=";
  };

  llvmPackages = pkgs.llvmPackages_19;
  llvm = mkCmakePkg {
    inherit (llvmPackages.tools.libllvm) pname version meta;
    buildEnv = bootstrapBuildEnv;
    src = llvmPackages.tools.libllvm.passthru.monorepoSrc;
    sourceDir = "llvm";
    preConfigure = ''
      export WINEPATH="$WINEPATH;${toolchain-windows.makeWinePaths [python]}"
    '';
    patches = [
      # needed for clang-cl modules support
      (pkgs.fetchpatch {
        url = "https://github.com/llvm/llvm-project/pull/121046.patch";
        hash = "sha256-ZSi3t8sEDfbw4hKIebYjZ17pnniPCMCltJ3/giWmNpI=";
      })
    ];
    cmakeFlags = [
      "-DLLVM_USE_LINKER=lld-link"
      "-DLLVM_ENABLE_PROJECTS=clang"
      "-DLLVM_INCLUDE_TESTS=OFF"
    ];
    doCheck = false;
  };

  cmake = mkCmakePkg rec {
    inherit (pkgs.cmake) meta;
    buildEnv = bootstrapBuildEnv;
    pname = "cmake";
    version = "3.31.6";
    src = pkgs.fetchgit {
      url = "https://gitlab.kitware.com/cmake/cmake.git";
      rev = "v${version}";
      hash = "sha256-+IzKmmpCrHL9XlNNoFj/mUB0YvNCVQN+GhTb4Ks4d8o=";
    };
    patches = [
      (pkgs.fetchpatch {
        url = "https://gitlab.kitware.com/cmake/cmake/-/merge_requests/9762.patch";
        hash = "sha256-d2pUt/omiEy/5DXvKMugxuJi4k49QI5YaKvaYCxiG1o=";
      })
    ];
    doCheck = false;
  };

  buildEnvFun = { llvmBin, cmakeBin }: stdenv.mkDerivation {
    name = "windowsBuildEnv";

    buildCommand = ''
      mkdir -p $out/nix-support
      ln -s ${pkgs.writeScript "windowsBuildEnv-setupHook" ''
        export PATH=${toolchain-windows.wine}/bin:$PATH
        ${toolchain-windows.initWinePrefix}
        export WINEPATH="${toolchain-windows.makeWinePaths ([
          "${components}/msvc/VC/Tools/MSVC/*/bin/Hostx64/x64"
        ]
        ++ lib.optional (llvmBin != null) (pkgs.runCommand "llvmBin" {} ''
            mkdir $out
            ln -s ${llvmBin}/clang-cl.exe $out/clang-cl.exe
          '')
        ++ lib.optional (cmakeBin != null) cmakeBin
        ++ [
          "${components}/msvc/VC/Tools/Llvm/bin"
          "${components}/msvc/Common7/IDE/CommonExtensions/Microsoft/CMake/CMake/bin"
          "${components}/msvc/Common7/IDE/CommonExtensions/Microsoft/CMake/Ninja"
          ''"$(find ${components}/sdk/10/bin -iname '*.exe' -exec dirname {} \; | grep 'x64$' | sort -u)"''
        ])};C:\Windows\system32;C:\Windows;C:\Windows\System32\Wbem"
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

  buildEnv = buildEnvFun {
    llvmBin = "${llvm}/bin";
    cmakeBin = "${cmake}/bin";
  };

  bootstrapBuildEnv = buildEnvFun {
    llvmBin = null;
    cmakeBin = null;
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

  mkCmakePkg = let
    defaultBuildEnv = buildEnv;
  in lib.makeOverridable (
    { pname ? null
    , version ? null
    , name ? "${pname}-${version}"
    , src
    , sourceRoot ? null
    , nativeBuildInputs ? []
    , buildInputs ? []
    , cmakeFlags ? []
    , sourceDir ? "."
    , buildDir ? "../build"
    , buildConfig ? defaultBuildConfig
    , patches ? []
    , postPatch ? null
    , preConfigure ? null
    , postConfigure ? null
    , doCheck ? true
    , preInstall ? null
    , postInstall ? null
    , meta ? {}
    , buildEnv ? defaultBuildEnv
    }: pkgs.stdenvNoCC.mkDerivation {
    inherit pname version name src sourceRoot buildInputs patches postPatch preConfigure postConfigure doCheck preInstall postInstall meta;
    nativeBuildInputs = [
      buildEnv
    ] ++ nativeBuildInputs;
    configurePhase = ''
      runHook preConfigure
      wine cmake -S ${sourceDir} -B ${buildDir} \
        -DCMAKE_BUILD_TYPE=${buildConfig} \
        -DCMAKE_INSTALL_PREFIX=$(winepath -w $out) \
        -DCMAKE_INSTALL_INCLUDEDIR=$(winepath -w $out/include) \
        -DBUILD_TESTING=${if doCheck then "ON" else "OFF"} \
        ${lib.escapeShellArgs cmakeFlags}
      runHook postConfigure
    '';
    buildPhase = ''
      wine cmake --build ${buildDir} --config ${buildConfig} -j ''$NIX_BUILD_CORES
    '';
    checkPhase = ''
      wine ctest --test-dir ${buildDir}
    '';
    installPhase = ''
      runHook preInstall
      wine cmake --install ${buildDir} --config ${buildConfig}
      ${finalizePkg {
        inherit buildInputs;
      }}
      runHook postInstall
    '';
  });
}
