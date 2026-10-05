#!/usr/bin/env bash
set -euo pipefail

VERSION="${VERSION:-25.12-SNAPSHOT}"
TARGET="${TARGET:-x86/64}"
PROFILE="${PROFILE:-generic}"
IMAGEBUILDER_URL="${IMAGEBUILDER_URL:-https://downloads.immortalwrt.org/releases/25.12-SNAPSHOT/targets/x86/64/immortalwrt-imagebuilder-25.12-SNAPSHOT-x86-64.Linux-x86_64.tar.zst}"
EXTRA_IMAGE_NAME="${EXTRA_IMAGE_NAME:-daede}"
OUT_DIR="${OUT_DIR:-$PWD/out}"
PREFLIGHT="${PREFLIGHT:-1}"
ROOTFS_PARTSIZE="${ROOTFS_PARTSIZE:-1024}"

# 是否把 kenzok8/openwrt-daede 的 Release APK
# （dae / daed / luci-app-daede）直接打进固件
INSTALL_DAEDE="${INSTALL_DAEDE:-1}"

DAEDE_REPO="${DAEDE_REPO:-kenzok8/openwrt-daede}"
DAEDE_RELEASE_TAG="${DAEDE_RELEASE_TAG:-latest}"
DAEDE_ARCH="${DAEDE_ARCH:-x86_64}"

# 仍然保留这个兼容参数：
# 只用于覆盖 luci-app-daede 的下载地址。
DAEDE_APK_URL="${DAEDE_APK_URL:-}"

# 可选：分别覆盖 dae / daed 下载地址。
DAE_APK_URL="${DAE_APK_URL:-}"
DAED_APK_URL="${DAED_APK_URL:-}"

WORK_DIR="${WORK_DIR:-$PWD/work}"
IB_ARCHIVE="$WORK_DIR/imagebuilder.tar.zst"

EXTRA_PACKAGES="${EXTRA_PACKAGES:-luci luci-i18n-base-zh-cn luci-i18n-package-manager-zh-cn luci-app-daede kmod-sched-core kmod-sched-bpf kmod-veth kmod-xdp-sockets-diag kmod-nft-tproxy kmod-tun bash coreutils coreutils-cat coreutils-cp coreutils-date coreutils-dd coreutils-df coreutils-du coreutils-head coreutils-ls coreutils-mv coreutils-rm coreutils-readlink coreutils-realpath coreutils-sha256sum coreutils-sort coreutils-stat coreutils-tail coreutils-tee coreutils-touch coreutils-tr coreutils-uniq coreutils-wc findutils findutils-find findutils-xargs grep sed gawk diffutils procps-ng-free procps-ng-ps procps-ng-pgrep procps-ng-pkill procps-ng-top ip-full curl nano}"

mkdir -p "$WORK_DIR" "$OUT_DIR"


###############################################################################
# Resolve GitHub Release asset URL
###############################################################################

resolve_daede_apk_url() {
  local package="$1"

  # 对 luci-app-daede 保留原有 DAEDE_APK_URL 覆盖逻辑
  if [ "$package" = "luci-app-daede" ] && [ -n "$DAEDE_APK_URL" ]; then
    printf '%s\n' "$DAEDE_APK_URL"
    return
  fi

  # dae 单独 URL
  if [ "$package" = "dae" ] && [ -n "$DAE_APK_URL" ]; then
    printf '%s\n' "$DAE_APK_URL"
    return
  fi

  # daed 单独 URL
  if [ "$package" = "daed" ] && [ -n "$DAED_APK_URL" ]; then
    printf '%s\n' "$DAED_APK_URL"
    return
  fi

  local release_api

  if [ "$DAEDE_RELEASE_TAG" = "latest" ]; then
    release_api="https://api.github.com/repos/$DAEDE_REPO/releases/latest"
  else
    release_api="https://api.github.com/repos/$DAEDE_REPO/releases/tags/$DAEDE_RELEASE_TAG"
  fi

  python3 - "$release_api" "$DAEDE_ARCH" "$package" <<'PY'
import json
import os
import sys
import urllib.request

release_api, arch, package = sys.argv[1:4]

request = urllib.request.Request(
    release_api,
    headers={
        "Accept": "application/vnd.github+json",
        "User-Agent": "kenzok8-imagebuilder",
    },
)

token = os.environ.get("GITHUB_TOKEN")
if token:
    request.add_header("Authorization", f"Bearer {token}")

with urllib.request.urlopen(request, timeout=30) as response:
    release = json.load(response)

suffix = f"-{arch}.apk"

matches = [
    asset.get("browser_download_url") or asset.get("url")
    for asset in release.get("assets", [])
    if asset.get("name", "").startswith(f"{package}-")
    and asset.get("name", "").endswith(suffix)
]

if not matches:
    tag = release.get("tag_name", release_api)
    raise SystemExit(
        f"{package} APK for {arch} not found in {tag}"
    )

print(matches[0])
PY
}


