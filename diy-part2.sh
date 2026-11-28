#!/bin/bash
# ================================================================
# diy-part2.sh (for XG-040G-MD) —— 默认值定制（.config 加载之后、defconfig 之前运行）
# build-ponwrt.yml 步骤 8 cd 进来调用
#
# XG040MD 版功能清单（相对上游 ztb666ai 版的差异标 ★）：
#   [7.7]  USB 自动挂载到 /opt（mount-opt + hotplug + uci-defaults）
#   [7.9]  /etc/sysctl.conf 内核调优
#   [10]   ★ 默认 LAN IP=192.168.2.1、hostname=XG-040G-MD、时区 Asia/Shanghai
#   [10.5] uci-defaults 强制中国时区（保配置升级也生效）
#   [11] ★ NTP 候选服务器：ntp.ntsc.ac.cn / ntp1.aliyun.com / cn.pool.ntp.org / time.cloudflare.com
#   [12] ★ Nikki Concord 预编译 ipk 解包进 files/（服务 -> Nikki Concord）
#   [13] ★ MT7921AU USB 固件兜底（howardzhou888/MT7921 mediatek .bin）
#   原有:  zoneinfo-asia / 固件版本后缀 / 自定义包开关
# ================================================================
set -euo pipefail

# ---- 可调参数（均有默认值，可用环境变量覆盖，不必改代码）----
LAN_IP="${LAN_IP:-192.168.2.1}"                       # [10] 默认 LAN IP
LAN_HOSTNAME="${LAN_HOSTNAME:-XG-040G-MD}"            # [10] ★ 默认主机名（LuCI 概览页显示）
ENABLE_USB_OPT_MOUNT="${ENABLE_USB_OPT_MOUNT:-1}"     # [7.7] USB 自动挂载 /opt 开关
ENABLE_SYSCTL_TUNING="${ENABLE_SYSCTL_TUNING:-1}"     # [7.9] sysctl 调优开关

# [12] Nikki Concord 预编译包（aarch64_cortex-a53，ponwrt = ImmortalWrt master/apk，
#      ipk 数据段与 apk 内容一致，解包注入 rootfs 不受包管理器差异影响）
NIKKI_REPO="${NIKKI_REPO:-user-7392/nikki-concord}"
NIKKI_TAG="${NIKKI_TAG:-v0.1.0-r31}"
NIKKI_ARCH="${NIKKI_ARCH:-aarch64_cortex-a53}"
NIKKI_PKG_NAME="luci-app-nikki-concord-0.1.0-r31_${NIKKI_ARCH}.ipk"
NIKKI_URL="https://github.com/${NIKKI_REPO}/releases/download/${NIKKI_TAG}/${NIKKI_PKG_NAME}"

# [13] MT7921AU 固件兜底仓库（kmod-mt7921-firmware 已自带同名固件，此处仅兜底）
MT7921_FW_BASE="https://raw.githubusercontent.com/howardzhou888/MT7921/main/firmware"
MT7921_FW_FILES=("WIFI_RAM_CODE_MT7961_1.bin" "WIFI_MT7961_patch_mcu_1_2_hdr.bin")

echo "=========================================="
echo "默认值定制 (diy-part2.sh XG-040G-MD)"
echo "  LAN_IP        = ${LAN_IP}"
echo "  LAN_HOSTNAME  = ${LAN_HOSTNAME}"
echo "  USB /opt      = ${ENABLE_USB_OPT_MOUNT}"
echo "  sysctl 调优   = ${ENABLE_SYSCTL_TUNING}"
echo "  Nikki Concord = ${NIKKI_URL}"
echo "=========================================="

# ================================================================
# [7.7] USB 自动挂载到 /opt（移植自 build-mf-NoOC 步骤 7.7）
# ================================================================
if [ "${ENABLE_USB_OPT_MOUNT}" = "1" ]; then
  mkdir -p files/usr/bin files/etc/hotplug.d/block files/etc/uci-defaults

  # ---- 1) 挂载/卸载辅助脚本 ----
  cat > files/usr/bin/mount-opt <<'EOF'
#!/bin/sh
# 将第一个未挂载的 USB/SD 分区挂载到 /opt
MOUNT_POINT="/opt"

