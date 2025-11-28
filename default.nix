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

  runPackerStep =
    { name
    , memory ? 4096
    , disk ? null # set to the previous step, null for initial step
    , iso ? null
    , provisioners
    , extraMount ? null # path to mount (actually copy) into VM as drive D:
    , extraMountIn ? true # whether to copy data into VM
    , extraMountOut ? true # whether to copy data out of VM
    , extraMountSize ? "32G"
    , extraIso ? null
    , beforeScript ? ""
    , afterScript ? ''
        mkdir $out
        mv build/packer-qemu $out/image.qcow2
        mv VARS.fd tpm $out/
      ''
    , outputHash ? null
    , outputHashAlgo ? "sha256"
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
      export HOME="$(mktemp -d)" # fix guestfish warning
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
      echo 'Starting swtpm...'
      if [ ! -d tpm ]
      then
        ${if disk != null
          then "cp -r --no-preserve=mode ${disk}/tpm tpm"
          else "mkdir tpm"
        }
      fi
      ${swtpm}/bin/swtpm socket --tpm2 --tpmstate dir=tpm --ctrl type=unixio,path=tpm.sock --daemon --terminate
      echo 'Starting VM...'
      if [ ! -f VARS.fd ]
      then
        cp --no-preserve=mode ${if disk != null then "${disk}/VARS.fd" else "${ovmf}/FV/OVMF_VARS.ms.fd"} ./VARS.fd
      fi
      PATH=${qemu}/bin:$PATH ${lib.optionalString debug "PACKER_LOG=1"} CHECKPOINT_DISABLE=1 ${packer}/bin/packer build --var cpus=$NIX_BUILD_CORES ${packerTemplateJson {
        name = "${name}.template.json";
        inherit memory iso extraIso provisioners headless debug;
        disk = if disk != null then "${disk}/image.qcow2" else null;
        extraDisk = "extraMount.img";
      }}
      echo 'Clearing RAM file...'
      rm pc.ram
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
      inherit outputHash outputHashAlgo;
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
    , extraIso ? null
    , output_directory ? "build"
    , provisioners
    , extraDisk ? null
    , headless ? true
    , debug ? false
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
            # https://www.qemu.org/docs/master/system/i386/hyperv.html
            [ "-cpu" "host,hv_relaxed,hv_vapic,hv_spinlocks=0x1fff,hv_vpindex,hv_runtime,hv_time,hv_synic,hv_stimer,hv_tlbflush,hv_ipi,hv_frequencies" ]
            # file-backed memory
            [ "-machine" "type=q35,accel=kvm,memory-backend=pc.ram" ]
            [ "-object" "memory-backend-file,id=pc.ram,size=${toString memory}M,mem-path=pc.ram,prealloc=off,share=on,discard-data=on" ]
            # ACHI for hdds
            [ "-device" "ahci,id=ahci0" ]
            # ACHI for cdroms
            [ "-device" "ahci,id=ahci1" ]
            # main hdd
            [ "-drive" "file=${output_directory}/packer-qemu,if=none,cache=unsafe,discard=unmap,detect-zeroes=unmap,format=qcow2,id=drive-hd0" ]
            [ "-device" "ide-hd,bus=ahci0.0,drive=drive-hd0,id=hd0,bootindex=0" ]
            # UEFI
            [ "-drive" "if=pflash,format=raw,readonly=on,file=${ovmf}/FV/OVMF_CODE.ms.fd" ]
            [ "-drive" "if=pflash,format=raw,file=VARS.fd" ]
            # TPM
            [ "-chardev" "socket,id=chrtpm,path=tpm.sock" ]
            [ "-tpmdev" "emulator,id=tpm0,chardev=chrtpm" ]
            [ "-device" "tpm-tis,tpmdev=tpm0" ]
            # better controls for debugging
            [ "-usb" ] [ "-device" "usb-tablet" ]
          ] ++
          # cdroms and floppy
          lib.optionals (disk == null && iso != null) [
            # main cdrom
            [ "-drive" "file=${iso.iso},if=none,format=raw,media=cdrom,id=drive-cd0" ]
            [ "-device" "ide-cd,bus=ahci1.0,drive=drive-cd0,id=cd0,bootindex=1" ]
            # virtio-win cdrom
            [ "-drive" "file=${virtio_win_iso},if=none,format=raw,media=cdrom,id=drive-cd1" ]
            [ "-device" "ide-cd,bus=ahci1.1,drive=drive-cd1,id=cd1,bootindex=2" ]
            # floppy
            [ "-drive" "file=fat:floppy:${pkgs.runCommand "autounattend-dir" {} ''
              mkdir $out
              cp ${iso.autounattend} $out/Autounattend.xml
            ''},format=raw,readonly=on,if=none,id=floppy0" ]
            [ "-device" "isa-fdc,id=fdc0" ]
            [ "-device" "floppy,bus=fdc0.0,drive=floppy0" ]
          ] ++
          # extra hdd
          lib.optionals (extraDisk != null) [
            [ "-drive" "file=${extraDisk},if=none,cache=unsafe,discard=unmap,detect-zeroes=unmap,format=qcow2,id=drive-hd1" ]
            [ "-device" "ide-hd,bus=ahci0.1,drive=drive-hd1,id=hd1,bootindex=3" ]
          ] ++
          # extra iso
          lib.optionals (extraIso != null) [
            [ "-drive" "file=${extraIso},if=none,format=raw,media=cdrom,id=drive-cd2" ]
            [ "-device" "ide-cd,bus=ahci0.2,drive=drive-cd2,id=cd2,bootindex=4" ]
          ];
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
          boot_command = ["<enter><wait><enter><wait><enter>"]; # "press any key to boot from cd"
          boot_wait = "1s";
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

  initialDisk = { version ? "2025" }: runPackerStep {
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
          ''reg import D:\work\initial.reg''
          # uninstall defender
          "Uninstall-WindowsFeature -Name Windows-Defender -Remove"
          # power options
          "powercfg /setactive 8c5e7fda-e8bf-4a96-9a85-a6e23a8c635c"
          "powercfg /hibernate off"
          "powercfg /change -monitor-timeout-ac 0"
          "powercfg /change -monitor-timeout-dc 0"
          # install recent Microsoft root code signing certificate required for some software
          # see https://developercommunity.microsoft.com/t/VS-2022-Unable-to-Install-Offline/10927089
          ''Import-Certificate -FilePath D:\work\microsoft.crt -CertStoreLocation Cert:\LocalMachine\Root''
          # confirm Secure Boot
          ''Confirm-SecureBootUEFI''
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
        # https://www.microsoft.com/en-us/evalcenter/download-windows-server-2025
        "2025" = "https://go.microsoft.com/fwlink/?linkid=2293312&clcid=0x409&culture=en-us&country=us";
      }."${version}"}") url sha256 name;
      meta = {
        license = lib.licenses.unfree;
      };
    };
    checksum = "none";
    autounattend = ./autounattend + "/${version}.xml";
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

  wine = (pkgs.winePackagesFor "wineWow64").minimal;

  initWinePrefix = ''
    echo -n 'Initializing Wine prefix... ' >&2
    mkdir .wineprefix
    export WINEPREFIX="$(readlink -f .wineprefix)" WINEDEBUG=-all
    wineboot
    echo ' done.' >&2
  '';

  installWineMono = let
    version = "10.3.0";
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

  msvc = import ./msvc.nix {
    inherit pkgs fixeds;
    inherit (coil) toolchain-windows toolchain-msvs;
  };

  mkDotnet = version: pkgs.stdenvNoCC.mkDerivation {
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
  dotnet8 = mkDotnet "8.0";
  dotnet9 = mkDotnet "9.0";
  dotnet10 = mkDotnet "10.0";

  touch = {
    initialDisk = initialDisk {};
    inherit makemsix;

    inherit (msvc {}) get-clang-version;

    inherit dotnet8 dotnet9 dotnet10;

    autoUpdateScript = coil.toolchain.autoUpdateFixedsScript fixedsFile;
  };
};
in toolchain-windows