###############################################################################
# Download dae / daed / luci-app-daede Release APKs
###############################################################################

install_daede_apks() {
  case "$INSTALL_DAEDE" in
    1|true|yes)
      ;;
    *)
      echo "Skipping dae/daed/luci-app-daede release APK download."
      return
      ;;
  esac

  local packages_dir="$WORK_DIR/imagebuilder/packages"

  mkdir -p "$packages_dir"

  for package in luci-app-daede dae daed; do
    local apk_url
    local fname

    apk_url="$(resolve_daede_apk_url "$package")"

    # GitHub asset:
    #   dae-2026.xx.xx-rX-x86_64.apk
    #
    # ImageBuilder 本地 packages/index 中应使用：
    #   dae-2026.xx.xx-rX.apk
    #
    # 原脚本已经针对 luci-app-daede 这么做了，
    # 现在对三个包统一处理。
    fname="${apk_url##*/}"
    fname="${fname%-${DAEDE_ARCH}.apk}.apk"

    echo
    echo "Downloading ${package} APK:"
    echo "  URL : $apk_url"
    echo "  File: $fname"

    curl -L \
      --fail \
      --retry 8 \
      --retry-delay 5 \
      --connect-timeout 30 \
      -o "$packages_dir/$fname" \
      "$apk_url"

    if [ ! -s "$packages_dir/$fname" ]; then
      echo "ERROR: downloaded APK is empty: $packages_dir/$fname" >&2
      exit 1
    fi
  done
}


###############################################################################
# Download ImageBuilder
###############################################################################

IB_ARCHIVE="$WORK_DIR/imagebuilder.tar.zst"

if [ ! -s "$IB_ARCHIVE" ]; then
  echo "Downloading ImageBuilder:"
  echo "  $IMAGEBUILDER_URL"

  curl -L \
    --fail \
    --retry 8 \
    --retry-delay 5 \
    --connect-timeout 30 \
    -o "$IB_ARCHIVE" \
    "$IMAGEBUILDER_URL"
fi


###############################################################################
# Extract ImageBuilder
###############################################################################

rm -rf "$WORK_DIR/imagebuilder"

mkdir -p "$WORK_DIR/imagebuilder"

tar \
  --use-compress-program=unzstd \
  -xf "$IB_ARCHIVE" \
  -C "$WORK_DIR/imagebuilder" \
  --strip-components=1


###############################################################################
# Copy custom files
###############################################################################

cp -a files "$WORK_DIR/imagebuilder/files"


###############################################################################
# Add custom dae/daed packages
###############################################################################

install_daede_apks


###############################################################################
# Enter ImageBuilder
###############################################################################

cd "$WORK_DIR/imagebuilder"


###############################################################################
# Display configuration
###############################################################################

echo
echo "================ Build Configuration ================"
echo "Version:              $VERSION"
echo "Target:               $TARGET"
echo "Profile:              $PROFILE"
echo "Rootfs part size:     ${ROOTFS_PARTSIZE}MB"
echo "Install daede APKs:   $INSTALL_DAEDE"
echo "Daede release:        $DAEDE_REPO@$DAEDE_RELEASE_TAG"
echo "Daede architecture:   $DAEDE_ARCH"
echo
echo "Extra packages:"
echo "$EXTRA_PACKAGES"
echo "======================================================"
echo


