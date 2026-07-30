#!/usr/bin/env bash
# Redis 브로커 설치/기동. 대상 서버 root 실행.
#   - 단일(Phase1/2): localhost 또는 CONTROL_IP 바인딩, 선택적 requirepass
#   - Sentinel HA (REDIS_SENTINEL_ENABLED=true): master/replica + redis-sentinel
#       * master 장애 시 sentinel 이 replica 를 자동 승격 → 브로커 무중단
#       * 각 redis 노드에 sentinel 을 함께 띄운다(홀수 3대 이상 권장)
#
# 재실행 안전성(중요):
#   이 스크립트는 설치 후에도 반복 실행된다. 페일오버로 master 가 바뀐 뒤 재실행하면
#   인벤토리의 REDIS_MASTER_HOST/REDIS_ROLE 는 이미 낡은 값이다. 그 값을 그대로 쓰면
#   현재 master 를 죽은 옛 노드의 replica 로 강등시키거나 이중 master 를 만든다.
#   그래서 토폴로지는 항상 "Sentinel 이 지금 master 라고 말하는 노드"로 수렴시키고,
#   인벤토리 값은 Sentinel 이 아무것도 모르는 최초 부트스트랩에서만 쓴다.
set -euo pipefail
source "$(dirname "$0")/env.sh"

[ "${INSTALL_REDIS}" = "true" ] || { echo ">> INSTALL_REDIS=false → 로컬 Redis 스킵(외부 브로커 사용)"; exit 0; }

RCONF=/etc/redis/redis.conf
[ -f "${RCONF}" ] || RCONF=/etc/redis.conf      # 배포판별 경로 보정
SCONF=/etc/redis/sentinel.conf

REDIS_SENTINEL_FORCE_REWRITE="${REDIS_SENTINEL_FORCE_REWRITE:-false}"
REDIS_SENTINEL_VERIFY_STRICT="${REDIS_SENTINEL_VERIFY_STRICT:-false}"

# --- redis-cli 래퍼 -----------------------------------------------------------
rcli() {  # 로컬 redis (인증 유무 반영)
  if [ -n "${REDIS_PASSWORD}" ]; then
    redis-cli -h 127.0.0.1 -p "${REDIS_PORT}" -a "${REDIS_PASSWORD}" --no-auth-warning "$@"
  else
    redis-cli -h 127.0.0.1 -p "${REDIS_PORT}" "$@"
  fi
}
scli() {  # sentinel (이 구성의 sentinel 은 requirepass 를 쓰지 않는다)
  redis-cli -h "${1:-127.0.0.1}" -p "${REDIS_SENTINEL_PORT}" --no-auth-warning "${@:2}"
}

# --- 이 노드가 해당 주소의 주인인지 판정 ---------------------------------------
# REDIS_ROLE(운영자 선언)에 의존하지 않는다. 오설정 하나로 split-brain 이 나기 때문.
is_local_addr() {
  local a="$1"
  ip -4 -o addr show 2>/dev/null | awk '{print $4}' | cut -d/ -f1 | grep -qx "${a}" && return 0
  [ "${a}" = "$(hostname -s 2>/dev/null)" ] && return 0
  [ "${a}" = "$(hostname -f 2>/dev/null)" ] && return 0
  return 1
}
node_is_master() {
  local m="$1"
  is_local_addr "${m}" && return 0
  # IP/호스트명으로 판정할 수 없으면(예: DNS 별칭) 운영자 선언에 위임
  if ! ip -4 -o addr show >/dev/null 2>&1; then
    [ "${REDIS_ROLE}" = "master" ] && [ "${m}" = "${REDIS_MASTER_HOST}" ] && return 0
  fi
  return 1
}

