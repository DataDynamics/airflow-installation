#!/usr/bin/env bash
# airflow.cfg(비밀 제외) + 비밀 env파일(키 영속화) + db migrate + 관리자 + systemd 등록.
# ① 키 영속화  ② cfg 멱등(백업)  ③ 비밀 분리(평문 cfg 금지, env 주입)
set -euo pipefail
source "$(dirname "$0")/env.sh"

AF="${VENV}/bin/airflow"
SECRETS_FILE="${AIRFLOW_HOME}/airflow-secrets.env"     # 600, 모든 비밀
SYS_ENV="/etc/systemd/system/airflow.env"             # 비밀 아님(AIRFLOW_HOME)
CFG="${AIRFLOW_HOME}/airflow.cfg"

mkdir -p "${AIRFLOW_HOME}"

# --- ① 보안키 영속화: env주입 > 기존 secrets파일 재사용 > 신규생성 ---
prev() { [ -f "${SECRETS_FILE}" ] && sed -n "s/^$1=//p" "${SECRETS_FILE}" | head -1 || true; }
FERNET="${AF_FERNET_KEY:-$(prev AIRFLOW__CORE__FERNET_KEY)}"
SECRET="${AF_SECRET_KEY:-$(prev AIRFLOW__WEBSERVER__SECRET_KEY)}"
# 워커는 control 과 동일 키가 필수 — 신규 생성 금지(주입/배포된 키만 허용)
if [ "${ROLE}" = "worker" ]; then
  [ -n "${FERNET}" ] && [ -n "${SECRET}" ] || {
    echo "ERROR: ROLE=worker 는 control 과 동일한 AF_FERNET_KEY/AF_SECRET_KEY 주입 필요"
    echo "       (cluster-secrets.env 배포 또는 환경변수 주입)"; exit 1; }
else
  [ -n "${FERNET}" ] || FERNET="$("${VENV}/bin/python" -c 'from cryptography.fernet import Fernet;print(Fernet.generate_key().decode())')"
  [ -n "${SECRET}" ] || SECRET="$(openssl rand -hex 32)"
fi
# BROKER_URL / RESULT_BACKEND 은 env.sh 에서 파생(redis 인증·sslmode 반영)

# --- ③ 비밀 분리: 모든 비밀을 600 env파일로(평문 cfg 금지). 비밀은 공백 없는 값 전제 ---
( umask 077
cat > "${SECRETS_FILE}" <<EOF
AIRFLOW__DATABASE__SQL_ALCHEMY_CONN=${SQLA_CONN}
AIRFLOW__CORE__FERNET_KEY=${FERNET}
AIRFLOW__WEBSERVER__SECRET_KEY=${SECRET}
AIRFLOW__CELERY__BROKER_URL=${BROKER_URL}
AIRFLOW__CELERY__RESULT_BACKEND=${RESULT_BACKEND}
EOF
)
chown "${AIRFLOW_USER}:${AIRFLOW_GROUP}" "${SECRETS_FILE}"; chmod 600 "${SECRETS_FILE}"

# --- ② airflow.cfg 멱등: 존재하면 타임스탬프 백업 후 재생성(비밀 미포함) ---
if [ -f "${CFG}" ]; then
  cp -a "${CFG}" "${CFG}.bak.$(date +%Y%m%d%H%M%S)"
  echo ">> 기존 airflow.cfg 백업: ${CFG}.bak.*"
fi
cat > "${CFG}" <<EOF
# 비밀(DB비번/fernet/secret/broker/result)은 ${SECRETS_FILE}(600)에서
# 환경변수(AIRFLOW__SECTION__KEY)로 주입됨 — 이 파일에는 평문 비밀을 두지 않음.
[core]
executor = ${AF_EXECUTOR}
dags_folder = ${AIRFLOW_HOME}/dags
plugins_folder = ${AIRFLOW_HOME}/plugins
default_timezone = ${AF_DEFAULT_TIMEZONE}
load_examples = ${AF_LOAD_EXAMPLES}
dags_are_paused_at_creation = ${AF_DAGS_PAUSED_AT_CREATION}
default_task_retries = ${AF_DEFAULT_TASK_RETRIES}
dagbag_import_timeout = ${AF_DAGBAG_IMPORT_TIMEOUT}
dag_file_processor_timeout = ${AF_DAG_FILE_PROCESSOR_TIMEOUT}
parallelism = ${AF_PARALLELISM}
max_active_tasks_per_dag = ${AF_MAX_ACTIVE_TASKS_PER_DAG}
max_active_runs_per_dag = ${AF_MAX_ACTIVE_RUNS_PER_DAG}

[database]
sql_alchemy_pool_size = ${AF_SQL_POOL_SIZE}
sql_alchemy_max_overflow = ${AF_SQL_MAX_OVERFLOW}
sql_alchemy_pool_recycle = ${AF_SQL_POOL_RECYCLE}
sql_alchemy_pool_pre_ping = ${AF_SQL_POOL_PRE_PING}

