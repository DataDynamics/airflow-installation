#!/usr/bin/env bash
# dnf repo 등록. 대상 서버에서 root로 실행.
#  RPM_SOURCE=mirror : RHEL 사내 미러(BaseOS/AppStream) 등록 (기본)
#  RPM_SOURCE=bundle : 번들에 포함된 로컬 repo(${LOCAL_RPM_DIR}) 만 등록(미러 불필요, 완전 오프라인)
#  RPM_SOURCE=system : 대상 서버에 이미 구성된 repo(DVD ISO 등) 그대로 사용 — 등록 생략
set -euo pipefail
source "$(dirname "$0")/env.sh"

if [ "${RPM_SOURCE}" = "system" ]; then
  echo ">> RPM_SOURCE=system → repo 등록 생략(기존 dnf 구성 사용)"
  dnf repolist
  exit 0
fi

if [ "${RPM_SOURCE}" = "bundle" ]; then
  [ -f "${LOCAL_RPM_DIR}/repodata/repomd.xml" ] || {
    echo "ERROR: 번들 로컬 repo 없음 (${LOCAL_RPM_DIR}/repodata). extract-rpms-*.sh 로 RPM을 포함해 패키징했는지 확인"; exit 1; }
  cat > /etc/yum.repos.d/airflow-airgap.repo <<EOF
[airflow-airgap-local]
name=Airflow airgap local RPMs
baseurl=file://${LOCAL_RPM_DIR}
enabled=1
gpgcheck=0
EOF
  # 미러 충돌 방지: 사내 미러 repo가 있으면 비활성(있을 때만)
  [ -f /etc/yum.repos.d/local-rhel94.repo ] && sed -i 's/^enabled=1/enabled=0/' /etc/yum.repos.d/local-rhel94.repo || true
  echo ">> 번들 로컬 repo 등록: ${LOCAL_RPM_DIR}"
else
  cat > /etc/yum.repos.d/local-rhel94.repo <<EOF
[local-baseos]
name=RHEL 9.4 BaseOS (local)
baseurl=${RHEL_REPO_BASE}/BaseOS/
enabled=1
gpgcheck=0

[local-appstream]
name=RHEL 9.4 AppStream (local)
baseurl=${RHEL_REPO_BASE}/AppStream/
enabled=1
gpgcheck=0
EOF
  echo ">> 사내 미러 repo 등록: ${RHEL_REPO_BASE}"
fi

dnf clean all
dnf repolist
dnf makecache
echo ">> repo 등록 완료 (RPM_SOURCE=${RPM_SOURCE})"
