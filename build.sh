#!/bin/bash

BUILD_ERROR_CODE=1

set -e

if [ "$(id -u)" != "0" ]; then
   echo "This script must be run as root" 1>&2
   exit $BUILD_ERROR_CODE
fi

if [ -z "$1" ]; then
  echo "Usage: "${BASH_SOURCE[0]}" <configuration path>" 1>&2
  exit $BUILD_ERROR_CODE
else
  CONFIG_PATH="$( cd -P "$( dirname "$1"/blah )" && pwd )"
  if [ ! -f "$CONFIG_PATH/vars.txt" ] || [ ! -d "$CONFIG_PATH/config" ]; then
    echo "Usage: "$CONFIG_PATH" should contain vars.txt and config directory" 1>&2
    exit $BUILD_ERROR_CODE
  fi
fi


if [ ! -d "/usr/share/live/build/hooks" ]; then
  echo "/usr/share/live/build/hooks does not exist, install live-build before proceeding" 1>&2
  exit $BUILD_ERROR_CODE
fi

RUN_PATH="$(pwd)"
pushd "$CONFIG_PATH" >/dev/null 2>&1

source ./vars.txt

if [ -z "$BUILD_DIR" ]; then
  WORKDIR="$(mktemp -d -t deblive-XXXXXX)"
else
  WORKDIR="$(mktemp -d -p "$BUILD_DIR" -t deblive-XXXXXX)"
fi

function cleanup {
  # unmount any chroot stuff left behind after an error
  (umount -f $(mount | grep chroot | cut -d ' ' -f 3) >/dev/null 2>&1) && sleep 5

  # clean up the temporary build directory
  if ! rm -rf "$WORKDIR"; then
    echo "Failed to remove temporary directory '$WORKDIR'"
    exit $BUILD_ERROR_CODE
  fi
}

