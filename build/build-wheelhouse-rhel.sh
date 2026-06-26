#!/usr/bin/env bash
#
# Airflow 2.11 airgap wheelhouse 빌드 — RHEL 9.4 네이티브 (docker 불필요)
# 인터넷이 되는 RHEL 9.4 빌드머신에서 시스템 Python 3.9 로 직접 빌드한다.
# 대상과 동일 OS/Python ABI 라 가장 정합. (docker 버전: build-wheelhouse-docker.sh)
#
set -euo pipefail

AF_VERSION="${AF_VERSION:-2.11.0}"
PY_TAG="3.9"
EXTRAS="${EXTRAS:-celery,postgres,redis,common-sql,ssh,apache-kafka,sftp,ftp,hdfs,samba,pandas,uv,async,password,ldap}"

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
OUT="${REPO_ROOT}/artifacts"
WH="${OUT}/wheelhouse"
BUILD_VENV="${OUT}/.buildvenv"
CONSTRAINTS_URL="https://raw.githubusercontent.com/apache/airflow/constraints-${AF_VERSION}/constraints-${PY_TAG}.txt"

mkdir -p "${WH}"
trap 'rm -rf "${BUILD_VENV}"' EXIT

# 0) 환경 점검 (경고만, 강제 중단 X)
. /etc/os-release 2>/dev/null || true
echo ">> host: ${PRETTY_NAME:-unknown} / $(uname -m)"
case "${PRETTY_NAME:-}" in
  *"Red Hat"*" 9."*|*Rocky*9*|*AlmaLinux*9*) : ;;
  *) echo "WARN: RHEL 9 계열이 아님 — 대상(RHEL 9.4)과 wheel ABI 불일치 가능";;
esac
PYV="$(python3 -c 'import sys;print("%d.%d"%sys.version_info[:2])')"
[ "${PYV}" = "${PY_TAG}" ] || echo "WARN: 시스템 python3=${PYV} (대상 ${PY_TAG}와 다름) — 호환성 주의"

# 1) 빌드 도구 (dnf 사용 가능할 때만; 실패해도 진행 — 대부분 manylinux wheel 사용)
SUDO=""; [ "$(id -u)" -ne 0 ] && command -v sudo >/dev/null && SUDO="sudo"
if command -v dnf >/dev/null; then
  ${SUDO} dnf -y install gcc gcc-c++ make libpq-devel python3-devel python3-pip openldap-devel cyrus-sasl-devel krb5-devel >/dev/null 2>&1 \
    || echo "WARN: 빌드 패키지 설치 실패(이미 설치/repo 미구성). 계속 진행."
fi

# 2) 격리된 빌드 venv (시스템 오염 방지)
python3 -m venv "${BUILD_VENV}"
PIP="${BUILD_VENV}/bin/pip"
"${PIP}" install --upgrade pip wheel setuptools >/dev/null

# 3) constraints
echo ">> constraints 다운로드"
curl -fsSL "${CONSTRAINTS_URL}" -o "${OUT}/constraints-${PY_TAG}.txt"

# 4) 부트스트랩 도구 + airflow 전체를 wheel 로 빌드/수집
echo ">> 부트스트랩(pip/setuptools/wheel) 수집"
"${PIP}" download -d "${WH}" pip setuptools wheel
echo ">> airflow + 의존성 wheel 빌드: apache-airflow[${EXTRAS}]==${AF_VERSION}"
"${PIP}" wheel "apache-airflow[${EXTRAS}]==${AF_VERSION}" \
  -c "${OUT}/constraints-${PY_TAG}.txt" -w "${WH}"

echo ">> wheel 개수: $(ls -1 "${WH}"/*.whl 2>/dev/null | wc -l)"

# 5) 패키징(보조 산출물) — docker 버전과 동일 형식
PKG="${OUT}/airflow-${AF_VERSION}-py${PY_TAG}-airgap.tar.gz"
tar czf "${PKG}" -C "${OUT}" wheelhouse "constraints-${PY_TAG}.txt"
( cd "${OUT}" && sha256sum "$(basename "${PKG}")" > "$(basename "${PKG}").sha256" )
echo ">> 완료: ${PKG}"
ls -lh "${PKG}"*