do_mount() {
    local dev
    mkdir -p "$MOUNT_POINT"
    # /opt 已被占用则不重复挂
    grep -qs " ${MOUNT_POINT} " /proc/mounts && return 0
    for dev in /dev/sd[a-z][0-9]* /dev/mmcblk[0-9]p[0-9]*; do
        [ -b "$dev" ] || continue
        grep -qs "^${dev} " /proc/mounts && continue
        logger -t mount-opt "mounting ${dev} -> ${MOUNT_POINT}"
        mount -o rw,noatime "$dev" "$MOUNT_POINT" && return 0
    done
    return 1
}

do_umount() {
    local dev="${1}"
    grep -qs "^${dev} ${MOUNT_POINT} " /proc/mounts && umount "$MOUNT_POINT"
}

case "$1" in
    mount)  do_mount ;;
    umount) do_umount "$2" ;;
    *)      echo "usage: $0 mount|umount [dev]" ;;
esac
EOF
  chmod +x files/usr/bin/mount-opt

  # ---- 2) hotplug: 开机冷插拔 + 运行期热插拔 ----
  cat > files/etc/hotplug.d/block/40-mount-opt <<'EOF'
case "$ACTION" in
    add)
        case "$DEVNAME" in
            sd[a-z][0-9]*|mmcblk[0-9]p[0-9]*)
                # 后台执行避免阻塞 hotplug 队列; 等 1s 让设备节点就绪
                ( sleep 1; /usr/bin/mount-opt mount ) &
                ;;
        esac
        ;;
    remove)
        case "$DEVNAME" in
            sd[a-z][0-9]*|mmcblk[0-9]p[0-9]*)
                /usr/bin/mount-opt umount "/dev/$DEVNAME"
                ;;
        esac
        ;;
esac
EOF

  # ---- 3) 首次开机: 禁用 blockd, 并提前完成挂载 ----
  cat > files/etc/uci-defaults/99-mount-opt <<'EOF'
# blockd 会把 U 盘自动挂到 /mnt/sda1, 与 /opt 冲突, 禁用之
[ -x /etc/init.d/blockd ] && /etc/init.d/blockd disable
mkdir -p /opt
# S10 时 kmodloader 已加载 usb-storage, 稍等设备枚举后挂载
(
    n=0
    while [ "$n" -lt 10 ] && ! /usr/bin/mount-opt mount; do
        sleep 1
        n=$((n+1))
    done
) &
exit 0
EOF
  chmod +x files/etc/uci-defaults/99-mount-opt
  echo "✅ [7.7] USB auto-mount overlay generated (mount-opt / hotplug / uci-defaults)"
fi

# ================================================================
# [10] 默认 LAN IP / hostname / 时区
# ponwrt(ImmortalWrt master) 的 config_generate 是
# `set system.@system[-1].xxx='...'` 格式，不是 uci 的 `option xxx` 格式，
# 旧版 sed 匹配不到（无声失效）。这里改用 python 精确替换，
# 匹配失败直接报错（fail fast），@system[[-0-9]+] 兼容新旧写法。
# ================================================================
CFG="package/base-files/files/bin/config_generate"
if [ -f "$CFG" ]; then
  LAN_IP="$LAN_IP" LAN_HOSTNAME="$LAN_HOSTNAME" python3 - "$CFG" <<'PY'
import os, re, sys
p = sys.argv[1]
s = open(p, encoding="utf-8").read()
lan_ip = os.environ.get("LAN_IP", "192.168.2.1")
hostname = os.environ.get("LAN_HOSTNAME", "XG-040G-MD")

def must_replace(pattern, repl, label):
    global s
    s2, n = re.subn(pattern, repl, s, count=1)
    if n != 1:
        raise SystemExit(f"ERROR: config_generate patch failed: {label}")
    s = s2

must_replace(
    r'lan\) ipad=\$\{ipaddr:-"192\.168\.1\.1"\} ;;',
    'lan) ipad=${ipaddr:-"' + lan_ip + '"} ;;',
    "lan ip",
)
must_replace(
    r"(set system\.@system\[-?\d+\]\.hostname=)'[^']*'",
    "\\g<1>'" + hostname + "'",
    "hostname",
)
must_replace(
    r"(set system\.@system\[-?\d+\]\.timezone=)'[^']*'",
    "\\g<1>'CST-8'",
    "timezone",
)
must_replace(
    r"(set system\.@system\[-?\d+\]\.zonename=)'[^']*'",
    "\\g<1>'Asia/Shanghai'",
    "zonename",
)
open(p, "w", encoding="utf-8").write(s)
print("config_generate patched OK: LAN=" + lan_ip
      + " hostname=" + hostname + " TZ=Asia/Shanghai (CST-8)")
