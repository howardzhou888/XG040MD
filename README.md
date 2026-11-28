# XG040MD — Nokia XG-040G-MD (AN7581) PonWrt 固件构建

基于 [ztb666ai/Actions-OpenWrt-AN758X](https://github.com/ztb666ai/Actions-OpenWrt-AN758X)（固件源码 [ztb666ai/ponwrt](https://github.com/ztb666ai/ponwrt) master 分支）定制，保留原 openclash 变体全部特性，额外加入：

## 内置特性

| 项目 | 内容 |
|---|---|
| 机型 | Nokia **XG-040G-MD**（UBI，SoC Airoha AN7581，内核 6.18） |
| 代理 | **OpenClash**（dev 最新版）+ **Nikki Concord**（服务 → Nikki Concord，预编译 v0.1.0-r31 aarch64_cortex-a53，内置 Concord 内核与 Zashboard 面板，独立于 OpenClash 并存） |
| USB 无线网卡 | **MT7921AU/MT7921U**（kmod-mt7921u + MT7961 固件，6.18 树内驱动解决兼容性）、**MT7612U**（kmod-mt76x2u）、**RTL8821CU/RTL8811CU**（kmod-rtw88-8821cu）、**RTL8822BU/88x2bu**（kmod-rtw88-8822bu）、**RTL8812AU**（kmod-rtw88-8812au）、**RTL8814AU**（kmod-rtw88-8814au）、rtl8xxxu 兜底；配 wireless-regdb + wpad-openssl + iw |
| 定时重启 | luci-app-autoreboot + luci-i18n-autoreboot-zh-cn（系统 → 定时重启） |
| Web 终端 | luci-app-ttyd + luci-i18n-ttyd-zh-cn（系统 → ttyd 终端） |
| 主机名 | **XG-040G-MD**（首次开机 LuCI 概览页即显示） |
| NTP 候选服务器 | ntp.ntsc.ac.cn / ntp1.aliyun.com / cn.pool.ntp.org / time.cloudflare.com |
| 语言 | 全量简体中文菜单（LUCI_LANG_zh_Hans 总开关 + 各应用 zh-cn 包 + Nikki Concord 自带 zh-cn） |
| 产物 | **仅 UBI `.itb` 固件**（squashfs-sysupgrade.itb / initramfs-recovery.itb） |

原版保留：PON 全链路（pon/ponctl/pon-debug/luci-app-pon）、IPTV、luci-app-airoha-npu、rtp2httpd、ddns-go、USB 自动挂载 /opt、EIP93 硬件加速、argon 主题等。

## 编译

Actions 页面 → **Build PonWrt (Airoha AN758x PON)** → Run workflow：

- `profile`: `nokia_xg-040g-md-ubi`（默认）
- `soc`: `an7581`（默认）
- `proxy`: `openclash`（默认；留空则不装 OpenClash，Nikki Concord 始终内置）
- `scope`: `firmware`（默认；首次构建建议先跑一次 `toolchain-only` 预热工具链缓存）

构建完成后到 Releases 下载 `ponwrt-airoha-an7581-nokia_xg-040g-md-ubi-master-openclash`，内含 `.itb` 固件。

> ⚠️ 首次冷构建（工具链 + 全部软件包）约 4-5 小时；有工具链缓存后约 1.5-2 小时。
> 刷机前请用 AN758x-Stock2UBI 备份原厂 flash，刷机后恢复 PON/校准数据。

## MT7921AU 兼容性说明

固件内 `kmod-mt7921u` 使用 ImmortalWrt master 的 mt76（与 6.18 内核同源编译），依赖链自动安装 `kmod-mt7921-firmware`（`WIFI_RAM_CODE_MT7961_1.bin` + `WIFI_MT7961_patch_mcu_1_2_hdr.bin`）。`diy-part2.sh` 另从 [howardzhou888/MT7921](https://github.com/howardzhou888/MT7921) 下载同名固件经 `files/` 覆盖层双保险。支持 USB ID：`0e8d:7961`、`3574:6211`、`0846:9060/9065`、`35bc:0107`。
