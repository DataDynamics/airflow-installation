#!/usr/bin/env bash
# 공통 변수 — 모든 install 스크립트에서 source.
# 모든 값은 환경변수로 주입(override) 가능. 기본값은 "현재 /opt 단일노드 구성"을 재현.
set -euo pipefail

# --- 설치 환경 ---
# Airflow 3.2+ 는 Python 3.10+ 필수 → RHEL 9 AppStream 의 python3.11 RPM 사용.
export AIRFLOW_VERSION="3.3.0"
export PY_TAG="3.11"
export PYTHON_BIN="${PYTHON_BIN:-/usr/bin/python3.11}"
# 3.x extras: hdfs→apache-hdfs 개명, password extra 삭제(FAB provider에 통합),
# fab(로그인 UI/사용자 관리)·standard(기본 오퍼레이터) 명시 필요.
export EXTRAS="celery,postgres,redis,fab,standard,common-sql,ssh,apache-kafka,sftp,ftp,apache-hdfs,samba,pandas,uv,async,ldap"

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

# --- OS 패키지 소스: 사내 미러(dnf) vs 번들 RPM(완전 오프라인) vs 기존 repo ---
# RPM_SOURCE=mirror : http 사내 미러에서 dnf (기본, target 이 미러 접근 가능할 때)
# RPM_SOURCE=bundle : 번들에 포함된 로컬 repo(${INSTALL_DIR}/rpms)에서만 설치(미러 불필요)
# RPM_SOURCE=system : 대상 서버에 이미 구성된 dnf repo 그대로 사용(repo 등록 생략)
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
export AF_SECRET_KEY="${AF_SECRET_KEY:-}"              # api-server 세션 서명키([api] secret_key)
export AF_JWT_SECRET="${AF_JWT_SECRET:-}"              # 3.x 신규: Execution API/UI 토큰 서명키. 전 노드 동일 필수

# --- Executor (Phase1=LocalExecutor / Phase2=CeleryExecutor) ---
export AF_EXECUTOR="${AF_EXECUTOR:-LocalExecutor}"

# === [6] airflow.cfg 주요 설정 (설치 시 적용, 중간 규모 프로파일 기본값) =========
# 타임존(KST) / UI
export AF_DEFAULT_TIMEZONE="${AF_DEFAULT_TIMEZONE:-Asia/Seoul}"
export AF_EXPOSE_CONFIG="${AF_EXPOSE_CONFIG:-True}"            # UI Configuration 표시(True/non-sensitive-only/False)
# 코어 동작
export AF_LOAD_EXAMPLES="${AF_LOAD_EXAMPLES:-False}"
export AF_DAGS_PAUSED_AT_CREATION="${AF_DAGS_PAUSED_AT_CREATION:-True}"
export AF_DEFAULT_TASK_RETRIES="${AF_DEFAULT_TASK_RETRIES:-1}"
export AF_DAGBAG_IMPORT_TIMEOUT="${AF_DAGBAG_IMPORT_TIMEOUT:-30}"
export AF_DAG_FILE_PROCESSOR_TIMEOUT="${AF_DAG_FILE_PROCESSOR_TIMEOUT:-50}"
# 성능(중간 규모: 4~8 vCPU 가정)
export AF_PARALLELISM="${AF_PARALLELISM:-64}"
export AF_MAX_ACTIVE_TASKS_PER_DAG="${AF_MAX_ACTIVE_TASKS_PER_DAG:-32}"
export AF_MAX_ACTIVE_RUNS_PER_DAG="${AF_MAX_ACTIVE_RUNS_PER_DAG:-16}"
export AF_MAX_TIS_PER_QUERY="${AF_MAX_TIS_PER_QUERY:-512}"
# 스케줄러 / DAG 프로세서(3.x: 파싱 설정은 [dag_processor] 섹션, 독립 서비스)
export AF_PARSING_PROCESSES="${AF_PARSING_PROCESSES:-2}"
export AF_MIN_FILE_PROCESS_INTERVAL="${AF_MIN_FILE_PROCESS_INTERVAL:-30}"
export AF_DAG_DIR_LIST_INTERVAL="${AF_DAG_DIR_LIST_INTERVAL:-300}"     # 3.x: [dag_processor] refresh_interval
export AF_SCHEDULER_HEARTBEAT_SEC="${AF_SCHEDULER_HEARTBEAT_SEC:-5}"
export AF_CATCHUP_BY_DEFAULT="${AF_CATCHUP_BY_DEFAULT:-False}"
# DB 커넥션 풀
export AF_SQL_POOL_SIZE="${AF_SQL_POOL_SIZE:-10}"
export AF_SQL_MAX_OVERFLOW="${AF_SQL_MAX_OVERFLOW:-20}"
export AF_SQL_POOL_RECYCLE="${AF_SQL_POOL_RECYCLE:-1800}"
export AF_SQL_POOL_PRE_PING="${AF_SQL_POOL_PRE_PING:-True}"
# Celery 워커
export AF_CELERY_WORKER_CONCURRENCY="${AF_CELERY_WORKER_CONCURRENCY:-16}"
# API 서버(3.x: webserver → api-server, FastAPI/uvicorn)
export AF_API_WORKERS="${AF_API_WORKERS:-2}"                  # uvicorn 워커 수
export AF_API_WORKER_TIMEOUT="${AF_API_WORKER_TIMEOUT:-120}"
export AF_API_PORT="${AF_API_PORT:-8080}"
# 표시/보안
export AF_INSTANCE_NAME="${AF_INSTANCE_NAME:-AIRFLOW}"
export AF_EXPOSE_STACKTRACE="${AF_EXPOSE_STACKTRACE:-False}"
# 로깅
export AF_LOGGING_LEVEL="${AF_LOGGING_LEVEL:-INFO}"