PY
  # 回显确认（python 已保证替换必然成功；|| true 防 set -e 误杀 grep）
  echo "--- patch result ---"
  grep -n "$LAN_IP" "$CFG" || true
  grep -n "$LAN_HOSTNAME" "$CFG" || true
  grep -n "CST-8" "$CFG" || true
else
  echo "::warning::未找到 $CFG，跳过默认 LAN/主机名/时区修改"
fi

# ================================================================
# [10.5] uci-defaults 强制中国时区（保配置升级/恢复出厂后也强制刷回）
# [11]   ★ NTP 候选服务器（LuCI 系统->系统->时间同步 页面同步显示）
# ================================================================
mkdir -p files/etc/uci-defaults
cat > files/etc/uci-defaults/99-timezone-cn <<'EOF'
#!/bin/sh
# Force China timezone (UTC+8) on every flash / keep-settings upgrade
[ -s /etc/config/system ] || exit 0
uci -q set system.@system[0].zonename='Asia/Shanghai'
uci -q set system.@system[0].timezone='CST-8'
uci -q commit system
exit 0
EOF
chmod +x files/etc/uci-defaults/99-timezone-cn
echo "✅ [10.5] uci-defaults 99-timezone-cn 已写入"

cat > files/etc/uci-defaults/99-xg-ntp <<'EOF'
#!/bin/sh
# [11] NTP 候选服务器（国内优先）
[ -s /etc/config/system ] || exit 0
uci -q batch <<'UCI'
set system.ntp=timeserver
set system.ntp.enabled='1'
set system.ntp.enable_server='0'
delete system.ntp.server
add_list system.ntp.server='ntp.ntsc.ac.cn'
add_list system.ntp.server='ntp1.aliyun.com'
add_list system.ntp.server='cn.pool.ntp.org'
add_list system.ntp.server='time.cloudflare.com'
commit system
UCI
exit 0
EOF
chmod +x files/etc/uci-defaults/99-xg-ntp
echo "✅ [11] uci-defaults 99-xg-ntp 已写入（ntp.ntsc.ac.cn / ntp1.aliyun.com / cn.pool.ntp.org / time.cloudflare.com）"

# ================================================================
# [12] ★ Nikki Concord —— 预编译 ipk 解包进 files/
#   包: luci-app-nikki-concord (v0.1.0-r31, aarch64_cortex-a53)
#   LuCI 入口: 服务 -> Nikki Concord ；自带 zh-cn lmo 翻译、
#   uci-defaults(防火墙注册/初始化)、init.d/nikkic、Zashboard 面板。
#   依赖里的 yq 由 configs/nokia_xg-040g-md-ubi.config 显式 =y，
#   其余依赖（rpcd-mod-ucode/kmod-tun/nftables-json 等）均已启用。
# ================================================================
group_dl() { echo "::group::$*"; }
endgroup_dl() { echo "::endgroup::"; }

group_dl "[12] 下载并解包 Nikki Concord ipk"
mkdir -p /tmp/nikkic
if curl -fsSL --retry 3 -o "/tmp/nikkic/${NIKKI_PKG_NAME}" "$NIKKI_URL"; then
  echo "下载完成: $(du -h "/tmp/nikkic/${NIKKI_PKG_NAME}" | cut -f1)"
  sha256sum "/tmp/nikkic/${NIKKI_PKG_NAME}"
  # ipk 兼容两种封装：旧版 ar 归档 / 新版 tar.gz，统一交给 tar 尝试
  rm -rf /tmp/nikkic/ext && mkdir -p /tmp/nikkic/ext
  if tar -xzf "/tmp/nikkic/${NIKKI_PKG_NAME}" -C /tmp/nikkic/ext 2>/dev/null; then
    IPK_FMT=targz
  else
    # ar 归档：无 ar 命令时用 python 解
    python3 - "/tmp/nikkic/${NIKKI_PKG_NAME}" /tmp/nikkic/ext <<'PY'
import sys
src, outdir = sys.argv[1], sys.argv[2]
with open(src, 'rb') as f:
    data = f.read()
assert data[:8] == b'!<arch>\n', 'not an ar archive'
off = 8
while off + 60 <= len(data):
    hdr = data[off:off+60]
    name = hdr[0:16].decode().strip().rstrip('/')
    size = int(hdr[48:58].decode().strip())
    content = data[off+60:off+60+size]
    with open(f'{outdir}/{name}', 'wb') as f:
        f.write(content)
    off += 60 + size + (size % 2)