# --- 현재 master 결정: Sentinel 우선, 없으면 부트스트랩 값 ---------------------
sentinel_master_addr() {
  local h out
  # 로컬 sentinel 먼저(가장 빠르고 확실), 없으면 피어들에게 물어본다.
  out="$(scli 127.0.0.1 sentinel get-master-addr-by-name "${REDIS_MASTER_NAME}" 2>/dev/null | head -1 || true)"
  [ -n "${out}" ] && { echo "${out}"; return 0; }
  for h in ${REDIS_SENTINEL_HOSTS//,/ }; do
    out="$(scli "${h}" sentinel get-master-addr-by-name "${REDIS_MASTER_NAME}" 2>/dev/null | head -1 || true)"
    [ -n "${out}" ] && { echo "${out}"; return 0; }
  done
  return 0
}

EFF_MASTER="${REDIS_MASTER_HOST}"
if [ "${REDIS_SENTINEL_ENABLED}" = "true" ]; then
  _sm="$(sentinel_master_addr)"
  if [ -n "${_sm}" ]; then
    EFF_MASTER="${_sm}"
    if [ "${EFF_MASTER}" != "${REDIS_MASTER_HOST}" ]; then
      echo ">> Sentinel 기준 현재 master = ${EFF_MASTER} (인벤토리 REDIS_MASTER_HOST=${REDIS_MASTER_HOST} 는 낡은 값이므로 무시)"
    else
      echo ">> Sentinel 기준 현재 master = ${EFF_MASTER}"
    fi
  else
    echo ">> Sentinel 미초기화 → 부트스트랩 master 사용: ${EFF_MASTER}"
  fi
fi

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
# 블록 밖(Sentinel 이 CONFIG REWRITE 로 써 둔) replicaof/slaveof 는 제거한다.
# 우리 블록은 파일 끝에 붙어 마지막 값이 이기므로, 남겨두면 두 값이 뒤섞여 헷갈린다.
# 여기서 지우고 아래에서 'Sentinel 이 말하는 현재 master' 기준으로 다시 쓴다.
sed -ri '/^[[:space:]]*(replicaof|slaveof)[[:space:]]/d' "${RCONF}"
{
  echo "# === AF-REDIS ==="
  echo "bind ${REDIS_BIND}"
  echo "protected-mode no"
  echo "port ${REDIS_PORT}"
  if [ -n "${REDIS_PASSWORD}" ]; then
    echo "requirepass ${REDIS_PASSWORD}"
    echo "masterauth ${REDIS_PASSWORD}"      # 승격/재합류 시 복제 인증에 필요(항상 설정)
  fi
  if [ "${REDIS_SENTINEL_ENABLED}" = "true" ] && ! node_is_master "${EFF_MASTER}"; then
    echo "replicaof ${EFF_MASTER} ${REDIS_PORT}"
  fi
  echo "# === AF-REDIS-END ==="
} >> "${RCONF}"
# sentinel/redis 가 장애복구 시 자기 conf 를 rewrite 할 수 있도록 소유권 부여
chown redis:redis "${RCONF}" 2>/dev/null || true
chmod 0640 "${RCONF}" 2>/dev/null || true

systemctl enable redis
systemctl restart redis

rcli ping
if [ "${REDIS_SENTINEL_ENABLED}" = "true" ]; then
  if node_is_master "${EFF_MASTER}"; then _r=master; else _r="replica of ${EFF_MASTER}"; fi
else
  _r="${REDIS_ROLE}"
fi
echo ">> Redis 기동 (${_r}, bind=${REDIS_BIND})"

# --- Sentinel (HA) ---
if [ "${REDIS_SENTINEL_ENABLED}" = "true" ]; then
  # ⚠ sentinel.conf 를 매번 덮어쓰면 안 된다.
  #   Sentinel 은 이 파일에 학습 결과(known-replica/known-sentinel/epoch)를 직접 기록한다.
  #   덮어쓰면 monitor 대상이 부트스트랩 값으로 되돌아가, 페일오버 이후 재실행 시
  #   sentinel 들이 옛 master(죽었을 수도 있는 노드)를 다시 가리킨다.
  #   ⚠ '파일이 있는가'로 판단해도 안 된다 — redis 패키지가 stock sentinel.conf
  #     (mymaster 127.0.0.1 6379)를 이미 설치해 두기 때문에 항상 '있음'이 된다.
  #     '우리 master 이름이 들어 있는가'로 판단해야 한다.
  if grep -qE "^sentinel monitor ${REDIS_MASTER_NAME}[[:space:]]" "${SCONF}" 2>/dev/null \
     && [ "${REDIS_SENTINEL_FORCE_REWRITE}" != "true" ]; then
    echo ">> sentinel.conf 에 ${REDIS_MASTER_NAME} 설정 존재 → 학습 상태 보존(재작성 안 함)"
    # 정적 설정만 보정한다. 특히 bind 는 위의 함정 때문에 반드시 0.0.0.0 이어야 한다.
    if grep -qE '^[[:space:]]*bind[[:space:]]' "${SCONF}"; then
      sed -ri 's#^[[:space:]]*bind[[:space:]].*#bind 0.0.0.0#' "${SCONF}"
    else
      sed -i '1i bind 0.0.0.0' "${SCONF}"
    fi
  else
    {
      echo "port ${REDIS_SENTINEL_PORT}"
      echo "bind 0.0.0.0"
      echo "protected-mode no"
      echo "dir /var/lib/redis"
      echo "sentinel monitor ${REDIS_MASTER_NAME} ${EFF_MASTER} ${REDIS_PORT} ${REDIS_SENTINEL_QUORUM}"
      [ -n "${REDIS_PASSWORD}" ] && echo "sentinel auth-pass ${REDIS_MASTER_NAME} ${REDIS_PASSWORD}"
      echo "sentinel down-after-milliseconds ${REDIS_MASTER_NAME} ${REDIS_SENTINEL_DOWN_AFTER_MS}"
      echo "sentinel failover-timeout ${REDIS_MASTER_NAME} ${REDIS_SENTINEL_FAILOVER_TIMEOUT_MS}"
      echo "sentinel parallel-syncs ${REDIS_MASTER_NAME} 1"
    } > "${SCONF}"
    echo ">> sentinel.conf 신규 작성 (monitor ${REDIS_MASTER_NAME} ${EFF_MASTER}:${REDIS_PORT} quorum=${REDIS_SENTINEL_QUORUM})"
  fi
  chown redis:redis "${SCONF}"; chmod 0640 "${SCONF}"

  systemctl enable redis-sentinel
  systemctl restart redis-sentinel

  if [ "${OPEN_FIREWALL}" = "true" ] && systemctl is-active --quiet firewalld; then
    firewall-cmd --permanent --add-port="${REDIS_SENTINEL_PORT}/tcp" >/dev/null && firewall-cmd --reload >/dev/null
    echo ">> firewalld: ${REDIS_SENTINEL_PORT}/tcp 개방(sentinel)"
  fi

  # --- 검증 -------------------------------------------------------------------
  # ⚠ get-master-addr-by-name 이 값을 돌려준다고 정상이 아니다. 그 값은 우리가 써 넣은
  #   monitor 설정을 되읽는 것이라, master 에 접속조차 못 하고 peer 를 하나도 발견하지
  #   못한 상태에서도 통과한다. 그래서 아래 세 가지를 실제로 확인한다:
  #     ① flags 에 s_down/o_down 이 없다  → master 에 실제로 붙어 있다
  #     ② num-other-sentinels >= quorum-1 → 정족수를 채울 peer 를 발견했다
  #     ③ num-slaves >= 1                 → 승격시킬 후보가 있다
  #   ②③은 노드를 순차 설치하는 도중에는 아직 성립하지 않을 수 있어 기본은 경고다.
  #   전 노드 설치 후 REDIS_SENTINEL_VERIFY_STRICT=true 로 한 번 확인할 것.
  s_flags=""; s_peers=0; s_slaves=0
  for _i in $(seq 1 12); do
    _info="$(scli 127.0.0.1 sentinel master "${REDIS_MASTER_NAME}" 2>/dev/null | paste - - || true)"
    s_flags="$(awk '$1=="flags"{print $2}' <<<"${_info}")"
    s_peers="$(awk '$1=="num-other-sentinels"{print $2}' <<<"${_info}")"
    s_slaves="$(awk '$1=="num-slaves"{print $2}' <<<"${_info}")"
    case "${s_flags:-}" in
      ""|*s_down*|*o_down*) sleep 5 ;;
      *) break ;;
    esac
  done

  if [ -z "${s_flags:-}" ] || [[ "${s_flags}" == *_down* ]]; then
    echo "ERROR: Sentinel 이 master(${EFF_MASTER}:${REDIS_PORT})에 접속하지 못합니다 (flags=${s_flags:-없음})."
    echo "       확인: ① sentinel.conf 의 bind 가 0.0.0.0 인가"
    echo "             ② ${REDIS_SENTINEL_PORT}/${REDIS_PORT} 방화벽이 노드 간 열려 있는가"
    echo "             ③ REDIS_PASSWORD 와 sentinel auth-pass 가 일치하는가"
    echo "       상세: /var/log/redis/sentinel.log"
    exit 1
  fi

  _need_peers=$(( REDIS_SENTINEL_QUORUM - 1 ))
  echo ">> Sentinel 상태: master=${EFF_MASTER} peers=${s_peers:-0} replicas=${s_slaves:-0} (quorum=${REDIS_SENTINEL_QUORUM})"
  if [ "${s_peers:-0}" -lt "${_need_peers}" ] || [ "${s_slaves:-0}" -lt 1 ]; then
    _msg="Sentinel 이 아직 페일오버 가능한 상태가 아닙니다 (peers=${s_peers:-0} < ${_need_peers} 또는 replicas=${s_slaves:-0} < 1)."
    if [ "${REDIS_SENTINEL_VERIFY_STRICT}" = "true" ]; then
      echo "ERROR: ${_msg}"; exit 1
    fi
    echo "WARN:  ${_msg}"
    echo "       노드를 순차 설치하는 중이면 정상입니다. 전 노드 설치 후"
    echo "       REDIS_SENTINEL_VERIFY_STRICT=true ./install/04-redis.sh 로 반드시 재확인하세요."
    echo "       (이 조건이 깨져 있어도 평소에는 아무 증상이 없고, master 장애 시에만 드러납니다)"
  fi
fi

# --- Phase2/HA: 방화벽 6379 개방 ---
if [ "${OPEN_FIREWALL}" = "true" ] && systemctl is-active --quiet firewalld; then
  firewall-cmd --permanent --add-port="${REDIS_PORT}/tcp" >/dev/null && firewall-cmd --reload >/dev/null
  echo ">> firewalld: ${REDIS_PORT}/tcp 개방"
fi
echo ">> Redis 준비 완료 (sentinel=${REDIS_SENTINEL_ENABLED}, REDIS_PASSWORD $( [ -n "${REDIS_PASSWORD}" ] && echo 설정됨 || echo 미설정 ))"
