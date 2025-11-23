{ pkgs
, lib ? pkgs.lib
, toolchain-windows
, toolchain-msvs
, fixeds
}:

{ version ? "18"
, versionChannel ? "stable"
, buildConfig ? "Release"
}:

rec {
  inherit ((toolchain-msvs.vsPackages {
    inherit version versionChannel;
  }).resolve {
    product = "Microsoft.VisualStudio.Product.BuildTools";
    packageIds = [
      "Microsoft.VisualStudio.Workload.VCTools"
      "Microsoft.VisualStudio.ComponentGroup.NativeDesktop.Llvm.Clang"
    ];
    includeRecommended = true;
  }) disk;

  components = toolchain-windows.runPackerStep {
    name = "msvcComponents-${version}";
    inherit disk;
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
    url = "https://www.python.org/ftp/python/3.14.0/python-3.14.0-embed-amd64.zip";
    stripRoot = false;
    hash = "sha256-TGVvEbiZOyDxWSa+lzVaV6BpSnRZMYw3OnOOoVvHC24=";
  };

  # determine clang version
  get-clang-version = mkCmakePkg {
    name = "get-clang-version";
    src = ./get-clang-version;
    postInstall = ''
      wine $out/bin/get-clang-version.exe > $out/bin/version.txt
    '';
  };
  clangVersion = builtins.readFile "${get-clang-version}/bin/version.txt";

  llvmPackages = pkgs."llvmPackages_${clangVersion}";
  llvm = mkCmakePkg {
    inherit (llvmPackages.libllvm) pname version meta;
    reduceDeps = false;
    src = llvmPackages.libllvm.passthru.monorepoSrc;
    sourceDir = "llvm";
    preConfigure = ''
      export WINEPATH="$WINEPATH;${toolchain-windows.makeWinePaths [python]}"
    '';
    patches = [
      # needed for clang-cl modules support
      (pkgs.fetchpatch {
        url = "https://github.com/llvm/llvm-project/pull/121046.patch";
        hash = "sha256-WLkFUYgouLPn5wSV0L7ZUWWZ5ATm1KCezTDe2uqXGiw=";
      })
    ];
    cmakeFlags = [
      "-DLLVM_USE_LINKER=lld-link"
      "-DLLVM_ENABLE_PROJECTS=clang"
      "-DLLVM_INCLUDE_TESTS=OFF"
    ];
    doCheck = false;
  };

  # seed cmake from official binaries
  # cmake from msvs is broken in Wine since msvs 18.0.0
  cmakeBinary = pkgs.runCommand "cmake-windows-binary" {
    nativeBuildInputs = [
      pkgs.unzip
    ];
  } ''
    unzip -q ${pkgs.fetchurl {
      inherit (fixeds.fetchrelease."https://github.com/Kitware/CMake#^cmake-[0-9.]+-windows-x86_64\\.zip$") url name sha256;
    }}
    mv cmake-* $out
  '';

  cmake = mkCmakePkg rec {
    inherit (pkgs.cmake) meta;
    reduceDeps = false;
    name = "cmake-windows";
    src = pkgs.fetchgit {
      inherit (fixeds.fetchgit."https://github.com/Kitware/CMake.git##latest_release") url rev sha256;
    };
    patches = [
      ./msvc-cmake-cpp-modules.patch
    ];
    cmakeFlags = [
      # using non-DLL runtime somehow fixes CMake crash
      # FIXME: probably a deeper issue here with MSVC DLLs
      "-DCMAKE_MSVC_RUNTIME_LIBRARY=MultiThreaded"
    ];
    doCheck = false;
    buildEnv = buildEnvForCMake;
  };

  buildEnvFun = { llvmBin, cmakeBin }: stdenv.mkDerivation {
    name = "windowsBuildEnv";

    buildCommand = ''
      mkdir -p $out/nix-support
      ln -s ${pkgs.writeScript "windowsBuildEnv-setupHook" ''
        export PATH=${toolchain-windows.wine}/bin:$PATH
        ${toolchain-windows.initWinePrefix}
        MSVC_PREFIX=""
        for i in ${components}/msvc/VC/Tools/MSVC/*
        do
          MSVC_PREFIX="$i"
        done
        export WINEPATH="${toolchain-windows.makeWinePaths ([
          "$MSVC_PREFIX/bin/Hostx64/x64"
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
          "$MSVC_PREFIX/include"
          "${components}/sdk/10/Include/*/ucrt"
          "${components}/sdk/10/Include/*/shared"
          "${components}/sdk/10/Include/*/um"
          "${components}/sdk/10/Include/*/winrt"
          "${components}/sdk/10/Include/*/cppwinrt"
        ]}"
        export LIB="${toolchain-windows.makeWinePaths [
          "$MSVC_PREFIX/lib/x64"
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

  pe-deps = mkCmakePkg {
    name = "pe-deps";
    src = ./pe-deps;
    reduceDeps = false;
  };

  buildEnvForCMake = buildEnvFun {
    llvmBin = null;
    cmakeBin = "${cmakeBinary}/bin";
  };

  buildEnv = buildEnvFun {
    llvmBin = null;
    cmakeBin = "${cmake}/bin";
  };

  buildEnvWithModulesSupport = buildEnvFun {
    llvmBin = "${llvm}/bin";
    cmakeBin = "${cmake}/bin";
  };

  defaultBuildConfig = buildConfig;

  finalizePkg = { buildInputs, reduceDeps ? true }: ''
    mkdir -p $out/{bin,nix-support}
    echo 'if [[ "''${CMAKE_PREFIX_PATH:-}" != *'$out'* ]]; then export CMAKE_PREFIX_PATH=''${CMAKE_PREFIX_PATH:+''${CMAKE_PREFIX_PATH};}'$out'; fi' > $out/nix-support/setup-hook
    echo 'if [[ "''${WINEPATH:-}" != *'$out/bin'* ]]; then export WINEPATH=''${WINEPATH:+''${WINEPATH};}'$out/bin'; fi' >> $out/nix-support/setup-hook
    ${lib.concatStrings (map (dep: ''
      if [ -f ${dep}/nix-support/setup-hook ]
      then
        echo '. ${dep}/nix-support/setup-hook' >> $out/nix-support/setup-hook
      fi
      find -L ${dep} -iname '*.dll' -exec ln -sft $out/bin '{}' +
    '') buildInputs)}
    ${lib.optionalString reduceDeps ''
      mkdir -p $out/bin-reduced
      find -L $out/bin -iname '*.exe' -exec ln -rst $out/bin-reduced '{}' +
      pushd $out/bin
      find -L $out/bin -iname '*.exe' -exec wine ${pe-deps}/bin/pe-deps.exe '{}' + \
        | ${pkgs.dos2unix}/bin/dos2unix \
        | sort -u \
        | xargs -I % find -L $out/bin -iname % -exec ln -rst $out/bin-reduced '{}' +
      popd
    ''}
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
    , preBuild ? null
    , postBuild ? null
    , doCheck ? true
    , preInstall ? null
    , postInstall ? null
    , meta ? {}
    , buildEnv ? defaultBuildEnv
    , reduceDeps ? true
    }: pkgs.stdenvNoCC.mkDerivation {
    inherit pname version name src sourceRoot buildInputs patches postPatch preConfigure postConfigure preBuild postBuild doCheck preInstall postInstall meta;
    nativeBuildInputs = [
      buildEnv
    ] ++ nativeBuildInputs;
    configurePhase = ''
      runHook preConfigure
      wine cmake -S ${sourceDir} -B ${buildDir} \
        -DCMAKE_BUILD_TYPE=${buildConfig} \
        -DCMAKE_INSTALL_PREFIX=Z:"$out" \
        -DCMAKE_INSTALL_INCLUDEDIR=Z:"$out"/include \
        -DBUILD_TESTING=${if doCheck then "ON" else "OFF"} \
        ${lib.escapeShellArgs cmakeFlags}
      runHook postConfigure
    '';
    buildPhase = ''
      runHook preBuild
      wine cmake --build ${buildDir} --config ${buildConfig} -j ''$NIX_BUILD_CORES
      runHook postBuild
    '';
    checkPhase = ''
      wine ctest --test-dir ${buildDir}
    '';
    installPhase = ''
      runHook preInstall
      wine cmake --install ${buildDir} --config ${buildConfig}
      ${finalizePkg {
        inherit buildInputs reduceDeps;
      }}
      runHook postInstall
    '';
  });
}