PY
    IPK_FMT=ar
  fi
  DATA_TGZ=$(find /tmp/nikkic/ext -name 'data.tar.gz' | head -1)
  [ -n "$DATA_TGZ" ] || { echo "::error::ipk 内未找到 data.tar.gz"; exit 1; }
  # data.tar.gz 顶层为 ./...，直接解到 files/ 即为 rootfs 覆盖
  tar -xzf "$DATA_TGZ" -C files/
  echo "✅ Nikki Concord 已解包进 files/（IPK 格式: $IPK_FMT）"
  echo "--- nikkic 关键文件 ---"
  ls -l files/etc/init.d/nikkic files/etc/config/nikkic \
        files/usr/libexec/nikkic/concord \
        files/usr/share/luci/menu.d/luci-app-nikkic.json 2>/dev/null || true
  echo "--- 自带 uci-defaults ---"
  ls files/etc/uci-defaults/ | grep -i nikkic || true
  # 首启脚本兜底：包 postinst 的 first-boot.sh 逻辑在 uci-defaults 里补一次
  cat > files/etc/uci-defaults/99-xg-nikkic <<'EOF'
#!/bin/sh
# Nikki Concord 首次引导兜底（与包 postinst 行为对齐；服务保持默认不自启）
[ -x /etc/nikkic/scripts/first-boot.sh ] && /etc/nikkic/scripts/first-boot.sh || true
[ -x /etc/nikkic/scripts/firewall-register.sh ] && /etc/nikkic/scripts/firewall-register.sh || true
exit 0
EOF
  chmod +x files/etc/uci-defaults/99-xg-nikkic
  echo "✅ [12] uci-defaults 99-xg-nikkic 已写入"
else
  echo "::error::Nikki Concord ipk 下载失败: $NIKKI_URL"
  exit 1
fi
endgroup_dl

# ================================================================
# [13] ★ MT7921AU USB 固件兜底 —— 放入 files/lib/firmware/mediatek/
#   kmod-mt7921-firmware 本身会安装同名固件；此处以 files/ 覆盖层
#   双保险，保证 0e8d:7961 等 USB ID 插上即识别。
# ================================================================
group_dl "[13] 下载 MT7921AU 固件兜底"
mkdir -p files/lib/firmware/mediatek
for fw in "${MT7921_FW_FILES[@]}"; do
  if curl -fsSL --retry 3 -o "files/lib/firmware/mediatek/${fw}" "${MT7921_FW_BASE}/${fw}"; then
    echo "  ✅ ${fw} ($(du -h "files/lib/firmware/mediatek/${fw}" | cut -f1))"
  else
    echo "::warning::MT7921 固件兜底下载失败（不影响构建，kmod-mt7921-firmware 会提供）: ${fw}"
    rm -f "files/lib/firmware/mediatek/${fw}"
  fi
done
endgroup_dl

# ================================================================
# zoneinfo-asia —— 亚洲时区数据库（LuCI 时区显示/切换需要）
# ================================================================
if [ -f .config ]; then
  sed -i '/^CONFIG_PACKAGE_zoneinfo-asia=/d; /^# CONFIG_PACKAGE_zoneinfo-asia is not set/d' .config
  echo "CONFIG_PACKAGE_zoneinfo-asia=y" >> .config
  echo "✅ zoneinfo-asia 已加入 .config"
fi

# ================================================================
# 固件版本后缀（LuCI 概览页显示 · 作者 · 构建时间）
# ================================================================
[ -z "$FW_BUILD_TIME" ] && FW_BUILD_TIME="$(TZ="${TZ:-Asia/Shanghai}" date '+%Y-%m-%d %H:%M')"
VER_CODE="$(sed -n 's/^CONFIG_VERSION_CODE="\(.*\)"$/\1/p' .config 2>/dev/null || true)"
if [ -n "$VER_CODE" ]; then
  DESC_BODY='%D %V %C'
else
  DESC_BODY='%D %V'
fi
[ -z "$FW_DESC_SUFFIX" ] && FW_DESC_SUFFIX="· ${FW_AUTHOR} · ${FW_BUILD_TIME}"