mkdir -p "$OUT_DIR"

echo "extra_packages=$EXTRA_PACKAGES" \
  > "$OUT_DIR/.extra_packages"


###############################################################################
# Failure diagnostics
###############################################################################

diagnose_failure() {
  cat >&2 <<'EOF'

ImageBuilder failed.

Common causes for this daede image:

1. ImmortalWrt snapshot ImageBuilder and package feeds are out of sync.
   Example:
     base packages require a newer libubox/libblobmsg-json
     than the public feed currently provides.

2. A required kernel module is missing from the selected
   target/kernel feed.

   Important dae/daed dependencies include:
     kmod-sched-core
     kmod-sched-bpf
     kmod-veth
     kmod-xdp-sockets-diag
     kmod-nft-tproxy

   Tailscale also needs:
     kmod-tun

3. The kenzok8/openwrt-daede Release APKs could not be resolved
   or do not match the selected architecture.

   This script expects:
     luci-app-daede-*-x86_64.apk
     dae-*-x86_64.apk
     daed-*-x86_64.apk

4. The newer dae/daed Release APKs depend on libraries or ABI
   components that are unavailable in the selected ImmortalWrt
   package feed.

5. One of the GNU utility package names changed or is unavailable
   in the selected ImmortalWrt snapshot.

About BTF:

- ImmortalWrt 25.12 kernels enable CONFIG_DEBUG_INFO_BTF by default.
- dae/daed reads BTF directly from:
    /sys/kernel/btf/vmlinux
- Do NOT add vmlinux-btf to EXTRA_PACKAGES.
- ImageBuilder cannot build a missing vmlinux-btf package.
- Older releases without built-in BTF require a full SDK/kernel build.

The build uses local APK packages for:
  dae
  daed
  luci-app-daede

Those three packages are intentionally obtained from:
  kenzok8/openwrt-daede

instead of allowing dae/daed to be selected from the
ImmortalWrt feed.

Useful commands for debugging:

  make manifest PROFILE="$PROFILE" PACKAGES="$EXTRA_PACKAGES"

  ls -lah packages/

  find packages/ -maxdepth 1 -type f -name '*.apk' -print

Environment overrides:

  DAEDE_RELEASE_TAG
  DAEDE_ARCH
  DAEDE_APK_URL
  DAE_APK_URL
  DAED_APK_URL
  EXTRA_PACKAGES
  ROOTFS_PARTSIZE
EOF
}


###############################################################################
# Package manifest preflight
###############################################################################

if [ "$PREFLIGHT" = "1" ] || [ "$PREFLIGHT" = "true" ]; then
  echo
  echo "Running package manifest preflight..."

  # Helpful debug information: show our local APKs before make manifest.
  echo
  echo "Local custom APK packages:"
  if find packages/ -maxdepth 1 -type f -name '*.apk' -print -quit | grep -q .; then
    find packages/ \
      -maxdepth 1 \
      -type f \
      -name '*.apk' \
      -printf '  %f\n' \
      | sort
  else
    echo "  (none)"
  fi
  echo

  if ! make manifest \
      PROFILE="$PROFILE" \
      PACKAGES="$EXTRA_PACKAGES"; then
    diagnose_failure
    exit 1
  fi
fi


###############################################################################
# Image format selection
#
# 保持原项目的 squashfs-only 设计。
# ROOTFS_PARTSIZE 仍然完全由 GitHub Actions / workflow 提供。
###############################################################################

sed -i \
  -e 's/^CONFIG_TARGET_ROOTFS_EXT4FS=y/# CONFIG_TARGET_ROOTFS_EXT4FS is not set/' \
  -e 's/^CONFIG_TARGET_ROOTFS_TARGZ=y/# CONFIG_TARGET_ROOTFS_TARGZ is not set/' \
  -e 's/^CONFIG_VDI_IMAGES=y/# CONFIG_VDI_IMAGES is not set/' \
  -e 's/^CONFIG_VHDX_IMAGES=y/# CONFIG_VHDX_IMAGES is not set/' \
  -e 's/^CONFIG_ISO_IMAGES=y/# CONFIG_ISO_IMAGES is not set/' \
  -e 's/^CONFIG_GRUB_IMAGES=y/# CONFIG_GRUB_IMAGES is not set/' \
  .config


