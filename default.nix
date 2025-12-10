{ pkgs
, lib ? pkgs.lib
, coil
, fixedsFile ? ./fixeds.json
, fixeds ? lib.importJSON fixedsFile
}: let

toolchain-windows = rec {
  qemu = pkgs.qemu_kvm;
  libguestfs = pkgs.libguestfs-with-appliance;
  # pre-BSL version of packer
  packer = pkgs.callPackage ./packer.nix {};
  ovmf = pkgs.OVMFFull.fd;
  inherit (pkgs) swtpm;

  inherit (import ./windows.nix {
    inherit pkgs qemu libguestfs packer ovmf swtpm msvc dotnet fixeds;
  }) runPackerStep mkWindows;

  windows = mkWindows {};

  wine = (pkgs.winePackagesFor "wineWow64").minimal;

  initWinePrefix = ''
    echo -n 'Initializing Wine prefix... ' >&2
    mkdir .wineprefix
    export WINEPREFIX="$(readlink -f .wineprefix)" WINEDEBUG=-all
    wineboot
    echo ' done.' >&2
  '';

  installWineMono = let
    version = "10.4.0";
  in ''
    echo -n 'Installing Wine Mono... ' >&2
    msiexec /qn /i ${pkgs.fetchurl {
      inherit (fixeds.fetchurl."https://dl.winehq.org/wine/wine-mono/${version}/wine-mono-${version}-x86.msi") url sha256 name;
    }}
    echo ' done.' >&2
  '';

  # convert list of unix-style paths to windows-style PATH var
  # paths must be pre-shell-escaped if needed
  makeWinePaths = paths: lib.concatStringsSep ";" (map (path: "$(winepath -w ${path})") paths);

  # makemsix tool
  makemsix = pkgs.stdenv.mkDerivation rec {
    name = "makemsix";
    src = pkgs.fetchgit {
      inherit (fixeds.fetchgit."https://github.com/microsoft/msix-packaging.git") url rev sha256;
    };
    buildInputs = [
      pkgs.icu
      pkgs.zlib
    ];
    nativeBuildInputs = [
      pkgs.cmake
      pkgs.ninja
      pkgs.clang
    ];
    preConfigure = ''
      # icu headers require at least C++ 17 since v75
      find . -name CMakeLists.txt -exec sed -iE 's/CMAKE_CXX_STANDARD 14/CMAKE_CXX_STANDARD 17/' {} \;
    '';
    cmakeFlags = [
      "-DCMAKE_CXX_COMPILER=clang++"
      "-DCMAKE_C_COMPILER=clang"
      "-DLINUX=ON"
      "-DMSIX_PACK=ON"
      "-DUSE_VALIDATION_PARSER=ON"
      "-DMSIX_SAMPLES=OFF"
      "-DMSIX_TESTS=OFF"
    ];
    installPhase = ''
      mkdir -p $out/{bin,lib}
      cp bin/makemsix $out/bin/
      cp lib/libmsix.so $out/lib/
      patchelf --set-rpath "${pkgs.lib.makeLibraryPath buildInputs}:$out/lib" $out/bin/*
    '';
  };

  msvc = mkMsvc {};
  mkMsvc = import ./msvc.nix {
    inherit pkgs fixeds;
    inherit (coil) toolchain-windows toolchain-msvs;
  };

  mkDotnet = { version }: pkgs.stdenvNoCC.mkDerivation {
    pname = "dotnet";
    inherit version;
    nativeBuildInputs = [
      pkgs.unzip
    ];
    buildCommand = ''
      mkdir $out
      unzip ${pkgs.fetchurl {
        inherit (fixeds.fetchurl."https://aka.ms/dotnet/${version}/dotnet-runtime-win-x64.zip") url name sha256;
      }} -d $out
    '';
    meta.license = lib.licenses.mit;
  };
  dotnet10 = mkDotnet {
    version = "10.0";
  };
  dotnet9 = mkDotnet {
    version = "9.0";
  };
  dotnet8 = mkDotnet {
    version = "8.0";
  };

  dotnet = pkgs.symlinkJoin {
    name = "dotnet";
    paths = [
      dotnet10
      dotnet9
      dotnet8
    ];
  };

  touch = {
    inherit (windows) initialDiskPlus;
    inherit makemsix;
    inherit (msvc) get-clang-version;
    inherit dotnet;

    autoUpdateScript = coil.toolchain.autoUpdateFixedsScript fixedsFile;
  };
};
in toolchain-windows