RELEASE_TPL="package/base-files/files/etc/openwrt_release"
OSREL_TPL="package/base-files/files/usr/lib/os-release"
FW_DESC_LINE="DISTRIB_DESCRIPTION='${DESC_BODY} ${FW_DESC_SUFFIX}'"
OSREL_LINE="OPENWRT_RELEASE=\"${DESC_BODY} ${FW_DESC_SUFFIX}\""
export FW_DESC_LINE OSREL_LINE

if [ -f "$RELEASE_TPL" ]; then
  perl -i -pe 's/^DISTRIB_DESCRIPTION=.*/$ENV{FW_DESC_LINE}/' "$RELEASE_TPL"
  echo "✅ 固件版本模板 -> $FW_DESC_LINE"
else
  echo "::warning::未找到 $RELEASE_TPL，固件版本不会带构建信息"
fi

if [ -f "$OSREL_TPL" ]; then
  perl -i -pe 's/^OPENWRT_RELEASE=.*/$ENV{OSREL_LINE}/' "$OSREL_TPL"
  echo "✅ os-release 同步 -> $OSREL_LINE"
fi

# ================================================================
# 自定义包开关 —— defconfig 前最后一手
# （第三方包需 diy-part1.sh 先拉源，否则 defconfig 会静默剔除）
# ================================================================
if [ -f .config ]; then
  cat >> .config <<'EOF'

# ==== XG-040G-MD custom configuration (diy-part2) ====
# --- 附加应用 ---
CONFIG_PACKAGE_rtp2httpd=y
CONFIG_PACKAGE_luci-app-rtp2httpd=y
CONFIG_PACKAGE_luci-i18n-rtp2httpd-zh-cn=y
CONFIG_PACKAGE_acme-acmesh-dnsapi=y
CONFIG_PACKAGE_luci-app-acme=y
CONFIG_PACKAGE_luci-i18n-acme-zh-cn=y
CONFIG_PACKAGE_luci-ssl-openssl=y
CONFIG_PACKAGE_luci-app-ddns-go=y
CONFIG_PACKAGE_luci-app-uhttpd=y
CONFIG_PACKAGE_luci-i18n-uhttpd-zh-cn=y
CONFIG_PACKAGE_msmtp=y
CONFIG_PACKAGE_msmtp-mta=y
CONFIG_PACKAGE_mutt=y
CONFIG_PACKAGE_vim-fuller=y
CONFIG_PACKAGE_kmod-dummy=y
# --- ★ XG-040G-MD 新增 ---
CONFIG_PACKAGE_luci-app-ttyd=y                      # Web 终端
CONFIG_PACKAGE_luci-i18n-ttyd-zh-cn=y
CONFIG_PACKAGE_luci-app-autoreboot=y                # 定时重启
CONFIG_PACKAGE_luci-i18n-autoreboot-zh-cn=y
CONFIG_PACKAGE_yq=y                                 # Nikki Concord 依赖（Go 版 yq）
# --- 基础工具 ---
CONFIG_PACKAGE_curl=y
CONFIG_PACKAGE_bash=y
CONFIG_PACKAGE_htop=y
# 让 usb-power(regulator-output) 节点有驱动认领，防止 usb-5v 被
# regulator late-cleanup 关闭（U 盘开机 ~34s 断电问题）
CONFIG_PACKAGE_kmod-regulator-userspace-consumer=y
CONFIG_PACKAGE_kmod-sched-bpf=y
CONFIG_PACKAGE_kmod-sched-cake=y
CONFIG_PACKAGE_kmod-xdp-sockets-diag=y
CONFIG_PACKAGE_bpftool=y
CONFIG_PACKAGE_kmod-veth=y
EOF
fi

# Change 默认Luci的主题为Argon
sed -i 's/+luci-theme-bootstrap/+luci-theme-argon/g; s/default Bootstrap theme/Argon theme/g' feeds/luci/collections/luci-light/Makefile

# Remove LuCI menus: System > Plugins, Network > Diagnostics
python3 - <<'PY' || exit 1
import json
menus = {
    'feeds/luci/modules/luci-mod-system/root/usr/share/luci/menu.d/luci-mod-system.json': 'admin/system/plugins',
    'feeds/luci/modules/luci-mod-network/root/usr/share/luci/menu.d/luci-mod-network.json': 'admin/network/diagnostics',
}
for path, node in menus.items():
    with open(path) as f:
        data = json.load(f)
    data.pop(node)
    with open(path, 'w') as f:
        json.dump(data, f, indent='\t')
PY

echo "🎉 diy-part2.sh 执行完毕 (author=$FW_AUTHOR)"