###############################################################################
# Build image
###############################################################################

if ! make image \
    PROFILE="$PROFILE" \
    PACKAGES="$EXTRA_PACKAGES" \
    FILES=files \
    BIN_DIR="$OUT_DIR" \
    EXTRA_IMAGE_NAME="$EXTRA_IMAGE_NAME" \
    ROOTFS_PARTSIZE="$ROOTFS_PARTSIZE"; then

  diagnose_failure
  exit 1
fi


###############################################################################
# Rename output files
###############################################################################

cd "$OUT_DIR"

for f in *-squashfs-combined-efi.img.gz; do
  [ -f "$f" ] && mv "$f" daede-squashfs-efi.img.gz
done

for f in *-squashfs-combined-efi.qcow2; do
  [ -f "$f" ] && mv "$f" daede-squashfs-efi.qcow2
done

for f in *-squashfs-combined-efi.vmdk; do
  [ -f "$f" ] && mv "$f" daede-squashfs-efi.vmdk
done

for f in *-kernel.bin; do
  [ -f "$f" ] && mv "$f" daede-kernel.bin
done

for f in *-rootfs.tar.gz; do
  [ -f "$f" ] && mv "$f" daede-rootfs.tar.gz
done

for f in *.manifest; do
  [ -f "$f" ] && mv "$f" daede.manifest
done

for f in *.bom.cdx.json; do
  [ -f "$f" ] && mv "$f" daede.bom.cdx.json
done


###############################################################################
# SHA256
###############################################################################

for f in \
  *.img.gz \
  *.qcow2 \
  *.vmdk \
  *.bin \
  *.tar.gz \
  *.manifest \
  *.bom.cdx.json
do
  [ -f "$f" ] || continue
  sha256sum "$f"
done > sha256sums


###############################################################################
# Build manifest
###############################################################################

BUILD_DATE="$(TZ='Asia/Shanghai' date '+%F %H:%M CST')"

cat > BUILD-MANIFEST.txt <<BODYEOF
## daede 固件 · ${EXTRA_IMAGE_NAME}

基于 ImmortalWrt 25.12-SNAPSHOT，x86-64 通用镜像，squashfs-only。

### 推荐下载

| 格式 | 适用场景 | 文件 |
|------|----------|------|
| **img.gz** | 物理机 dd 写盘 / PVE 导入 | daede-squashfs-efi.img.gz |
| **qcow2** | QEMU / Proxmox VE | daede-squashfs-efi.qcow2 |
| **vmdk** | VMware ESXi / Workstation | daede-squashfs-efi.vmdk |

> 额外：\`daede-rootfs.tar.gz\` 裸文件系统，可用于 LXC 容器转换。

### 镜像详情

- **系统类型**：squashfs（只读根 + overlay 可写层）
- **分区**：combined（含分区表 + 引导，直接 dd）
- **启动**：EFI
- **根分区大小**：${ROOTFS_PARTSIZE} MB
- **构建日期**：${BUILD_DATE}
- **ImageBuilder**：${IMAGEBUILDER_URL}

### dae / daed

本固件中的：

- \`dae\`
- \`daed\`
- \`luci-app-daede\`

均来自：

\`${DAEDE_REPO}@${DAEDE_RELEASE_TAG}\`

架构：

\`${DAEDE_ARCH}\`

### 预装软件

\`$(cat "$OUT_DIR/.extra_packages" 2>/dev/null || echo "$EXTRA_PACKAGES")\`

### 校验

\`\`\`bash
sha256sum -c sha256sums --ignore-missing
\`\`\`
BODYEOF


###############################################################################
# Final output
###############################################################################

echo
echo "================ Build Complete ================"
ls -lah "$OUT_DIR"
echo "==============================================="
