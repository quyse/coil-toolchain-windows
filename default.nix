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

  runPackerStep =
    { name ? "packer-disk"
    , memory ? 4096
    , disk ? null # set to the previous step, null for initial step
    , iso ? null
    , provisioners
    , extraMount ? null # path to mount (actually copy) into VM as drive D:
    , extraMountIn ? true # whether to copy data into VM
    , extraMountOut ? true # whether to copy data out of VM
    , extraMountSize ? "32G"
    , beforeScript ? ""
    , afterScript ? "mv build/packer-qemu $out"
    , outputHash ? null
    , outputHashAlgo ? "sha256"
    , outputHashMode ? "flat"
    , run ? true # set to false to return generated script instead of actually running it
    , headless ? true # set to false to run VM with UI for debugging
    , meta ? null
    , impure ? false
    , debug ? false
    }: let
    guestfishCmd = ''
      ${libguestfs}/bin/guestfish \
        disk-create extraMount.img qcow2 ${extraMountSize} : \
        add extraMount.img format:qcow2 label:extraMount : \
        run : \
        part-disk /dev/disk/guestfs/extraMount mbr : \
        part-set-mbr-id /dev/disk/guestfs/extraMount 1 07 : \
        mkfs ntfs /dev/disk/guestfs/extraMount1'';
    extraMountArg = lib.escapeShellArg extraMount;
    script = ''
      export HOME="$(mktemp -d)" # fix warning by guestfish
      echo 'Executing beforeScript...'
      ${beforeScript}
      ${if extraMount != null && extraMountIn then ''
        echo 'Copying extra mount data in...'
        tar -C ${extraMountArg} -c --dereference . | ${guestfishCmd} : \
          mount /dev/disk/guestfs/extraMount1 / : \
          mkdir /${extraMountArg} : \
          tar-in - /${extraMountArg}
        rm -r ${extraMountArg}
      '' else ''
        echo 'Creating extra mount...'
        ${guestfishCmd}
      ''}
      ${lib.optionalString debug ''
        echo 'Starting socat proxying VNC as Unix socket...'
        ${pkgs.socat}/bin/socat unix-listen:vnc.socket,fork tcp-connect:127.0.0.1:5900 &
      ''}
      echo 'Starting VM...'
      PATH=${qemu}/bin:$PATH CHECKPOINT_DISABLE=1 ${packer}/bin/packer build --var cpus=$NIX_BUILD_CORES ${packerTemplateJson {
        name = "${name}.template.json";
        inherit memory disk iso provisioners headless;
        extraDisk = "extraMount.img";
      }}
      ${lib.optionalString (extraMount != null && extraMountOut) ''
        echo 'Copying extra mount data out...'
        mkdir ${extraMountArg}
        ${libguestfs}/bin/guestfish \
          add extraMount.img format:qcow2 label:extraMount readonly:true : \
          run : \
          mount-ro /dev/disk/guestfs/extraMount1 / : \
          tar-out /${extraMountArg} - | tar -C ${extraMountArg} -vxf -
      ''}
      echo 'Clearing extra mount...'
      rm extraMount.img
      echo 'Executing afterScript...'
      ${afterScript}
    '';
    env = {
      requiredSystemFeatures = ["kvm"];
    } // (lib.optionalAttrs (outputHash != null) {
      inherit outputHash outputHashAlgo outputHashMode;
    })
    // (lib.optionalAttrs (meta != null) {
      inherit meta;
    })
    // (lib.optionalAttrs impure {
      __impure = true;
    });
  in (if run then pkgs.runCommand name env else pkgs.writeScript "${name}.sh") script;

  packerTemplateJson =
    { name
    , cpus ? 1
    , memory ? 4096
    , disk ? null
    , disk_size ? "256G"
    , iso ? null
    , output_directory ? "build"
    , provisioners
    , extraDisk ? null
    , headless ? true
    }: pkgs.writeText name (builtins.toJSON {
      builders = [(
        {
          type = "qemu";
          communicator = "winrm";
          cpus = "{{ user `cpus` }}";
          inherit memory headless output_directory;
          skip_compaction = true;
          # username and password are fixed in bento's autounattend
          winrm_username = "vagrant";
          winrm_password = "vagrant";
          winrm_timeout = "30m";
          shutdown_command = ''shutdown /s /t 10 /f /d p:4:1 /c "Packer Shutdown"'';
          shutdown_timeout = "15m";
          qemuargs = [
            # https://blog.wikichoon.com/2014/07/enabling-hyper-v-enlightenments-with-kvm.html
            [ "-cpu" "qemu64,hv_relaxed,hv_spinlocks=0x1fff,hv_vapic,hv_time" ]
            # main hdd
            [ "-drive" "file=${output_directory}/packer-qemu,if=virtio,cache=unsafe,discard=unmap,detect-zeroes=unmap,format=qcow2,index=0" ]
          ] ++
          # cdroms
          lib.optionals (disk == null && iso != null) [
            # main cdrom
            [ "-drive" "file=${iso.iso},media=cdrom,index=1" ]
            # virtio-win cdrom
            [ "-drive" "file=${virtio_win_iso},media=cdrom,index=2" ]
          ] ++
          # extra hdd
          lib.optional (extraDisk != null) [ "-drive" "file=${extraDisk},if=virtio,cache=unsafe,discard=unmap,detect-zeroes=unmap,format=qcow2,index=3" ];
          # fixed VNC port for easier debugging
          vnc_port_min = 5900;
          vnc_port_max = 5900;
        }
        // (if disk != null then {
          inherit disk_size;
          disk_image = true;
          use_backing_file = true;
          iso_url = disk;
          iso_checksum = "none";
          skip_resize_disk = true;
        } else if iso != null then {
          inherit disk_size;
          iso_url = iso.iso;
          iso_checksum = iso.checksum;
          floppy_files = ["${pkgs.runCommand "autounattend-dir" {} ''
            mkdir $out
            cp ${iso.autounattend} $out/Autounattend.xml
          ''}/Autounattend.xml"];
        } else {})
      )];
      provisioners =
        lib.optional (extraDisk != null) {
          type = "powershell";
          inline = [
            "Set-Disk -Number 1 -IsOffline $False"
            "Set-Disk -Number 1 -IsReadOnly $False"
          ];
        } ++
        provisioners;
      variables = {
        cpus = toString(cpus);
      };
    });

  initialDisk = { version ? "2022" }: runPackerStep {
    name = "windows-${version}";
    iso = windowsInstallIso {
      inherit version;
    };
    extraMount = "work";
    extraMountOut = false;
    beforeScript = ''
      mkdir work
      ln -s ${writeRegistryFile {
        name = "initial.reg";
        keys = {
          # disable uac
          # https://docs.microsoft.com/en-us/windows/security/identity-protection/user-account-control/user-account-control-group-policy-and-registry-key-settings
          "HKEY_LOCAL_MACHINE\\SOFTWARE\\Microsoft\\Windows\\CurrentVersion\\Policies\\System" = {
            EnableLUA = false;
            PromptOnSecureDesktop = false;
            ConsentPromptBehaviorAdmin = 0;
            EnableVirtualization = false;
            EnableInstallerDetection = false;
          };
          # disable restore
          "HKEY_LOCAL_MACHINE\\SOFTWARE\\Policies\\Microsoft\\Windows NT\\SystemRestore" = {
            DisableSR = true;
          };
          # disable windows update
          # https://docs.microsoft.com/en-us/windows/deployment/update/waas-wu-settings
          "HKEY_LOCAL_MACHINE\\SOFTWARE\\Policies\\Microsoft\\Windows\\WindowsUpdate\\AU" = {
            NoAutoUpdate = true;
            AUOptions = 1;
          };
          # disable screensaver
          "HKEY_CURRENT_USER\\Control Panel\\Desktop" = {
            ScreenSaveActive = false;
          };
        };
      }} work/initial.reg
      ln -s ${pkgs.fetchurl {
        inherit (fixeds.fetchurl."https://www.microsoft.com/pkiops/certs/Microsoft%20Windows%20Code%20Signing%20PCA%202024.crt") url sha256 name;
      }} work/microsoft.crt
    '';
    provisioners = [
      {
        type = "powershell";
        inline = [
          # apply registry tweaks
          ''reg import F:\work\initial.reg''
          # uninstall defender
          "Uninstall-WindowsFeature -Name Windows-Defender -Remove"
          # power options
          "powercfg /setactive 8c5e7fda-e8bf-4a96-9a85-a6e23a8c635c"
          "powercfg /hibernate off"
          "powercfg /change -monitor-timeout-ac 0"
          "powercfg /change -monitor-timeout-dc 0"
          # install recent Microsoft root code signing certificate required for some software
          # see https://developercommunity.microsoft.com/t/VS-2022-Unable-to-Install-Offline/10927089
          ''Import-Certificate -FilePath F:\work\microsoft.crt -CertStoreLocation Cert:\LocalMachine\Root''
        ];
      }
      {
        type = "windows-restart";
      }
    ];
    meta = {
      license = lib.licenses.unfree;
    };
  };

  windowsInstallIso = { version }: {
    iso = pkgs.fetchurl {
      inherit (fixeds.fetchurl."${{
        # https://www.microsoft.com/en-us/evalcenter/download-windows-server-2019
        "2019" = "https://go.microsoft.com/fwlink/p/?LinkID=2195167&clcid=0x409&culture=en-us&country=US";
        # https://www.microsoft.com/en-us/evalcenter/download-windows-server-2022
        "2022" = "https://go.microsoft.com/fwlink/p/?LinkID=2195280&clcid=0x409&culture=en-us&country=US";
      }."${version}"}") url sha256 name;
      meta = {
        license = lib.licenses.unfree;
      };
    };
    checksum = "none";
    autounattend = pkgs.fetchurl {
      inherit (fixeds.fetchurl."https://raw.githubusercontent.com/chef/bento/main/packer_templates/win_answer_files/${version}/Autounattend.xml") url sha256 name;
    };
  };

  # generate .reg file given a list of actions
  writeRegistryFile =
    { name ? "registry.reg"
    , keys
    }: let
    keyAction = keyName: keyValues: if keyValues == null then ''

      [-${keyName}]
    '' else ''

      [${keyName}]
      ${lib.concatStrings (lib.mapAttrsToList valueAction keyValues)}'';
    valueAction = valueName: valueValue: ''
      ${if valueName == "" then "@" else builtins.toJSON(valueName)}=${{
        int = "dword:${toString(valueValue)}";
        bool = "dword:${if valueValue then "1" else "0"}";
        string = builtins.toJSON(valueValue);
        null = "-";
      }.${builtins.typeOf valueValue}}
    '';
  in pkgs.writeText name ''
    Windows Registry Editor Version 5.00
    ${lib.concatStrings (lib.mapAttrsToList keyAction keys)}
  '';

  virtio_win_iso = pkgs.fetchurl {
    inherit (fixeds.fetchurl."https://fedorapeople.org/groups/virt/virtio-win/direct-downloads/stable-virtio/virtio-win.iso") url sha256 name;
    meta = {
      license = lib.licenses.bsd3;
    };
  };

  wine = ((pkgs.winePackagesFor "wineWow64").minimal.override {
    x11Support = true;
    embedInstallers = true;
  }).overrideAttrs (attrs: {
    patches = attrs.patches ++ [
      # https://bugs.winehq.org/show_bug.cgi?id=51869
      ./wine_replacefile.patch
    ];
  });

  initWinePrefix = ''
    mkdir .wineprefix
    export WINEPREFIX="$(readlink -f .wineprefix)" WINEDEBUG=-all
    wineboot
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

  msvc = import ./msvc.nix {
    inherit pkgs;
    inherit (coil) toolchain-windows toolchain-msvs;
  };

  touch = {
    initialDisk = initialDisk {};
    inherit makemsix;

    autoUpdateScript = coil.toolchain.autoUpdateFixedsScript fixedsFile;
  };
};
in toolchain-windows
