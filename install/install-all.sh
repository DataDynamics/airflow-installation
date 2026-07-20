#!/usr/bin/env bash
# 단일 진입점: 00~06 을 순서대로 실행(번들 해제 후 대상 서버에서 실행).
# root 로그인이 불가한 환경 지원: sudo 권한 계정으로 실행하면 자동으로 sudo 승격한다.
# 모든 토글은 env.sh 변수(환경변수로 override). 각 스크립트는 자체적으로 env.sh 를 source 함.
set -euo pipefail

# --- sudo 자동 승격 (root가 아닐 때) -----------------------------------------
# PG_PASSWORD=*** ROLE=worker ./install-all.sh 처럼 일반 계정이 실행해도 동작.
# 설정 변수는 'sudo VAR=val'(기본 sudoers에서 SETENV 거부됨)이 아니라
# root 셸 내부의 export 문으로 안전하게(%q) 릴레이한다.
if [ "$(id -u)" -ne 0 ]; then
  command -v sudo >/dev/null || { echo "ERROR: root가 아니며 sudo도 없음 — root 또는 sudo 계정 필요"; exit 1; }
  echo ">> root가 아니므로 sudo로 재실행합니다(암호를 물을 수 있음)"
  EXPORTS=""
  # 접두사군(AF_*, PG_* 등)과 정확일치군(ROLE 등)을 구분해 수집
  for k in $(env | grep -E '^(AF_|PG_|REDIS_|INSTALL_|AIRFLOW_)[A-Za-z_0-9]*=|^(ROLE|CREATE_USER|MANAGE_SELINUX|RPM_SOURCE|RHEL_REPO_BASE|LOCAL_RPM_DIR|DB_MODE|CONTROL_IP|OPEN_FIREWALL|ENABLE_FLOWER|VENV|PYTHON_BIN|PY_TAG|EXTRAS)=' | cut -d= -f1 | sort -u); do
    EXPORTS+="export $(printf '%q=%q' "$k" "${!k}"); "
  done
  exec sudo bash -c "${EXPORTS} exec \"\$0\" \"\$@\"" "$0" "$@"
fi
# -----------------------------------------------------------------------------

HERE="$(cd "$(dirname "$0")" && pwd)"
source "${HERE}/env.sh"

step() { echo; echo "######## $* ########"; }

echo ">> ROLE=${ROLE}  executor=${AF_EXECUTOR}  CONTROL_IP=${CONTROL_IP}"
echo ">> AIRFLOW_HOME=${AIRFLOW_HOME}  user=${AIRFLOW_USER}  DB_MODE=${DB_MODE}  INSTALL_REDIS=${INSTALL_REDIS}"
if [ "${ROLE}" = "worker" ]; then
  echo ">> (worker) 로컬 DB/Redis 미설치, control(${CONTROL_IP}) 원격 접속. control 선행 설치 필요."
fi

step "00 RHEL repo 등록";        "${HERE}/00-repo.sh"
step "01 OS 패키지";             "${HERE}/01-os-packages.sh"
step "06 SELinux 레이블";        "${HERE}/06-selinux.sh"
step "02 venv 오프라인 설치";    "${HERE}/02-venv-offline.sh"

if [ "${DB_MODE}" = "local" ]; then
  step "03 PostgreSQL(local)";   "${HERE}/03-postgres.sh"
else
  step "03b PostgreSQL(external)"; "${HERE}/03b-db-external.sh"
fi

step "04 Redis";                 "${HERE}/04-redis.sh"
step "05 Airflow 초기화";        "${HERE}/05-airflow-init.sh"

echo; echo ">> 전체 설치 완료. http://<server>:8080"
