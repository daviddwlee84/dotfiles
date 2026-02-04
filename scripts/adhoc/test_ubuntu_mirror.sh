#!/usr/bin/env bash
set -euo pipefail

# # 大學/社群鏡像（普遍口碑最好）
# https://mirrors.tuna.tsinghua.edu.cn/ubuntu/        # 清華 TUNA  (help page)
# https://mirrors.ustc.edu.cn/ubuntu/                 # 中科大 USTC (help page)
# https://mirror.sjtu.edu.cn/ubuntu/                  # 上海交大 SJTU (help page)
# https://mirrors.bfsu.edu.cn/ubuntu/                 # 北外 BFSU (Ubuntu CN mirror list snippet)
# https://mirrors.zju.edu.cn/ubuntu/                  # 浙大 ZJU  (Ubuntu CN mirror list snippet)
#
# # 雲廠商鏡像（帶寬大、覆蓋廣；Launchpad 有登記）
# https://mirrors.cloud.tencent.com/ubuntu/           # 騰訊雲 Tencent Cloud (Launchpad mirror)
# https://repo.huaweicloud.com/ubuntu/                # 華為雲 Huawei Cloud (Launchpad mirror)
#
# # 官方自動鏡像（會從 mirrors 列表挑，可能抽到不穩定；但「能用就用」時很省事）
# mirror://mirrors.ubuntu.com/mirrors.txt             # apt 支援 mirror://

# 你要測的 Ubuntu 版本代號：noble=24.04, jammy=22.04, focal=20.04
SUITE="${1:-noble}"

MIRRORS=(
  "https://mirrors.tuna.tsinghua.edu.cn/ubuntu"
  "https://mirrors.ustc.edu.cn/ubuntu"
  "https://mirror.sjtu.edu.cn/ubuntu"
  "https://mirrors.bfsu.edu.cn/ubuntu"
  "https://mirrors.zju.edu.cn/ubuntu"
  "https://mirrors.cloud.tencent.com/ubuntu"
  "https://repo.huaweicloud.com/ubuntu"
)

echo "Testing suite: ${SUITE}"
echo

for m in "${MIRRORS[@]}"; do
  url="${m}/dists/${SUITE}/Release"
  # 下載 Release（很小），看總時間；失敗就略過
  t="$(curl -L --connect-timeout 3 --max-time 8 -o /dev/null -s -w '%{time_total}' "$url" || true)"
  if [[ -n "$t" && "$t" != "0.000" ]]; then
    printf "%8s  %s\n" "$t" "$m"
  fi
done | sort -n
