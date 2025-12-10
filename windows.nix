{ pkgs
, lib ? pkgs.lib
, qemu
, libguestfs
, packer
, ovmf
, swtpm
, msvc
, dotnet
, fixeds
}:

rec {
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
        disk-create extraMount.qcow2 qcow2 ${extraMountSize} : \
        add extraMount.qcow2 format:qcow2 label:extraMount : \
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
        extraDisk = "extraMount.qcow2";
      }}
      ${lib.optionalString (extraMount != null && extraMountOut) ''
        echo 'Copying extra mount data out...'
        mkdir ${extraMountArg}
        ${libguestfs}/bin/guestfish \
          add extraMount.qcow2 format:qcow2 label:extraMount readonly:true : \
          run : \
          mount-ro /dev/disk/guestfs/extraMount1 / : \
          tar-out /${extraMountArg} - | tar -C ${extraMountArg} -vxf -
      ''}
      echo 'Clearing extra mount...'
      rm extraMount.qcow2
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
          # username and password are fixed in autounattend.xml
          winrm_username = "vagrant";
          winrm_password = "vagrant";
          winrm_timeout = "30m";
          shutdown_command = ''shutdown /s /t 10 /f /d p:4:1 /c "Packer Shutdown"'';
          shutdown_timeout = "15m";
          qemuargs = [
            # https://www.qemu.org/docs/master/system/i386/hyperv.html
            [ "-cpu" "host,hv_relaxed,hv_vapic,hv_spinlocks=0x1fff,hv_vpindex,hv_runtime,hv_time,hv_synic,hv_stimer,hv_tlbflush,hv_ipi,hv_frequencies" ]
            [ "-machine" "type=q35,accel=kvm" ]
            # virtio-scsi for hdds
            [ "-device" "virtio-scsi-pci,id=scsi0" ]
            # ACHI for cdroms
            [ "-device" "ahci,id=ahci1" ]
            # main ssd
            [ "-drive" "file=${output_directory}/packer-qemu,if=none,cache=unsafe,discard=unmap,detect-zeroes=unmap,format=qcow2,id=drive-hd0" ]
            [ "-device" "scsi-hd,bus=scsi0.0,lun=0,drive=drive-hd0,id=hd0,bootindex=0,rotation_rate=1" ]
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
            [ "-drive" "file=fat:floppy:${iso.floppy},format=raw,readonly=on,if=none,id=floppy0" ]
            [ "-device" "isa-fdc,id=fdc0" ]
            [ "-device" "floppy,bus=fdc0.0,drive=floppy0" ]
          ] ++
          # extra ssd
          lib.optionals (extraDisk != null) [
            [ "-drive" "file=${extraDisk},if=none,cache=unsafe,discard=unmap,detect-zeroes=unmap,format=qcow2,id=drive-hd1" ]
            [ "-device" "scsi-hd,bus=scsi0.0,lun=1,drive=drive-hd1,id=hd1,bootindex=3,rotation_rate=1" ]
          ] ++
          # extra iso
          lib.optionals (extraIso != null) [
            [ "-drive" "file=${extraIso},if=none,format=raw,media=cdrom,id=drive-cd2" ]
            [ "-device" "scsi-cd,bus=scsi0.0,lun=2,drive=drive-cd2,id=cd2,bootindex=4" ]
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
      inherit provisioners;
      variables = {
        cpus = toString(cpus);
      };
    });

  mkWindows = { version ? "2025" }: rec {
    initialDisk =  runPackerStep {
      name = "windows-${version}";
      iso = installIso;
      provisioners = [
        {
          type = "windows-restart";
        }
      ];
      meta = {
        license = lib.licenses.unfree;
      };
    };

    installIso = {
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
      inherit autounattend;
      floppy = let
        writeLines = name: lines: pkgs.writeText name (lib.concatMapStrings (line: ''
          ${line}
        '') lines);
      in pkgs.runCommand "windows-${version}-autounattend-floppy" {} ''
        mkdir $out
        cp ${autounattend} $out/Autounattend.xml

        cp ${writeRegistryFile {
          name = "windows-${version}-specialize.reg";
          keys = {
            # enable long paths
            "HKEY_LOCAL_MACHINE\\SYSTEM\\CurrentControlSet\\Control\\FileSystem".LongPathsEnabled = true;
            # disable uac
            # https://docs.microsoft.com/en-us/windows/security/identity-protection/user-account-control/user-account-control-group-policy-and-registry-key-settings
            "HKEY_LOCAL_MACHINE\\SOFTWARE\\Microsoft\\Windows\\CurrentVersion\\Policies\\System" = {
              EnableLUA = false;
              PromptOnSecureDesktop = false;
              ConsentPromptBehaviorAdmin = 0;
              EnableVirtualization = false;
              EnableInstallerDetection = false;
            };
            # disable system restore
            "HKEY_LOCAL_MACHINE\\SOFTWARE\\Policies\\Microsoft\\Windows NT\\SystemRestore".DisableSR = true;
            # disable windows update
            # https://docs.microsoft.com/en-us/windows/deployment/update/waas-wu-settings
            "HKEY_LOCAL_MACHINE\\SOFTWARE\\Policies\\Microsoft\\Windows\\WindowsUpdate\\AU" = {
              NoAutoUpdate = true;
              AUOptions = 1;
            };
            # disable windows defender
            "HKEY_LOCAL_MACHINE\\SOFTWARE\\Policies\\Microsoft\\Windows Defender".DisableAntiSpyware = true;
            "HKEY_LOCAL_MACHINE\\SOFTWARE\\Policies\\Microsoft\\Windows Defender\\Real-Time Protection".DisableRealtimeMonitoring = true;
            # disable hibernation and fast startup
            "HKEY_LOCAL_MACHINE\\SYSTEM\\CurrentControlSet\\Control\\Session Manager\\Power" = {
              HibernateEnabled = false;
              HiberbootEnabled = false;
            };
            # disable screensaver
            "HKEY_USERS\\DefaultUser\\Control Panel\\Desktop" = {
              ScreenSaveActive = false;
            };
            # set explorer options
            "HKEY_USERS\\DefaultUser\\Software\\Microsoft\\Windows\\CurrentVersion\\Explorer\\Advanced" = {
              # show file extensions
              HideFileExt = false;
              # show hidden files
              Hidden = 1;
            };
          };
        }} $out/specialize.reg

        cp ${writeLines "windows-${version}-specialize.ps1" [
          # disable filesystem access time
          ''fsutil behavior set disablelastaccess 1''
          # move pagefile to D:
          ''(Get-WmiObject -Query "select * from Win32_PageFileSetting").delete()''
          ''Set-WMIInstance -Class Win32_PageFileSetting -Arguments @{Name="D:\pagefile.sys"; MaximumSize=0}''
          # uninstall defender
          ''Uninstall-WindowsFeature -Name Windows-Defender -Remove''
          # disable Windows Search
          ''sc config WSearch start= disabled''
          # power options
          ''powercfg /setactive 8c5e7fda-e8bf-4a96-9a85-a6e23a8c635c''
          ''powercfg /hibernate off''
          ''powercfg /change -monitor-timeout-ac 0''
          ''powercfg /change -monitor-timeout-dc 0''
          # confirm Secure Boot
          ''Confirm-SecureBootUEFI''
          # apply registry tweaks
          ''reg load "HKU\DefaultUser" "C:\Users\Default\NTUSER.DAT"''
          ''reg import "A:\specialize.reg"''
          ''reg unload "HKU\DefaultUser"''
          # install recent Microsoft root code signing certificate required for some software
          # see https://developercommunity.microsoft.com/t/VS-2022-Unable-to-Install-Offline/10927089
          ''Import-Certificate -FilePath "A:\microsoft.crt" -CertStoreLocation "Cert:\LocalMachine\Root"''
        ]} $out/specialize.ps1

        cp ${pkgs.fetchurl {
          inherit (fixeds.fetchurl."https://www.microsoft.com/pkiops/certs/Microsoft%20Windows%20Code%20Signing%20PCA%202024.crt") url sha256 name;
        }} $out/microsoft.crt
      '';
    };

    initialDiskPlus = runPackerStep {
      name = "windows-plus-${version}";
      disk = initialDisk;
      extraMount = "work";
      extraMountOut = false;
      beforeScript = ''
        mkdir work
        ln -s \
          ${msvc.redist_x64.installer}/vc_redist.x64.exe \
          ${msvc.redist_x86.installer}/vc_redist.x86.exe \
          work/
        ln -s ${dotnet} work/dotnet
      '';
      provisioners = [
        {
          type = "windows-shell";
          inline = [''
            D:\work\vc_redist.x64.exe /install /quiet /norestart
            D:\work\vc_redist.x86.exe /install /quiet /norestart
            xcopy D:\work\dotnet "C:\Program Files\dotnet" /s /i /y /q
          ''];
        }
      ];
    };

    autounattend = mkAutounattend {
      virtioSubpath = {
        "2019" = "2k19";
        "2022" = "2k22";
        "2025" = "2k25";
      }."${version}";
      virtioDriversDuringSetup = [
        "Balloon"
        "NetKVM"
        "pvpanic"
        "qemupciserial"
        "qxldod"
        "vioinput"
        "viorng"
        "vioscsi"
        "vioserial"
        "viostor"
      ];
      virtioDrivers = [
        "Balloon"
        "fwcfg"
        "NetKVM"
        "pvpanic"
        "qemufwcfg"
        "qemupciserial"
        "qxl"
        "qxldod"
        "smbus"
        "sriov"
        "viofs"
        "viogpudo"
        "vioinput"
        "viomem"
        "viorng"
        "vioscsi"
        "vioserial"
        "viostor"
      ];
    };
    mkAutounattend = { virtioSubpath, virtioDriversDuringSetup, virtioDrivers }: let
      # driver paths for Microsoft-Windows-PnpCustomizations{,Non}WinPE components
      mkPnpCustomizations = drivers: {
        DriverPaths.PathAndCredentials = lib.pipe drivers [
          (map (driver: lib.nameValuePair driver {
            Path = ''E:\${driver}\${virtioSubpath}\amd64'';
          }))
          lib.listToAttrs
          keyedSet
        ];
      };
      keyedSet = lib.mapAttrsToList (key: value: value // {
        "@wcm:action" = "add";
        "@wcm:keyValue" = key;
      });
      orderedList = lib.imap0 (i: value: value // {
        "@wcm:action" = "add";
        Order = i + 1;
      });
    in mkAutounattendInternal {
      windowsPE = {
        # drivers necessary during setup
        Microsoft-Windows-PnpCustomizationsWinPE = mkPnpCustomizations virtioDriversDuringSetup;
        # locales
        Microsoft-Windows-International-Core-WinPE = {
          SetupUILanguage.UILanguage = "en-US";
          InputLocale = "en-US";
          SystemLocale = "en-US";
          UILanguage = "en-US";
          UILanguageFallback = "en-US";
          UserLocale = "en-US";
        };
        # disk partitions
        Microsoft-Windows-Setup = {
          DiskConfiguration.Disk = {
            "@wcm:action" = "add";
            CreatePartitions.CreatePartition = orderedList [
              {
                Type = "EFI";
                Size = 256;
              }
              {
                Type = "MSR";
                Size = 128;
              }
              {
                Type = "Primary";
                Extend = true;
              }
            ];
            ModifyPartitions.ModifyPartition = orderedList [
              {
                Format = "FAT32";
                Label = "EFI";
                PartitionID = 1;
              }
              {
                Format = "NTFS";
                Label = "Windows";
                Letter = "C";
                PartitionID = 3;
              }
            ];
            DiskID = 0;
            WillWipeDisk = true;
          };
          ImageInstall.OSImage = {
            Compact = true;
            InstallFrom.MetaData = {
              "@wcm:action" = "add";
              Key = "/IMAGE/NAME";
              Value = "Windows Server ${version} SERVERSTANDARD";
            };
            InstallTo = {
              DiskID = 0;
              PartitionID = 3;
            };
          };
          UserData = {
            AcceptEula = true;
            FullName = "Vagrant";
            Organization = "Bento by Progress Chef";
          };
          DynamicUpdate.Enable = false;
        };
      };
      offlineServicing = {
        # automount all storage
        Microsoft-Windows-PartitionManager.SanPolicy = 1;
        # drivers to install
        Microsoft-Windows-PnpCustomizationsNonWinPE = mkPnpCustomizations virtioDrivers;
        # disable UAC
        Microsoft-Windows-LUA-Settings.EnableLUA = false;
        # disable BitLocker encryption
        Microsoft-Windows-SecureStartup-FilterDriver.PreventDeviceEncryption = true;
      };
      specialize = {
        Microsoft-Windows-Deployment.RunSynchronous.RunSynchronousCommand = orderedList (map (command: {
          Path = command;
        }) [
          ''powershell -File A:\specialize.ps1''
        ]);
        Microsoft-Windows-ServerManager-SvrMgrNc.DoNotOpenServerManagerAtLogon = true;
        # disable IE hardened configuration
        Microsoft-Windows-IE-ESC = {
          IEHardenAdmin = false;
          IEHardenUser = false;
        };
        # disable System Restore
        Microsoft-Windows-SystemRestore-Main.DisableSR = true;
        Microsoft-Windows-SystemSettingsThreshold.DisplayNetworkSelection = false;
        # firewall settings
        Networking-MPSSVC-Svc.FirewallGroups.FirewallGroup = keyedSet {
          WindowsRemoteManagement = {
            Active = true;
            Group = "Windows Remote Management";
            Profile = "all";
          };
          RemoteAdministration = {
            Active = true;
            Group = "Remote Administration";
            Profile = "all";
          };
        };
        # do not participate in customer experience improvement program
        Microsoft-Windows-SQMApi.CEIPEnabled = 0;
        # disable auto activation
        Microsoft-Windows-Security-SPP-UX.SkipAutoActivation = true;
      };
      oobeSystem = {
        # locales
        Microsoft-Windows-International-Core = {
          InputLocale = "en-US";
          SystemLocale = "en-US";
          UILanguage = "en-US";
          UserLocale = "en-US";
        };
        Microsoft-Windows-Shell-Setup = {
          # disable OOBE crap
          OOBE = {
            HideEULAPage = true;
            HideLocalAccountScreen = true;
            HideOEMRegistrationScreen = true;
            HideOnlineAccountScreens = true;
            HideWirelessSetupInOOBE = true;
            NetworkLocation = "Work";
            ProtectYourPC = 3;
            SkipMachineOOBE = true;
            SkipUserOOBE = true;
            VMModeOptimizations = {
              SkipAdministratorProfileRemoval = true;
              SkipNotifyUILanguageChange = true;
              SkipWinREInitialization = true;
            };
          };
          TimeZone = "UTC";
          # user accounts
          UserAccounts = {
            AdministratorPassword = {
              Value = "vagrant";
              PlainText = true;
            };
            LocalAccounts.LocalAccount = {
              "@wcm:action" = "add";
              Password = {
                Value = "vagrant";
                PlainText = true;
              };
              Description = "Vagrant User";
              DisplayName = "vagrant";
              Group = "administrators";
              Name = "vagrant";
            };
          };
          AutoLogon = {
            Password = {
              Value = "vagrant";
              PlainText = true;
            };
            Username = "vagrant";
            Enabled = true;
          };
          FirstLogonCommands.SynchronousCommand = orderedList (map (command: {
            CommandLine = command;
          }) [
            # Set Execution Policy 64 Bit
            ''%windir%\System32\WindowsPowerShell\v1.0\powershell.exe -Command "Set-ExecutionPolicy -ExecutionPolicy RemoteSigned -Force"''
            # Set Execution Policy 32 Bit
            ''%windir%\SysWOW64\cmd.exe /c powershell -Command "Set-ExecutionPolicy -ExecutionPolicy RemoteSigned -Force"''
            # Sets detected network connections to private to allow start of winrm
            ''%windir%\System32\WindowsPowerShell\v1.0\powershell.exe -Command Get-NetConnectionProfile | Set-NetConnectionProfile -NetworkCategory "Private"''
            # Allows winrm over public profile interfaces
            ''%windir%\System32\WindowsPowerShell\v1.0\powershell.exe -Command Set-NetFirewallRule -Name "WINRM-HTTP-In-TCP" -RemoteAddress Any''
            # winrm quickconfig -q
            ''%windir%\System32\cmd.exe /c winrm quickconfig -q''
            # winrm quickconfig -transport:http
            ''%windir%\System32\cmd.exe /c winrm quickconfig -transport:http''
            # Win RM MaxTimoutms
            ''%windir%\System32\cmd.exe /c winrm set winrm/config @{MaxTimeoutms="1800000"}''
            # Win RM MaxMemoryPerShellMB
            ''%windir%\System32\cmd.exe /c winrm set winrm/config/winrs @{MaxMemoryPerShellMB="2048"}''
            # Win RM AllowUnencrypted
            ''%windir%\System32\cmd.exe /c winrm set winrm/config/service @{AllowUnencrypted="true"}''
            # Win RM auth Basic
            ''%windir%\System32\cmd.exe /c winrm set winrm/config/service/auth @{Basic="true"}''
            # Win RM client auth Basic
            ''%windir%\System32\cmd.exe /c winrm set winrm/config/client/auth @{Basic="true"}''
            # Win RM listener Address/Port
            ''%windir%\System32\cmd.exe /c winrm set winrm/config/listener?Address=*+Transport=HTTP @{Port="5985"}''
            # Win RM port open
            ''%windir%\System32\cmd.exe /c netsh firewall add portopening TCP 5985 "Port 5985"''
            # Stop Win RM Service
            ''%windir%\System32\cmd.exe /c net stop winrm''
            # Win RM Autostart
            ''%windir%\System32\cmd.exe /c sc config winrm start= auto''
            # Start Win RM Service
            ''%windir%\System32\cmd.exe /c net start winrm''
          ]);
        };
        # remove Windows Recovery Environment
        Microsoft-Windows-WinRE-RecoveryAgent.UninstallWindowsRE = true;
      };
    };
    # make autounattend.xml from a two-level map (pass => component => ...)
    mkAutounattendInternal = passesComponents: pkgs.runCommand "autounattend-${version}.xml" {
      nativeBuildInputs = [
        pkgs.yq
      ];
    } ''
      echo '<?xml version="1.0" encoding="utf-8"?>' > $out
      yq -Sx . < ${pkgs.writeText "autounattend-${version}.json" (builtins.toJSON {
        unattend = {
          "@xmlns" = "urn:schemas-microsoft-com:unattend";
          "@xmlns:wcm" = "http://schemas.microsoft.com/WMIConfig/2002/State";
          "@xmlns:xsi" = "http://www.w3.org/2001/XMLSchema-instance";
          settings = lib.mapAttrsToList (pass: passDesc: {
            "@pass" = pass;
            component = lib.mapAttrsToList (component: componentDesc: componentDesc // {
              "@name" = component;
              "@processorArchitecture" = "amd64";
              "@publicKeyToken" = "31bf3856ad364e35";
              "@language" = "neutral";
              "@versionScope" = "nonSxS";
            }) passDesc;
          }) passesComponents;
        };
      })} >> $out
    '';
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
}
