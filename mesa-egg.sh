#!/bin/bash
# Build the egg's patched Mesa for Firefox's WebGPU present-without-readback
# swap chain and install it under /opt/mesa-egg. Runs inside `egg build` as
# root with network. Only Firefox uses it (through /usr/local/bin/firefox);
# the system Mesa that GNOME runs on is untouched.
#
# What the patch (mesa-egg-<minor>.patch, applied to the distribution's mesa source) does:
#  - Venus (the Vulkan driver on the host GPU) also claims OPAQUE_FD binary
#    semaphores and exports them as the sync file it already has: Firefox's
#    wgpu gates its dma_buf swap chain on OPAQUE_FD export.
#  - virgl (the GL driver) exposes GL_EXT_semaphore(_fd) over its existing
#    in-fence path, so Firefox's compositor waits for the WebGPU frame.
#  - The GL semaphore entry points are allowed on a GLES 3.0 context (Mesa's
#    API table tags them 3.2; virgl on this host is 3.0).
# The host half is the runner's EGG_VENUS_SHARED_PRESENT (on by default).
# Only the virgl GL driver and the virtio Vulkan driver are built, without
# LLVM: about two minutes on four vCPUs. Build dependencies are removed again.
set -euo pipefail
SRC=/root/mesa-src
PREFIX=/opt/mesa-egg
HERE="$(cd "$(dirname "$0")" && pwd)"

dpkg-query -W -f='${binary:Package}\n' | sort > /tmp/mesa-egg-pkgs-before
# Source packages on: Ubuntu's and Debian's deb822 files (Types: deb) and any
# classic one-line list (deb ...) get their deb-src twin.
sed -i 's/^Types: deb$/Types: deb deb-src/' /etc/apt/sources.list.d/*.sources 2>/dev/null || true
for l in /etc/apt/sources.list /etc/apt/sources.list.d/*.list; do
  [ -f "$l" ] && grep -q '^deb ' "$l" && ! grep -q '^deb-src ' "$l" && sed -n 's/^deb /deb-src /p' "$l" >> "$l"
done
# The build VM's clock can trail real time by an hour; a repository index
# signed in that hour is "not valid yet" to apt and the update aborts
# (2026-10-25, packages.mozilla.org). The signatures are still checked.
APT_UPDATE="apt-get -o Acquire::Check-Date=false update"
$APT_UPDATE
DEBIAN_FRONTEND=noninteractive apt-get build-dep -y mesa
DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends meson ninja-build pkg-config

rm -rf "$SRC"; mkdir -p "$SRC"; cd "$SRC"
apt-get source mesa
cd "$SRC"/mesa-*/
# One patch per Mesa minor the eggs ship: Ubuntu 26.04's 26.0, Debian 13's 25.0.
MESA_MINOR=$(basename "$PWD" | sed 's/^mesa-//; s/^\([0-9]*\.[0-9]*\).*/\1/')
PATCH="$HERE/mesa-egg-$MESA_MINOR.patch"
[ -f "$PATCH" ] || { echo "mesa-egg: no patch for Mesa $MESA_MINOR (have: $(ls "$HERE"/mesa-egg-*.patch | xargs -n1 basename | tr '\n' ' '))"; exit 1; }
patch -p1 < "$PATCH"
XML=$(find src -name EXT_external_objects.xml | head -1)
[ -n "$XML" ] || { echo "mesa-egg: EXT_external_objects.xml not found"; exit 1; }
sed -i 's/es2="3.2"/es2="2.0"/' "$XML"
grep -q 'es2="2.0"' "$XML"

meson setup build-egg --prefix="$PREFIX" --libdir=lib/aarch64-linux-gnu --buildtype=release \
  -Dgallium-drivers=virgl -Dvulkan-drivers=virtio -Dllvm=disabled -Dplatforms=x11,wayland \
  -Degl=enabled -Dgles1=disabled -Dgles2=enabled -Dglx=dri -Dgbm=enabled -Dglvnd=enabled \
  -Dvideo-codecs= -Dtools= -Dvalgrind=disabled -Dlibunwind=disabled -Dlmsensors=disabled \
  -Dzstd=enabled -Dshared-glapi=enabled -Dmicrosoft-clc=disabled
ninja -C build-egg
rm -rf "$PREFIX"
ninja -C build-egg install
cd /; rm -rf "$SRC"

# Back to the package set the egg had, plus nothing: the build deps go, and
# the runtime deps of what was installed are proved present afterwards.
sed -i 's/^Types: deb deb-src$/Types: deb/' /etc/apt/sources.list.d/*.sources 2>/dev/null || true
for l in /etc/apt/sources.list /etc/apt/sources.list.d/*.list; do [ -f "$l" ] && sed -i '/^deb-src /d' "$l"; done
dpkg-query -W -f='${binary:Package}\n' | sort > /tmp/mesa-egg-pkgs-after
comm -13 /tmp/mesa-egg-pkgs-before /tmp/mesa-egg-pkgs-after | xargs -r env DEBIAN_FRONTEND=noninteractive apt-get purge -y
DEBIAN_FRONTEND=noninteractive apt-get autoremove -y --purge
$APT_UPDATE
rm -f /tmp/mesa-egg-pkgs-before /tmp/mesa-egg-pkgs-after

for f in "$PREFIX"/lib/aarch64-linux-gnu/libvulkan_virtio.so "$PREFIX"/lib/aarch64-linux-gnu/libgallium-*.so "$PREFIX"/lib/aarch64-linux-gnu/libEGL_mesa.so.0 "$PREFIX"/lib/aarch64-linux-gnu/libgbm.so.1; do
  test -f "$f"
  # Resolved the way the Firefox wrapper runs them: with /opt/mesa-egg on the
  # library path (libEGL_mesa needs its sibling libgallium from there).
  if LD_LIBRARY_PATH="$PREFIX/lib/aarch64-linux-gnu" ldd "$f" | grep -q "not found"; then echo "mesa-egg: $f has unresolved libraries:"; LD_LIBRARY_PATH="$PREFIX/lib/aarch64-linux-gnu" ldd "$f" | grep "not found"; exit 1; fi
done
test -f "$PREFIX"/share/vulkan/icd.d/virtio_icd.aarch64.json
test -f "$PREFIX"/share/glvnd/egl_vendor.d/50_mesa.json
echo "mesa-egg: installed under $PREFIX"
