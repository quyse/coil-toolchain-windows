{ stdenv
, lib
, fetchgit
, cmake
, ninja
, clang
, icu
, zlib
, fixeds
}:

stdenv.mkDerivation rec {
  name = "makemsix";
  src = fetchgit {
    inherit (fixeds.fetchgit."https://github.com/microsoft/msix-packaging.git") url rev sha256;
  };
  nativeBuildInputs = [
    cmake
    ninja
    clang
  ];
  buildInputs = [
    icu
    zlib
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
    patchelf --set-rpath "${lib.makeLibraryPath buildInputs}:$out/lib" $out/bin/*
  '';
}
