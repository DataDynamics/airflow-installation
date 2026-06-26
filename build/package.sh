#!/usr/bin/env bash
#
# airgap 배포 번들 생성: wheelhouse + constraints + 설치 스크립트 + 문서를
# 단일 tar.gz 로 묶어 서버에 업로드할 수 있게 한다.
# 사전: build-wheelhouse-docker.sh 또는 -rhel.sh 로 artifacts/wheelhouse 가 생성되어 있어야 함.
#
set -euo pipefail

AIRFLOW_VERSION="${AIRFLOW_VERSION:-2.11.0}"
PY_TAG="3.9"
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
ART="${REPO_ROOT}/artifacts"
DIST="${REPO_ROOT}/dist"
STAGE="${DIST}/airflow-airgap"           # 번들 내부 최상위 디렉터리
BUNDLE="${DIST}/airflow-${AIRFLOW_VERSION}-airgap-bundle.tar.gz"

# 사전조건 검증
[ -d "${ART}/wheelhouse" ] && ls "${ART}/wheelhouse"/*.whl >/dev/null 2>&1 \
  || { echo "ERROR: ${ART}/wheelhouse 비어있음 — 먼저 build/build-wheelhouse-docker.sh(또는 -rhel.sh) 실행"; exit 1; }
[ -f "${ART}/constraints-${PY_TAG}.txt" ] \
  || { echo "ERROR: constraints-${PY_TAG}.txt 없음 — build-wheelhouse-docker.sh(또는 -rhel.sh) 실행"; exit 1; }

echo ">> 스테이징: ${STAGE}"
rm -rf "${STAGE}"; mkdir -p "${STAGE}"

# 1) 설치 스크립트 + env + 오케스트레이터
cp -a "${REPO_ROOT}/install"/. "${STAGE}/install/"
# 2) wheelhouse + constraints  (env.sh 기본 INSTALL_DIR 레이아웃과 일치하도록 최상위에 배치)
cp -a "${ART}/wheelhouse" "${STAGE}/wheelhouse"
cp -a "${ART}/constraints-${PY_TAG}.txt" "${STAGE}/"
# 3) OS RPM 로컬 repo (선택 — extract-rpms-*.sh 로 생성됐을 때만 포함)
RPMS=0
if [ -d "${ART}/rpms" ] && [ -f "${ART}/rpms/repodata/repomd.xml" ]; then
  cp -a "${ART}/rpms" "${STAGE}/rpms"
  RPMS=$(ls -1 "${STAGE}/rpms"/*.rpm 2>/dev/null | wc -l)
  echo ">> OS RPM 로컬 repo 포함: ${RPMS}개"
else
  echo ">> (OS RPM 미포함 — target 이 사내 미러로 dnf 설치. 오프라인 RPM 원하면 extract-rpms-*.sh 실행)"
fi

# 4) 참고 문서
cp -a "${REPO_ROOT}/DESIGN.md" "${STAGE}/" 2>/dev/null || true

# 5) 매니페스트
WHEELS=$(ls -1 "${STAGE}/wheelhouse"/*.whl | wc -l)
cat > "${STAGE}/MANIFEST.txt" <<EOF
Airflow airgap bundle
  airflow_version : ${AIRFLOW_VERSION}
  python_tag      : ${PY_TAG}
  wheels          : ${WHEELS}
  os_rpms         : ${RPMS}   (0이면 미포함 → target 이 사내 미러로 dnf)
  layout:
    install/                설치 스크립트(00~06, install-all.sh, env.sh, 99-teardown.sh)
    wheelhouse/             오프라인 wheel (${WHEELS}개)
    rpms/                   OS 패키지 로컬 repo (${RPMS}개, 있을 때만 / RPM_SOURCE=bundle 로 사용)
    constraints-${PY_TAG}.txt   pip constraints
    DESIGN.md               설계/런북

서버 설치(예: 기본 /opt, 로컬 DB):
  # OS 패키지를 번들 RPM(오프라인)으로 설치하려면 RPM_SOURCE=bundle 추가
  1) scp airflow-${AIRFLOW_VERSION}-airgap-bundle.tar.gz* root@<server>:/opt/
  2) ssh root@<server>
  3) mkdir -p /opt/airflow-install && tar xzf /opt/airflow-${AIRFLOW_VERSION}-airgap-bundle.tar.gz \\
       -C /opt/airflow-install --strip-components=1
  4) cd /opt/airflow-install
     PG_PASSWORD=*** AF_ADMIN_PASSWORD=*** ./install/install-all.sh
  # 변수 조합 예) INSTALL_ROOT=/app  AIRFLOW_USER=svc  CREATE_USER=false  DB_MODE=external ...
EOF

# 5) 패키징 + 체크섬
mkdir -p "${DIST}"
tar czf "${BUNDLE}" -C "${DIST}" "$(basename "${STAGE}")"
( cd "${DIST}" && sha256sum "$(basename "${BUNDLE}")" > "$(basename "${BUNDLE}").sha256" )

echo ">> 완료"
ls -lh "${BUNDLE}"*
echo "----- 번들 내부(요약) -----"
tar tzf "${BUNDLE}" | sed 's#^#  #' | grep -vE '/(wheelhouse/.+\.whl|rpms/.+\.rpm)$' | head -40
echo "  (+ wheelhouse/*.whl ${WHEELS}개, rpms/*.rpm ${RPMS}개)"