[scheduler]
parsing_processes = ${AF_PARSING_PROCESSES}
min_file_process_interval = ${AF_MIN_FILE_PROCESS_INTERVAL}
dag_dir_list_interval = ${AF_DAG_DIR_LIST_INTERVAL}
scheduler_heartbeat_sec = ${AF_SCHEDULER_HEARTBEAT_SEC}
catchup_by_default = ${AF_CATCHUP_BY_DEFAULT}
max_tis_per_query = ${AF_MAX_TIS_PER_QUERY}

[celery]
worker_concurrency = ${AF_CELERY_WORKER_CONCURRENCY}

[logging]
base_log_folder = ${AIRFLOW_HOME}/logs
logging_level = ${AF_LOGGING_LEVEL}

[api]
auth_backends = ${AF_API_AUTH_BACKENDS}

[webserver]
web_server_port = ${AF_WEB_SERVER_PORT}
default_ui_timezone = ${AF_UI_TIMEZONE}
expose_config = ${AF_EXPOSE_CONFIG}
instance_name = ${AF_INSTANCE_NAME}
navbar_color = ${AF_NAVBAR_COLOR}
expose_hostname = ${AF_EXPOSE_HOSTNAME}
expose_stacktrace = ${AF_EXPOSE_STACKTRACE}
warn_deployment_exposure = ${AF_WARN_DEPLOYMENT_EXPOSURE}
workers = ${AF_WEBSERVER_WORKERS}
worker_class = ${AF_WORKER_CLASS}
web_server_worker_timeout = ${AF_WEB_WORKER_TIMEOUT}
EOF
chown "${AIRFLOW_USER}:${AIRFLOW_GROUP}" "${CFG}"; chmod 640 "${CFG}"

# --- CLI 실행 헬퍼: 비밀 env를 ps 노출 없이 주입(source) ---
run_af() {
  sudo -u "${AIRFLOW_USER}" env AIRFLOW_HOME="${AIRFLOW_HOME}" bash -c \
    'set -a; source "$1"; set +a; shift; exec "$@"' _ "${SECRETS_FILE}" "${AF}" "$@"
}

# DB 스키마/관리자는 control 노드만 소유(워커는 수행 금지 — 이미 마이그레이션된 DB 사용)
if [ "${ROLE}" = "control" ]; then
  run_af db migrate
  run_af users create --username "${AF_ADMIN_USER}" --firstname Air --lastname Flow \
    --role Admin --email "${AF_ADMIN_EMAIL}" --password "${AF_ADMIN_PASSWORD}" || true
else
  echo ">> ROLE=worker → db migrate/관리자 생성 생략(원격 DB 연결만 검증)"
  run_af db check
fi

# --- systemd: 비밀 env파일을 EnvironmentFile로 주입(평문 인자 노출 없음) ---
echo "AIRFLOW_HOME=${AIRFLOW_HOME}" > "${SYS_ENV}"
render_unit() {  # $1=name $2=subcommand $3=extra After
  cat > "/etc/systemd/system/airflow-$1.service" <<EOF
[Unit]
Description=Airflow $1
After=network.target $3
[Service]
User=${AIRFLOW_USER}
Group=${AIRFLOW_GROUP}
EnvironmentFile=${SYS_ENV}
EnvironmentFile=${SECRETS_FILE}
ExecStart=${VENV}/bin/airflow $2
Restart=on-failure
RestartSec=5s
KillMode=mixed
[Install]
WantedBy=multi-user.target
EOF
}
DBDEP=""; [ "${DB_MODE}" = "local" ] && DBDEP="postgresql.service"
render_unit webserver "webserver" "${DBDEP}"
render_unit scheduler "scheduler" "${DBDEP}"
render_unit worker    "celery worker" ""
[ "${ENABLE_FLOWER}" = "true" ] && render_unit flower "celery flower" ""

systemctl daemon-reload
# 역할별 기동 서비스
if [ "${ROLE}" = "control" ]; then
  SERVICES="airflow-scheduler airflow-webserver"
  [ "${ENABLE_FLOWER}" = "true" ] && SERVICES="${SERVICES} airflow-flower"
else
  SERVICES="airflow-worker"
fi
systemctl enable ${SERVICES} >/dev/null 2>&1 || true
systemctl restart ${SERVICES}

echo ">> Airflow 초기화 완료. ROLE=${ROLE}  기동=[${SERVICES}]"
echo ">> cfg=${CFG}(비밀없음)  secrets=${SECRETS_FILE}(600)"
echo ">> AIRFLOW_HOME=${AIRFLOW_HOME}  user=${AIRFLOW_USER}  DB_MODE=${DB_MODE}  executor=${AF_EXECUTOR}"
[ "${ROLE}" = "control" ] && echo ">> 워커 노드엔 동일 cluster-secrets(키/비번)·ROLE=worker 로 설치"
