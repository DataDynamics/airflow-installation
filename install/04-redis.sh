#!/usr/bin/env bash
# Redis 설치 기동 (Phase1: 설치/기동만, localhost). 대상 서버 root 실행.
set -euo pipefail
source "$(dirname "$0")/env.sh"

[ "${INSTALL_REDIS}" = "true" ] || { echo ">> INSTALL_REDIS=false → 로컬 Redis 스킵(외부 브로커 사용)"; exit 0; }

RCONF=/etc/redis/redis.conf
[ -f "${RCONF}" ] || RCONF=/etc/redis.conf      # 배포판별 경로 보정

# --- Phase2: 인증/원격 바인딩(값이 있을 때만; 비우면 Phase1 localhost 유지) ---
if [ -n "${REDIS_PASSWORD}" ]; then
  # requirepass
  if grep -qE "^[# ]*requirepass" "${RCONF}"; then
    sed -ri "s#^[# ]*requirepass\s+.*#requirepass ${REDIS_PASSWORD}#" "${RCONF}"
  else
    echo "requirepass ${REDIS_PASSWORD}" >> "${RCONF}"
  fi
  # bind 127.0.0.1 + CONTROL_IP, protected-mode no(인증이 보호)
  sed -ri "s#^[# ]*bind\s+.*#bind 127.0.0.1 ${CONTROL_IP}#" "${RCONF}"
  sed -ri "s#^[# ]*protected-mode\s+.*#protected-mode no#" "${RCONF}"
  echo ">> Redis 인증/바인딩: bind 127.0.0.1 ${CONTROL_IP}, requirepass(설정)"
fi

systemctl enable redis
systemctl restart redis

# ping (인증 유무 반영)
if [ -n "${REDIS_PASSWORD}" ]; then
  redis-cli -h 127.0.0.1 -p "${REDIS_PORT}" -a "${REDIS_PASSWORD}" ping 2>/dev/null
else
  redis-cli -h 127.0.0.1 -p "${REDIS_PORT}" ping
fi

# --- Phase2: 방화벽 6379 개방(control) ---
if [ "${OPEN_FIREWALL}" = "true" ] && systemctl is-active --quiet firewalld; then
  firewall-cmd --permanent --add-port=6379/tcp >/dev/null && firewall-cmd --reload >/dev/null
  echo ">> firewalld: 6379/tcp 개방"
fi
echo ">> Redis 준비 완료 (REDIS_PASSWORD $( [ -n "${REDIS_PASSWORD}" ] && echo 설정됨 || echo 미설정 ))"
