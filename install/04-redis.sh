#!/usr/bin/env bash
# Redis 브로커 설치/기동. 대상 서버 root 실행.
#   - 단일(Phase1/2): localhost 또는 CONTROL_IP 바인딩, 선택적 requirepass
#   - Sentinel HA (REDIS_SENTINEL_ENABLED=true): master/replica + redis-sentinel
#       * master 장애 시 sentinel 이 replica 를 자동 승격 → 브로커 무중단
#       * 각 redis 노드에 sentinel 을 함께 띄운다(홀수 3대 이상 권장)
set -euo pipefail
source "$(dirname "$0")/env.sh"

[ "${INSTALL_REDIS}" = "true" ] || { echo ">> INSTALL_REDIS=false → 로컬 Redis 스킵(외부 브로커 사용)"; exit 0; }

RCONF=/etc/redis/redis.conf
[ -f "${RCONF}" ] || RCONF=/etc/redis.conf      # 배포판별 경로 보정

# --- 바인딩 주소 결정 ---
# Sentinel(다중 노드)이면 0.0.0.0 로 열고 requirepass 로 보호한다.
#   (bind 를 "127.0.0.1 <ip>" 로 두면 sentinel 이 loopback 을 나가는 연결의 소스로 잡아
#    원격 master/sentinel 접속에 실패하는 사례가 있어, 다중 노드에서는 0.0.0.0 를 쓴다.)
if [ "${REDIS_SENTINEL_ENABLED}" = "true" ]; then
  REDIS_BIND="0.0.0.0"
else
  REDIS_BIND="127.0.0.1 ${REDIS_HOST}"
fi

# --- redis.conf 멱등 오버라이드 블록(개별 라인 sed 대신 블록 재작성) ---
sed -i '/# === AF-REDIS ===/,/# === AF-REDIS-END ===/d' "${RCONF}"
{
  echo "# === AF-REDIS ==="
  echo "bind ${REDIS_BIND}"
  echo "protected-mode no"
  echo "port ${REDIS_PORT}"
  if [ -n "${REDIS_PASSWORD}" ]; then
    echo "requirepass ${REDIS_PASSWORD}"
    echo "masterauth ${REDIS_PASSWORD}"      # 승격/재합류 시 복제 인증에 필요(항상 설정)
  fi
  if [ "${REDIS_SENTINEL_ENABLED}" = "true" ] && [ "${REDIS_ROLE}" = "replica" ]; then
    echo "replicaof ${REDIS_MASTER_HOST} ${REDIS_PORT}"
  fi
  echo "# === AF-REDIS-END ==="
} >> "${RCONF}"
# sentinel/redis 가 장애복구 시 자기 conf 를 rewrite 할 수 있도록 소유권 부여
chown redis:redis "${RCONF}" 2>/dev/null || true
chmod 0640 "${RCONF}" 2>/dev/null || true

systemctl enable redis
systemctl restart redis

# ping (인증 유무 반영)
if [ -n "${REDIS_PASSWORD}" ]; then
  redis-cli -h 127.0.0.1 -p "${REDIS_PORT}" -a "${REDIS_PASSWORD}" --no-auth-warning ping
else
  redis-cli -h 127.0.0.1 -p "${REDIS_PORT}" ping
fi
echo ">> Redis 기동 (role=${REDIS_ROLE}, bind=${REDIS_BIND})"

# --- Sentinel (HA) ---
if [ "${REDIS_SENTINEL_ENABLED}" = "true" ]; then
  SCONF=/etc/redis/sentinel.conf
  # sentinel 은 이 파일을 실행 중 rewrite(known-replica/known-sentinel 추가)하므로
  # 깨끗한 초기 설정으로 덮어쓰고 redis 소유권을 준다.
  {
    echo "port ${REDIS_SENTINEL_PORT}"
    echo "bind 0.0.0.0"
    echo "protected-mode no"
    echo "dir /var/lib/redis"
    echo "sentinel monitor ${REDIS_MASTER_NAME} ${REDIS_MASTER_HOST} ${REDIS_PORT} ${REDIS_SENTINEL_QUORUM}"
    [ -n "${REDIS_PASSWORD}" ] && echo "sentinel auth-pass ${REDIS_MASTER_NAME} ${REDIS_PASSWORD}"
    echo "sentinel down-after-milliseconds ${REDIS_MASTER_NAME} ${REDIS_SENTINEL_DOWN_AFTER_MS}"
    echo "sentinel failover-timeout ${REDIS_MASTER_NAME} ${REDIS_SENTINEL_FAILOVER_TIMEOUT_MS}"
    echo "sentinel parallel-syncs ${REDIS_MASTER_NAME} 1"
  } > "${SCONF}"
  chown redis:redis "${SCONF}"; chmod 0640 "${SCONF}"

  systemctl enable redis-sentinel
  systemctl restart redis-sentinel

  if [ "${OPEN_FIREWALL}" = "true" ] && systemctl is-active --quiet firewalld; then
    firewall-cmd --permanent --add-port="${REDIS_SENTINEL_PORT}/tcp" >/dev/null && firewall-cmd --reload >/dev/null
    echo ">> firewalld: ${REDIS_SENTINEL_PORT}/tcp 개방(sentinel)"
  fi
  echo ">> Sentinel 기동: monitor ${REDIS_MASTER_NAME} ${REDIS_MASTER_HOST}:${REDIS_PORT} quorum=${REDIS_SENTINEL_QUORUM}"
fi

# --- Phase2/HA: 방화벽 6379 개방 ---
if [ "${OPEN_FIREWALL}" = "true" ] && systemctl is-active --quiet firewalld; then
  firewall-cmd --permanent --add-port="${REDIS_PORT}/tcp" >/dev/null && firewall-cmd --reload >/dev/null
  echo ">> firewalld: ${REDIS_PORT}/tcp 개방"
fi
echo ">> Redis 준비 완료 (sentinel=${REDIS_SENTINEL_ENABLED}, REDIS_PASSWORD $( [ -n "${REDIS_PASSWORD}" ] && echo 설정됨 || echo 미설정 ))"
