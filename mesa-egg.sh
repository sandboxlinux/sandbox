#!/bin/bash
# Build the egg's Mesa from EggRun's fork and install it under /opt/mesa-egg.
# Runs inside `egg build` as root with network. Only Firefox uses it (through
# /usr/local/bin/firefox); the distribution's Mesa that GNOME runs on is
# untouched. Every Linux egg builds the same commit (MESA_COMMIT below): one
# version, one set of changes, one host-protocol check.
#
# The fork (github.com/CamouflageNetworks/mesa, branch `egg`, on upstream's
# mesa-26.0.8) carries as commits what Firefox's WebGPU present-without-
# readback swap chain needs on virtio-gpu and stock Mesa refuses:
#  - Venus (the Vulkan driver on the host GPU) also claims OPAQUE_FD binary
#    semaphores and exports them as the sync file it already has: Firefox's
#    wgpu (and Chrome's Dawn) gate the dma_buf swap chain on OPAQUE_FD export.
#  - virgl (the GL driver) exposes GL_EXT_semaphore(_fd) over its existing
#    in-fence path, so Firefox's compositor waits for the WebGPU frame.
#  - The GL semaphore entry points are allowed on a GLES 3.0 context (Mesa's
#    API table tags them 3.2; virgl on this host is 3.0).
# The host half is the runner's EGG_VENUS_SHARED_PRESENT (on by default).
# Only the virgl GL driver and the virtio Vulkan driver are built, without
# LLVM: about two minutes on four vCPUs. The distribution's own mesa
# build-dependencies cover it; they are removed again afterwards.
set -euo pipefail
MESA_REPO=https://github.com/CamouflageNetworks/mesa.git
MESA_COMMIT=bc7396a2ae2ff3d5b5d78e4c729bd07471cb160c
SRC=/root/mesa-src
PREFIX=/opt/mesa-egg

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
DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends meson ninja-build pkg-config git ca-certificates

rm -rf "$SRC"; mkdir -p "$SRC"; cd "$SRC"
git init -q mesa && cd mesa
git fetch -q --depth 1 "$MESA_REPO" "$MESA_COMMIT"
git checkout -q FETCH_HEAD
[ "$(git rev-parse HEAD)" = "$MESA_COMMIT" ] || { echo "mesa-egg: fetched $(git rev-parse HEAD), wanted $MESA_COMMIT"; exit 1; }
echo "mesa-egg: building Mesa $(cat VERSION) from $MESA_REPO @ ${MESA_COMMIT:0:12}"

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
