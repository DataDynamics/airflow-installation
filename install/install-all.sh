#!/usr/bin/env bash
# 단일 진입점: 00~06 을 순서대로 실행(번들 해제 후 대상 서버 root 실행).
# 모든 토글은 env.sh 변수(환경변수로 override). 각 스크립트는 자체적으로 env.sh 를 source 함.
set -euo pipefail
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

echo; echo ">> 전체 설치 완료. UI: http://<server>:${AF_API_PORT}  health: /api/v2/monitor/health"
