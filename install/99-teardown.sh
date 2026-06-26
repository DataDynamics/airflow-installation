#!/usr/bin/env bash
# 테스트용 클린 teardown. wheelhouse(INSTALL_DIR)는 보존하여 오프라인 재설치에 재사용.
# 주의: airflow.cfg/venv/DB/계정 삭제. 실데이터 환경에서 사용 금지.
set -euo pipefail
source "$(dirname "$0")/env.sh"

echo ">> 서비스 중지/비활성"
systemctl disable --now airflow-webserver airflow-scheduler airflow-worker 2>/dev/null || true
rm -f /etc/systemd/system/airflow-{webserver,scheduler,worker}.service /etc/systemd/system/airflow.env
systemctl daemon-reload || true

if [ "${DB_MODE}" = "local" ]; then
  echo ">> 로컬 DB/롤 삭제 (DB_MODE=local)"
  if systemctl is-active --quiet postgresql; then
    sudo -u postgres psql -tAc "SELECT 1" >/dev/null 2>&1 && {
      sudo -u postgres psql -c "DROP DATABASE IF EXISTS ${PG_DB};" || true
      sudo -u postgres psql -c "DROP ROLE IF EXISTS ${PG_USER};" || true
    }
  fi
fi

echo ">> venv/AIRFLOW_HOME 삭제 (${AIRFLOW_HOME})"
rm -rf "${AIRFLOW_HOME}"

if [ "${CREATE_USER}" = "true" ]; then
  echo ">> 계정 삭제 (${AIRFLOW_USER})"
  id "${AIRFLOW_USER}" &>/dev/null && userdel "${AIRFLOW_USER}" 2>/dev/null || true
fi

echo ">> teardown 완료 (wheelhouse=${INSTALL_DIR} 보존)"