if [ -d "$WORKDIR" ]; then
  # ensure that if we "grabbed a lock", we release it (works for clean exit, SIGTERM, and SIGINT/Ctrl-C)
  trap "cleanup" EXIT

  pushd "$WORKDIR" >/dev/null 2>&1

  mkdir -p ./output "./work/$IMAGE_NAME-Live-Build"
  pushd "./work/$IMAGE_NAME-Live-Build" >/dev/null 2>&1
  rsync -a "$CONFIG_PATH/config" .

  mkdir -p ./config/hooks/live
  pushd ./config/hooks/live
  ln -v -s -f /usr/share/live/build/hooks/live/* ./
  popd >/dev/null 2>&1

  mkdir -p ./config/hooks/normal
  pushd ./config/hooks/normal
  ln -v -s -f /usr/share/live/build/hooks/normal/* ./
  rm -f ./0910-remove-apt-sources-lists
  popd >/dev/null 2>&1

  # make sure we install the newer kernel, firmwares, and kernel headers
  echo "linux-image-$(uname -r)" > ./config/package-lists/kernel.list.chroot
  echo "linux-headers-$(uname -r)" >> ./config/package-lists/kernel.list.chroot
  echo "linux-compiler-gcc-8-x86=$(dpkg -s linux-compiler-gcc-8-x86 | grep ^Version: | cut -d' ' -f2)" >> ./config/package-lists/kernel.list.chroot
  echo "linux-kbuild-4.19=$(dpkg -s linux-kbuild-4.19 | grep ^Version: | cut -d' ' -f2)" >> ./config/package-lists/kernel.list.chroot
  echo "firmware-linux=$(dpkg -s firmware-linux | grep ^Version: | cut -d' ' -f2)" >> ./config/package-lists/kernel.list.chroot
  echo "firmware-linux-free=$(dpkg -s firmware-linux-free | grep ^Version: | cut -d' ' -f2)" >> ./config/package-lists/kernel.list.chroot
  echo "firmware-linux-nonfree=$(dpkg -s firmware-linux-nonfree | grep ^Version: | cut -d' ' -f2)" >> ./config/package-lists/kernel.list.chroot
  echo "firmware-misc-nonfree=$(dpkg -s firmware-misc-nonfree | grep ^Version: | cut -d' ' -f2)" >> ./config/package-lists/kernel.list.chroot
  echo "firmware-amd-graphics=$(dpkg -s firmware-amd-graphics | grep ^Version: | cut -d' ' -f2)" >> ./config/package-lists/kernel.list.chroot
  echo "firmware-iwlwifi=$(dpkg -s firmware-iwlwifi | grep ^Version: | cut -d' ' -f2)" >> ./config/package-lists/kernel.list.chroot
  echo "firmware-atheros=$(dpkg -s firmware-atheros | grep ^Version: | cut -d' ' -f2)" >> ./config/package-lists/kernel.list.chroot

  # virtualbox-guest .deb package(s) in its own clean environment (rather than in hooks/)
  if [[ -d "$CONFIG_PATH/vbox-guest-build" ]]; then
    rsync -a "$CONFIG_PATH/vbox-guest-build" .
    mkdir -p ./config/packages.chroot/
    bash ./vbox-guest-build/build-docker-image.sh
    docker run --rm -v "$(pwd)"/vbox-guest-build:/build vboxguest-build:latest -o /build
    rm -f ./vbox-guest-build/*-source*.deb \
          ./vbox-guest-build/*-dbgsym*.deb \
          ./vbox-guest-build/virtualbox_*.deb \
          ./vbox-guest-build/virtualbox-dkms_*.deb \
          ./vbox-guest-build/virtualbox-qt_*.deb
    mv ./vbox-guest-build/*.deb ./config/packages.chroot/
  fi

  chown -R root:root *

  # put the date in the grub.cfg entries
  sed -i "s/\(Install Debian\)/\1 $(date +'%Y-%m-%d %H:%M:%S')/g" ./config/includes.binary/boot/grub/grub.cfg ./config/includes.binary/isolinux/install.cfg

  lb config \
    --image-name "$IMAGE_NAME" \
    --debian-installer live \
    --debian-installer-gui false \
    --debian-installer-distribution $IMAGE_DISTRIBUTION \
    --distribution $IMAGE_DISTRIBUTION \
    --linux-packages "linux-image-$(uname -r | sed 's/-amd64$//')" \
    --architectures amd64 \
    --binary-images iso-hybrid \
    --bootloaders "syslinux,grub-efi" \
    --memtest none \
    --chroot-filesystem squashfs \
    --backports $APT_BACKPORTS \
    --security $APT_SECURITY \
    --updates $APT_UPDATES \
    --source false \
    --apt-indices none \
    --apt-source-archives false \
    --archive-areas 'main contrib non-free' \
    --debootstrap-options "--include=apt-transport-https,bc,gnupg,ca-certificates,openssl --no-merged-usr" \
    --apt-options "--allow-downgrades --allow-remove-essential --allow-change-held-packages -o Acquire::Check-Valid-Until=false --yes"

  lb build 2>&1 | tee "$WORKDIR/output/$IMAGE_NAME-$IMAGE_VERSION-build.log"
  if [ -f "$IMAGE_NAME-amd64.hybrid.iso" ]; then
    mv "$IMAGE_NAME-amd64.hybrid.iso" "$RUN_PATH/$IMAGE_NAME-$IMAGE_VERSION.iso" && \
      echo "Finished, created \"$RUN_PATH/$IMAGE_NAME-$IMAGE_VERSION.iso\""
    BUILD_ERROR_CODE=0
  else
    echo "Error creating ISO, see log file"
    BUILD_ERROR_CODE=2
  fi
  mv "$WORKDIR/output/$IMAGE_NAME-$IMAGE_VERSION-build.log" "$RUN_PATH/"

  popd >/dev/null 2>&1
  popd >/dev/null 2>&1

else
  echo "Unable to create temporary directory \"$WORKDIR\""
fi

popd  >/dev/null 2>&1

exit $BUILD_ERROR_CODE
