# Coil Toolchain for Windows

Nix-based toolchain for Windows builds. Uses Coil Toolchain MSVS project for MSVS support.

Currently the MSVC integration uses `clang-cl` compiler instead of usual `cl`.

## Example usage

The following example builds Windows version of [SDL2](https://www.libsdl.org/). WARNING: the initial build is very heavy: it will run multiple QEMU VMs and take many GiBs of space. Subsequent builds will reuse Nix cache and run much faster.

It is easier to use the umbrella `default.nix` from the root Coil project instead of using this project directly. Clone the Coil project, and run the following (while being in the Coil project directory):

```bash
# MSVS compilers are unfree, and nixpkgs requires explicit okay
export NIXPKGS_ALLOW_UNFREE=1
# perform build
nix build -L --impure --expr 'let
  pkgs = import <nixpkgs> {};
  coil = import ./default.nix {}; # import Coil project
  inherit (coil.toolchain-windows.msvc {}) mkCmakePkg;
in mkCmakePkg {
  inherit (pkgs.SDL2) pname version src meta; # just use source from nixpkgs
  cmakeFlags = [
    "-DBUILD_SHARED_LIBS=ON"
  ];
}'
```

## Credits

This uses multiple third-party projects:

* [Packer](https://www.packer.io/) - the tool for VM provisioning
* [QEMU](https://www.qemu.org/) - for VMs on Linux
* [Wine](https://www.winehq.org/) - for running Windows binaries on Linux
* [chef/bento](https://github.com/chef/bento) - for maintained Windows autounattend scripts
* [VirtIO-Win](https://docs.fedoraproject.org/en-US/quick-docs/creating-windows-virtual-machines-using-virtio-drivers/index.html) signed driver binaries by Fedora project

Inspiration and bits and pieces from:

* [WFVM](https://git.m-labs.hk/M-Labs/wfvm)
* [StefanScherer/packer-windows](https://github.com/StefanScherer/packer-windows)
