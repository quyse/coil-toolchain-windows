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

  # initializes wineprefix by doing lightweight copy of template wineprefix
  # symlink all files from drive_c instead of copying them
  initWinePrefix = ''
    echo -n 'Initializing Wine prefix from template... ' >&2
    mkdir .wineprefix
    export WINEPREFIX="$(readlink -f .wineprefix)" WINEDEBUG=-all
    cp -rs --no-preserve=mode ${templateWinePrefix}/drive_c "$WINEPREFIX"/drive_c
    cp -r --no-preserve=mode ${templateWinePrefix}/{*.reg,dosdevices,.update-timestamp} "$WINEPREFIX"/
    wineboot -u
    echo ' done.' >&2
  '';

  templateWinePrefix = pkgs.runCommand "wineprefix.template" {
    nativeBuildInputs = [
      wine
    ];
  } ''
    export WINEPREFIX=$out WINEDEBUG=-all
    mkdir $WINEPREFIX
    wineboot
    wineserver -k
  '';

  installWineMono = let
    version = "11.0.0";
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
  makemsix = pkgs.callPackage ./makemsix.nix {
    inherit fixeds;
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
