#!/usr/bin/env bash
# ================================================================
# diy-part1.sh —— 拉取可选插件到 package/custom 并校验索引
#
# 运行目录：ponwrt 源码根目录（feeds 安装之后、加载 .config 之前）
# XG040MD 版：仅保留 luci-app-airoha-npu 与 OpenClash(dev) ；
#             Nikki Concord 由 diy-part2.sh 以预编译 ipk 注入；
#             已移除上游 dae / honk 变体拉取（本仓库只出 openclash 变体）。
# ================================================================

# 严格模式 + pipefail，任何命令失败都立即退出
set -Eeuo pipefail
IFS=$'\n\t'

readonly SCRIPT_START=$(date +%s)
readonly PKG_DIR="$(pwd)/package/custom"          # 绝对路径，中途 cd 不失效
readonly PKGINFO="tmp/.packageinfo"

# ---------------------------------------------------------
# 插件开关（显式声明每一个，避免未定义变量）
# ---------------------------------------------------------
readonly ADD_AIROHA_NPU=true    # luci-app-airoha-npu（Airoha SoC 状态页）

# ---------------------------------------------------------
# 插件清单——"开关 + 仓库 + 目录 + 分支"集中在这里
# ---------------------------------------------------------
readonly PKG_LIST=(
  "luci-app-airoha-npu|${ADD_AIROHA_NPU}|https://github.com/luanmuc/luci-app-airoha-npu|main"
)

log()     { echo "[$(date '+%H:%M:%S')] $*"; }
die()     { echo "::error::$*" >&2; exit 1; }
group()   { echo "::group::$*"; }
endgroup(){ echo "::endgroup::"; }

# 带指数退避的重试
retry() {
  local attempts=$1 max=$2; shift 2
  while (( attempts <= max )); do
    if "$@"; then return 0; fi
    local rc=$?
    log "  ↻ 第 ${attempts}/${max} 次失败（rc=${rc}），${attempts}0s 后重试…"
    sleep $(( attempts * 10 ))
    attempts=$(( attempts + 1 ))
  done
  return 1
}

# git clone：正确处理退出码，日志写文件，失败时全量输出
clone() {
  # clone <url> <dest> [branch] [filter]
  local url="$1" dir="$2" br="${3:-}" filter="${4:---depth=1}"

  # 目录里含 .git 才算"已克隆"，半成品目录清掉重来
  if [ -d "$dir/.git" ]; then
    log "  ↷ 已存在，跳过: $dir"
    return 0
  fi
  rm -rf "$dir"

  local log_file
  log_file="$(mktemp /tmp/clone-XXXXXX.log)"
  local args=(git clone --progress $filter)
  [ -n "$br" ] && args+=(-b "$br")
  args+=("$url" "$dir")

  log "  ⤓ $(basename "$url") -> $dir"
  if ! retry 1 3 "${args[@]}" >"$log_file" 2>&1; then
    echo "--- git clone 失败，完整日志 ---" >&2
    cat "$log_file" >&2
    echo "-----------------------------------" >&2
    rm -f "$log_file"
    return 1
  fi
  rm -f "$log_file"

  if [ ! -f "$dir/Makefile" ]; then
    log "  ⚠ $dir 无根 Makefile，视为源仓库/子包容器"
  fi
  local commit
  commit=$(git -C "$dir" rev-parse --short HEAD 2>/dev/null || echo "unknown")
  log "  ✅ $(basename "$dir") @ ${commit}"
}

# ================================================================
# 主流程
# ================================================================
group "拉取可选插件 (diy-part1.sh)"
mkdir -p "$PKG_DIR"
endgroup

group "克隆插件仓库（共 ${#PKG_LIST[@]} 项清单）"
ENABLED_COUNT=0
FAILED_PKGS=()
for entry in "${PKG_LIST[@]}"; do
  IFS='|' read -r name enabled url branch <<<"$entry"
  if [ "$enabled" != "true" ]; then
    log "  ⊘ $name 未启用"
    continue
  fi
  ENABLED_COUNT=$((ENABLED_COUNT + 1))
  if ! clone "$url" "$PKG_DIR/$name" "$branch"; then
    FAILED_PKGS+=("$name")
    echo "::error::克隆失败: $name ($url)"
  fi
done
endgroup

# 特殊处理：个别仓库根目录 + 同名子目录各放一份会打断扫描
if [ "$ADD_AIROHA_NPU" = "true" ] && [ -d "$PKG_DIR/luci-app-airoha-npu/luci-app-airoha-npu" ]; then
  rm -rf "$PKG_DIR/luci-app-airoha-npu/luci-app-airoha-npu"
  log "  ✂ 已移除重复嵌套目录: luci-app-airoha-npu/luci-app-airoha-npu"
fi

(( ${#FAILED_PKGS[@]} == 0 )) || die "以下插件克隆失败: ${FAILED_PKGS[*]}"

group "重建包索引"
# 必须连 stamp 一起删：prepare-tmpinfo 有 scan_unchanged 优化，
# stamp 不删的话索引不会真正重建
rm -f tmp/.packageinfo tmp/.targetinfo
rm -f tmp/info/.scan-packageinfo.stamp tmp/info/.scan-targetinfo.stamp
rm -f tmp/.config-package.in tmp/.config-target.in

make -s prepare-tmpinfo OPENWRT_BUILD= 2>&1 | tail -5 || true
[ -s "$PKGINFO" ] || die "$PKGINFO 为空，prepare-tmpinfo 失败"
log "  ✅ tmp/.packageinfo 共 $(grep -c '^Package: ' "$PKGINFO") 个包"
endgroup

group "必装插件硬校验"
# config 里已写 =y 的包都必须出现在这里，否则 defconfig 会静默剔除
CRITICAL_PKGS=(luci-app-airoha-npu)

[ -f feeds/luci/luci.mk ] || die "feeds/luci/luci.mk 缺失，LuCI app 无法解析"

HARD_MISS=()
for r in "${CRITICAL_PKGS[@]}"; do
  grep -qx "Package: $r" "$PKGINFO" || HARD_MISS+=("$r")
done

if (( ${#HARD_MISS[@]} > 0 )); then
  for m in "${HARD_MISS[@]}"; do
    echo "::error::必装插件 $m 未进索引，defconfig 会静默剔除 =y"
  done
  exit 1
fi
log "  ✅ 必装插件全部就绪: ${CRITICAL_PKGS[*]}"
endgroup

# OpenClash update to latest version (dev 分支)
rm -rf feeds/luci/applications/luci-app-openclash
git clone --depth=1 -b dev https://github.com/vernesong/OpenClash.git feeds/luci/applications/luci-app-openclash

# ================================================================
# 输出 GitHub Step Summary，Actions 页面直接看结果
# ================================================================
if [ -n "${GITHUB_STEP_SUMMARY:-}" ]; then
  {
    echo "## diy-part1.sh 执行报告"
    echo ""
    echo "| 项目 | 值 |"
    echo "|---|---|"
    echo "| 启用插件 | ${ENABLED_COUNT} / ${#PKG_LIST[@]} |"
    echo "| 必装校验 | ✅ 通过（${CRITICAL_PKGS[*]}） |"
    echo "| 耗时 | $(( $(date +%s) - SCRIPT_START ))s |"
  } >> "$GITHUB_STEP_SUMMARY"
fi

log "🎉 diy-part1.sh 执行完毕"
