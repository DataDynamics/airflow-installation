#!/usr/bin/env bash
#
# Airflow 2.11 airgap wheelhouse 빌드 (오케스트레이터: 인터넷+docker 필요)
# RHEL9 ABI / Python 3.9 호환 wheel을 ubi9/python-39 컨테이너에서 생성.
#
set -euo pipefail

AF_VERSION="${AF_VERSION:-2.11.0}"
PY_TAG="3.9"
EXTRAS="${EXTRAS:-celery,postgres,redis,common-sql,ssh,apache-kafka,sftp,ftp,hdfs,samba,pandas,uv,async,password,ldap}"
IMAGE="registry.access.redhat.com/ubi9/python-39:latest"

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
OUT="${REPO_ROOT}/artifacts"
WH="${OUT}/wheelhouse"
CONSTRAINTS_URL="https://raw.githubusercontent.com/apache/airflow/constraints-${AF_VERSION}/constraints-${PY_TAG}.txt"

mkdir -p "${WH}"
echo ">> 빌드 대상: apache-airflow[${EXTRAS}]==${AF_VERSION} (Python ${PY_TAG})"
echo ">> 산출물:    ${WH}"

docker run --rm -u 0 -v "${OUT}:/out" "${IMAGE}" bash -lc "
  set -euo pipefail
  echo '--- 컨테이너 빌드 도구 설치 (sdist 대비 안전망) ---'
  dnf -y install gcc gcc-c++ make libpq-devel python3-devel openldap-devel cyrus-sasl-devel krb5-devel >/dev/null 2>&1 || true
  python -m pip install --upgrade pip wheel setuptools >/dev/null

  echo '--- constraints 다운로드 ---'
  curl -fsSL '${CONSTRAINTS_URL}' -o /out/constraints-${PY_TAG}.txt

  echo '--- 부트스트랩 도구(pip/setuptools/wheel) 수집 (대상 오프라인 부트스트랩용) ---'
  python -m pip download -d /out/wheelhouse pip setuptools wheel

  echo '--- airflow + 의존성 전체를 wheel로 빌드/수집 ---'
  python -m pip wheel 'apache-airflow[${EXTRAS}]==${AF_VERSION}' \
    -c /out/constraints-${PY_TAG}.txt -w /out/wheelhouse
"

echo ">> wheel 개수: $(ls -1 "${WH}"/*.whl 2>/dev/null | wc -l)"
echo ">> 패키징 ---"
PKG="${OUT}/airflow-${AF_VERSION}-py${PY_TAG}-airgap.tar.gz"
tar czf "${PKG}" -C "${OUT}" wheelhouse "constraints-${PY_TAG}.txt"
( cd "${OUT}" && sha256sum "$(basename "${PKG}")" > "$(basename "${PKG}").sha256" )
echo ">> 완료: ${PKG}"
ls -lh "${PKG}"*
