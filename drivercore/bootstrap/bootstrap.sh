#!/usr/bin/env bash
# AgentOS bootstrap (Linux / macOS entry)
#
# AgentOS 的安装实现是 PowerShell（install.ps1）；本脚本只做 POSIX 入口与参数转译，
# 不复制第二套 skill 安装逻辑。需要 PowerShell 7（pwsh）。
#
# 用法: bash drivercore/bootstrap/bootstrap.sh [HomeBase] [--dry-run] [--force]
# 默认 homebase = AgentOS 仓库的父目录（<homebase>/agentos），可用 HomeBase 参数或 AGENTOS_HOME 覆盖。
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
HOMEBASE=""
DRY=0
FORCE=0
for arg in "$@"; do
  case "$arg" in
    -n|--dry-run) DRY=1 ;;
    -f|--force)   FORCE=1 ;;
    -h|--help)
      echo "usage: bash bootstrap.sh [HomeBase] [--dry-run] [--force]"
      exit 0
      ;;
    *)
      if [ -n "$HOMEBASE" ]; then
        echo "[err] 只接受一个 HomeBase 参数: $arg" >&2
        exit 1
      fi
      HOMEBASE="$arg"
      ;;
  esac
done
if [ -z "$HOMEBASE" ]; then
  if [ -n "${AGENTOS_HOME:-}" ]; then HOMEBASE="$AGENTOS_HOME"; else HOMEBASE="$(dirname "$ROOT")"; fi
fi

echo "=== AgentOS bootstrap (drivercore, POSIX entry) ==="
echo "agentos:  $ROOT"
echo "homebase: $HOMEBASE"

if ! command -v pwsh >/dev/null 2>&1; then
  echo "[err] 需要 PowerShell 7 (pwsh) 才能执行 install.ps1。"
  echo "      Windows 请直接运行 drivercore/bootstrap/bootstrap.ps1；"
  echo "      Linux/macOS 请先安装 pwsh: https://aka.ms/powershell"
  exit 1
fi

args=(-NoProfile -File "$ROOT/drivercore/bootstrap/bootstrap.ps1" -HomeBase "$HOMEBASE")
if [ "$DRY" = "1" ]; then args+=(-DryRun); fi
if [ "$FORCE" = "1" ]; then args+=(-Force); fi
exec pwsh "${args[@]}"
