#!/bin/bash
# Blackwell Engine Native: Wine 11.18 for arm64 + Highball's patches-arm64 (branch arm64-games, through 0054) +
# Blackwell's Xbox patches ported to 11.18 (engine/patches-arm64-xbox), built natively on an Apple silicon Mac.
#   W=<work folder> bash engine/build-native.sh
# The work folder holds src/wine-11.18 (WineHQ's tarball, patches applied: see engine/inputs-native.json),
# toolchains/llvm-mingw (20260922) and build/. Homebrew: bison pkg-config ccache gnutls freetype sdl2 molten-vk
# vulkan-headers. Then engine/package-native.sh makes the bundle MetalHorizon installs.
set -euo pipefail
W="${W:-$HOME/BlackwellEngine-build/arm64}"
export PATH="$W/toolchains/llvm-mingw/bin:$(brew --prefix bison)/bin:$PATH"
export MACOSX_DEPLOYMENT_TARGET=11.0
cd $W/build
if [ ! -f Makefile ]; then
  ../src/wine-11.18/configure \
    --prefix="$W/out/engine" \
    --enable-archs=arm64ec,aarch64,i386 \
    --with-mingw \
    --without-x --without-alsa --without-capi --with-coreaudio --without-cups --without-dbus \
    --without-fontconfig --with-freetype --with-gnutls --without-gphoto --without-gstreamer \
    --without-krb5 --without-netapi --without-oss --without-pulse \
    --without-sane --with-sdl --without-udev --without-usb --without-v4l2 \
    --without-pcap --without-ffmpeg --disable-tests --with-vulkan \
    CPPFLAGS="-I$(brew --prefix vulkan-headers)/include -I$(brew --prefix)/include" LDFLAGS="-L$(brew --prefix molten-vk)/lib -L$(brew --prefix)/lib" \
    CC="ccache /usr/bin/clang" CXX="ccache /usr/bin/clang++" \
    arm64ec_CC="ccache arm64ec-w64-mingw32-clang" aarch64_CC="ccache aarch64-w64-mingw32-clang" \
    i386_CC="ccache i686-w64-mingw32-clang" > ../configure.log 2>&1 || { tail -30 ../configure.log; exit 1; }
fi
grep -E "SONAME_LIB(VULKAN|FREETYPE|GNUTLS|SDL2) " include/config.h
make -j"$(sysctl -n hw.ncpu)" > ../make.log 2>&1 || { grep -E "error" ../make.log | head -30; tail -20 ../make.log; exit 1; }
rm -rf $W/out/engine && make install-lib > ../install.log 2>&1
echo BUILD-OK
