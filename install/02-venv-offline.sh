#!/usr/bin/env bash
# 서비스 계정/디렉터리 생성 + venv + wheelhouse 오프라인 설치. 대상 서버 root 실행.
set -euo pipefail
source "$(dirname "$0")/env.sh"

# 산출물 존재 확인
[ -d "${WHEELHOUSE}" ] || { echo "ERROR: ${WHEELHOUSE} 없음. 패키지 전송/해제 먼저"; exit 1; }
[ -f "${CONSTRAINTS}" ] || { echo "ERROR: ${CONSTRAINTS} 없음"; exit 1; }

# 그룹/계정 (CREATE_USER=false면 조직 제공 계정 그대로 사용, 생성 안 함)
if [ "${CREATE_USER}" = "true" ]; then
  getent group "${AIRFLOW_GROUP}" >/dev/null || groupadd --system "${AIRFLOW_GROUP}"
  id "${AIRFLOW_USER}" &>/dev/null || \
    useradd --system --gid "${AIRFLOW_GROUP}" --home-dir "${AIRFLOW_HOME}" \
            --shell /sbin/nologin "${AIRFLOW_USER}"
else
  id "${AIRFLOW_USER}" &>/dev/null || { echo "ERROR: 계정 ${AIRFLOW_USER} 없음(CREATE_USER=false)"; exit 1; }
fi

# 디렉터리 (AIRFLOW_HOME 은 계정 home 과 독립적으로 위치 가능: 예) /app/airflow)
mkdir -p "${AIRFLOW_HOME}"/{dags,logs,plugins}
chown -R "${AIRFLOW_USER}:${AIRFLOW_GROUP}" "${AIRFLOW_HOME}"

# venv (python3.11 기반 — Airflow 3.x 최소 요구)
[ -x "${PYTHON_BIN}" ] || { echo "ERROR: ${PYTHON_BIN} 없음 — 01-os-packages.sh 선행 필요"; exit 1; }
sudo -u "${AIRFLOW_USER}" "${PYTHON_BIN}" -m venv "${VENV}"

# 부트스트랩 (오프라인)
sudo -u "${AIRFLOW_USER}" "${VENV}/bin/pip" install \
  --no-index --find-links "${WHEELHOUSE}" --upgrade pip setuptools wheel

# airflow 본체 (오프라인 + constraints)
sudo -u "${AIRFLOW_USER}" "${VENV}/bin/pip" install \
  --no-index --find-links "${WHEELHOUSE}" \
  -c "${CONSTRAINTS}" \
  "apache-airflow[${EXTRAS}]==${AIRFLOW_VERSION}"

"${VENV}/bin/airflow" version
echo ">> Airflow venv 오프라인 설치 완료 (${AIRFLOW_HOME}, user=${AIRFLOW_USER})"
