#!/usr/bin/env bash
# 비표준 설치경로(예: /app)에 SELinux 레이블 정합. SELinux Enforcing + 경로!=/opt 일 때만 의미.
# /opt 와 동일한 파일컨텍스트 규칙을 INSTALL_ROOT 에 상속(equivalence)시키고 relabel.
set -euo pipefail
source "$(dirname "$0")/env.sh"

[ "${MANAGE_SELINUX}" = "true" ] || { echo ">> MANAGE_SELINUX=false → 스킵"; exit 0; }
command -v getenforce >/dev/null && [ "$(getenforce)" != "Disabled" ] || { echo ">> SELinux 비활성 → 스킵"; exit 0; }
[ "${INSTALL_ROOT}" = "/opt" ] && { echo ">> INSTALL_ROOT=/opt (표준) → 추가 작업 불필요"; exit 0; }

command -v semanage >/dev/null || dnf -y install policycoreutils-python-utils >/dev/null

# 기존 equivalence 있으면 갱신, 없으면 추가
if semanage fcontext -l | grep -q "^${INSTALL_ROOT} = /opt"; then
  echo ">> equivalence ${INSTALL_ROOT} = /opt 이미 존재"
else
  semanage fcontext -a -e /opt "${INSTALL_ROOT}"
fi
restorecon -RvF "${INSTALL_ROOT}" | tail -5 || true
echo ">> SELinux 레이블 정합 완료 (${INSTALL_ROOT} → /opt 규칙 상속)"
