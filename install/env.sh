#!/usr/bin/env bash
# 공통 변수 — 모든 install 스크립트에서 source.
# 모든 값은 환경변수로 주입(override) 가능. 기본값은 "현재 /opt 단일노드 구성"을 재현.
set -euo pipefail

# --- 설치 환경 ---
export AIRFLOW_VERSION="2.11.0"
export PY_TAG="3.9"
export EXTRAS="celery,postgres,redis"

# === [1] 설치 경로 ============================================================
# INSTALL_ROOT 만 바꾸면 전체 트리 이동. 예) 별도 디스크 /app:  INSTALL_ROOT=/app
export INSTALL_ROOT="${INSTALL_ROOT:-/opt}"
export AIRFLOW_HOME="${AIRFLOW_HOME:-${INSTALL_ROOT}/airflow}"
export VENV="${VENV:-${AIRFLOW_HOME}/venv}"
export INSTALL_DIR="${INSTALL_DIR:-${INSTALL_ROOT}/airflow-install}"   # wheelhouse 적재(전송) 위치
export WHEELHOUSE="${INSTALL_DIR}/wheelhouse"
export CONSTRAINTS="${INSTALL_DIR}/constraints-${PY_TAG}.txt"

# === [2] 실행 계정 ============================================================
# 조직이 미리 만든 계정을 쓸 수 있음. 그 경우 CREATE_USER=false.
export AIRFLOW_USER="${AIRFLOW_USER:-airflow}"
export AIRFLOW_GROUP="${AIRFLOW_GROUP:-${AIRFLOW_USER}}"
export CREATE_USER="${CREATE_USER:-true}"           # false = 기존 계정 사용(생성 안 함)

# === [3] SELinux ==============================================================
# 비표준 경로(/app 등)는 새 파일시스템 레이블 정합이 필요. /opt 규칙을 상속시킴.
export MANAGE_SELINUX="${MANAGE_SELINUX:-true}"

# --- OS 패키지 소스: 사내 미러(dnf) vs 번들 RPM(완전 오프라인) ---
# RPM_SOURCE=mirror : http 사내 미러에서 dnf (기본, target 이 미러 접근 가능할 때)
# RPM_SOURCE=bundle : 번들에 포함된 로컬 repo(${INSTALL_DIR}/rpms)에서만 설치(미러 불필요)
export RPM_SOURCE="${RPM_SOURCE:-mirror}"
export RHEL_REPO_BASE="${RHEL_REPO_BASE:-http://10.0.1.102/rhel-9.4}"
export LOCAL_RPM_DIR="${LOCAL_RPM_DIR:-${INSTALL_DIR}/rpms}"

# === [4] PostgreSQL: 로컬 직접 구성 vs 외부 서비스 ============================
# DB_MODE=local    : 이 노드에 postgresql-server 설치/초기화/기동 (기본)
# DB_MODE=external : 사내 제공 PostgreSQL(별도 서버/DBaaS) 사용. 로컬 설치 안 함.
export DB_MODE="${DB_MODE:-local}"
export PG_DB="${PG_DB:-airflow}"
export PG_USER="${PG_USER:-airflow}"
export PG_PASSWORD="${PG_PASSWORD:-CHANGE_ME_STRONG}"   # 운영 시 반드시 교체/주입
export PG_HOST="${PG_HOST:-127.0.0.1}"                  # external: 제공받은 DB 호스트
export PG_PORT="${PG_PORT:-5432}"
export PG_SSLMODE="${PG_SSLMODE:-disable}"              # external 관리형은 보통 require/verify-full
# external 모드에서 DB/롤을 우리가 만들어야 할 때만 채움(이미 DBA가 만들면 비워둠).
export PG_ADMIN_USER="${PG_ADMIN_USER:-}"
export PG_ADMIN_PASSWORD="${PG_ADMIN_PASSWORD:-}"

# --- Redis (Phase2 대비) ---
export INSTALL_REDIS="${INSTALL_REDIS:-true}"          # external 브로커면 false 가능
export REDIS_HOST="${REDIS_HOST:-127.0.0.1}"
export REDIS_PORT="${REDIS_PORT:-6379}"

# --- Airflow 관리자 / 보안키 ---
export AF_ADMIN_USER="${AF_ADMIN_USER:-admin}"
export AF_ADMIN_PASSWORD="${AF_ADMIN_PASSWORD:-CHANGE_ME_ADMIN}"
export AF_ADMIN_EMAIL="${AF_ADMIN_EMAIL:-admin@example.com}"
export AF_FERNET_KEY="${AF_FERNET_KEY:-}"              # Phase2 다중노드 시 모든 노드 동일값
export AF_SECRET_KEY="${AF_SECRET_KEY:-}"

# --- Executor (Phase1=LocalExecutor / Phase2=CeleryExecutor) ---
export AF_EXECUTOR="${AF_EXECUTOR:-LocalExecutor}"

# === [5] Phase2 클러스터(역할/IP) ============================================
# ROLE=control : web(webserver+scheduler)+메타DB+브로커  (단일노드 Phase1도 control)
# ROLE=worker  : celery worker 전용. DB/Redis 는 control 에 원격 접속(로컬 설치 안 함)
export ROLE="${ROLE:-control}"
export CONTROL_IP="${CONTROL_IP:-127.0.0.1}"          # web/control 노드 IP (예: 192.168.0.1)
# Phase2에서 모든 노드는 DB/브로커 엔드포인트로 CONTROL_IP 를 바라봄(기본값을 CONTROL_IP로)
export PG_HOST="${PG_HOST:-${CONTROL_IP}}"
export REDIS_HOST="${REDIS_HOST:-${CONTROL_IP}}"
export REDIS_PASSWORD="${REDIS_PASSWORD:-}"           # 설정 시 브로커 인증 활성(Phase2 권장)
# control 노드의 원격 개방(비우면 Phase1 localhost 전용 유지):
export PG_LISTEN_ADDRESSES="${PG_LISTEN_ADDRESSES:-}" # 예: "localhost,192.168.0.1" 또는 "*"
export PG_ALLOW_CIDR="${PG_ALLOW_CIDR:-}"             # 워커 허용 범위 예: 192.168.0.0/24
export OPEN_FIREWALL="${OPEN_FIREWALL:-false}"        # control: 5432/6379/8080 개방, worker: 불필요
export ENABLE_FLOWER="${ENABLE_FLOWER:-false}"        # control: flower(:5555) 기동 여부

# 워커는 로컬 DB/Redis 미설치 강제
if [ "${ROLE}" = "worker" ]; then
  DB_MODE="external"; INSTALL_REDIS="false"
fi

# --- 파생: SQLAlchemy 연결 문자열 ---
export SQLA_CONN="postgresql+psycopg2://${PG_USER}:${PG_PASSWORD}@${PG_HOST}:${PG_PORT}/${PG_DB}?sslmode=${PG_SSLMODE}"

# --- 파생: Celery 브로커 URL (redis 인증 유무 반영) ---
if [ -n "${REDIS_PASSWORD}" ]; then
  export BROKER_URL="redis://:${REDIS_PASSWORD}@${REDIS_HOST}:${REDIS_PORT}/0"
else
  export BROKER_URL="redis://${REDIS_HOST}:${REDIS_PORT}/0"
fi
export RESULT_BACKEND="db+postgresql://${PG_USER}:${PG_PASSWORD}@${PG_HOST}:${PG_PORT}/${PG_DB}?sslmode=${PG_SSLMODE}"