# === [5] Phase2 클러스터(역할/IP) ============================================
# ROLE=control : api-server+scheduler+dag-processor+triggerer+메타DB+브로커 (단일노드 Phase1도 control)
# ROLE=worker  : celery worker 전용. 브로커/결과백엔드/Execution API 는 control 로 원격 접속
# ※ 3.x 워커 필요 포트: control 의 6379(broker) + 5432(celery result backend) + 8080(Execution API)
export ROLE="${ROLE:-control}"
export CONTROL_IP="${CONTROL_IP:-127.0.0.1}"          # web/control 노드 IP (예: 192.168.0.1)
# Phase2에서 모든 노드는 DB/브로커 엔드포인트로 CONTROL_IP 를 바라봄(기본값을 CONTROL_IP로)
export PG_HOST="${PG_HOST:-${CONTROL_IP}}"
export REDIS_HOST="${REDIS_HOST:-${CONTROL_IP}}"
export REDIS_PASSWORD="${REDIS_PASSWORD:-}"           # 설정 시 브로커 인증 활성(Phase2 권장)
# control 노드의 원격 개방(비우면 Phase1 localhost 전용 유지):
export PG_LISTEN_ADDRESSES="${PG_LISTEN_ADDRESSES:-}" # 예: "localhost,192.168.0.1" 또는 "*"
export PG_ALLOW_CIDR="${PG_ALLOW_CIDR:-}"             # 워커 허용 범위 예: 192.168.0.0/24
export OPEN_FIREWALL="${OPEN_FIREWALL:-false}"        # control: 5432/6379/8080 개방, worker: 8793(로그 서빙)
export ENABLE_FLOWER="${ENABLE_FLOWER:-false}"        # control: flower(:5555) 기동 여부

# 워커는 로컬 DB/Redis 미설치 강제
if [ "${ROLE}" = "worker" ]; then
  DB_MODE="external"; INSTALL_REDIS="false"
fi

# --- 파생: 연결 URL. 비밀번호는 percent-encoding 필수 ---
# (#/@/: 등 특수문자가 있으면 kombu(celery) URL 파서가 깨짐. SQLAlchemy는 인코딩된 값도 수용)
urlenc() { python3 -c 'import sys,urllib.parse;print(urllib.parse.quote(sys.argv[1], safe=""))' "$1"; }
PG_PASSWORD_ENC="$(urlenc "${PG_PASSWORD}")"

export SQLA_CONN="postgresql+psycopg2://${PG_USER}:${PG_PASSWORD_ENC}@${PG_HOST}:${PG_PORT}/${PG_DB}?sslmode=${PG_SSLMODE}"

# --- 파생: Celery 브로커 URL (redis 인증 유무 반영) ---
if [ -n "${REDIS_PASSWORD}" ]; then
  export BROKER_URL="redis://:$(urlenc "${REDIS_PASSWORD}")@${REDIS_HOST}:${REDIS_PORT}/0"
else
  export BROKER_URL="redis://${REDIS_HOST}:${REDIS_PORT}/0"
fi
export RESULT_BACKEND="db+postgresql://${PG_USER}:${PG_PASSWORD_ENC}@${PG_HOST}:${PG_PORT}/${PG_DB}?sslmode=${PG_SSLMODE}"

# --- 파생: Task Execution API (3.x 신규) ---
# 모든 태스크 실행(로컬/celery)이 api-server 의 /execution/ 을 호출. 워커는 control 을 바라봄.
export AF_EXECUTION_API_URL="${AF_EXECUTION_API_URL:-http://${CONTROL_IP}:${AF_API_PORT}/execution/}"
