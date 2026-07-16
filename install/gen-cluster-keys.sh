#!/usr/bin/env bash
# 클러스터 공통 구성 cluster.env 생성(키 1회 생성). 모든 노드에 '동일 파일' 배포가 핵심.
# 사용: ./gen-cluster-keys.sh [출력경로(기본 ./cluster.env)] [CONTROL_IP] [WORKER_CIDR]
set -euo pipefail
OUT="${1:-./cluster.env}"
CONTROL_IP="${2:-192.168.0.1}"
WORKER_CIDR="${3:-192.168.0.0/24}"

# Fernet 키(32바이트 urlsafe base64) — python 의존 없이 생성
FERNET="$(head -c32 /dev/urandom | base64 | tr '+/' '-_')"
SECRET="$(openssl rand -hex 32)"
JWT_SECRET="$(openssl rand -hex 32)"                              # 3.x: Execution API/UI 토큰 서명키
PG_PW="$(openssl rand -base64 18 | tr -d '/+=' | cut -c1-20)"     # 공백/특수문자 없는 비번
REDIS_PW="$(openssl rand -base64 18 | tr -d '/+=' | cut -c1-20)"
ADMIN_PW="$(openssl rand -base64 12 | tr -d '/+=' | cut -c1-12)"

( umask 077
cat > "${OUT}" <<EOF
# === Airflow 클러스터 공통 구성 — 모든 노드에 동일 배포(600) ===
# 노드에서: source cluster.env;  ROLE=control|worker ./install/install-all.sh
export AF_EXECUTOR=CeleryExecutor
export CONTROL_IP=${CONTROL_IP}
export PG_HOST=${CONTROL_IP}
export REDIS_HOST=${CONTROL_IP}

# --- 공유 비밀(전 노드 동일 필수) ---
export AF_FERNET_KEY='${FERNET}'
export AF_SECRET_KEY='${SECRET}'
export AF_JWT_SECRET='${JWT_SECRET}'
export PG_PASSWORD='${PG_PW}'
export REDIS_PASSWORD='${REDIS_PW}'
export AF_ADMIN_PASSWORD='${ADMIN_PW}'

# --- control 노드 원격 개방(워커에선 무시됨) ---
export PG_LISTEN_ADDRESSES='localhost,${CONTROL_IP}'
export PG_ALLOW_CIDR='${WORKER_CIDR}'
export OPEN_FIREWALL=true
export ENABLE_FLOWER=false
EOF
)
chmod 600 "${OUT}"
echo ">> 생성: ${OUT} (600)"
echo ">> CONTROL_IP=${CONTROL_IP}  WORKER_CIDR=${WORKER_CIDR}"
echo ">> 관리자 초기 비밀번호: ${ADMIN_PW}  (admin)"
echo ">> 이 파일을 모든 노드에 '동일하게' 배포하세요. 키가 다르면 워커가 동작하지 않습니다."
