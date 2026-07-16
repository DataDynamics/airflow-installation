#!/usr/bin/env bash
#
# OS RPM 추출 — docker 기반 (ubi9/python-39 컨테이너에서 yum repo의 RPM을 다운로드)
# os-packages.list + 전체 의존성을 사내 RHEL 미러에서 받아 로컬 repo(artifacts/rpms)로 만든다.
# 산출물은 package.sh 가 번들에 포함 → target 이 미러 없이도 OS 패키지 오프라인 설치 가능.
# (RHEL 네이티브 버전: extract-rpms-rhel.sh)
#
set -euo pipefail

RHEL_REPO_BASE="${RHEL_REPO_BASE:-http://10.0.1.102/rhel-9.4}"
IMAGE="registry.access.redhat.com/ubi9/python-311:latest"
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
OUT="${REPO_ROOT}/artifacts/rpms"
PKG_LIST="${REPO_ROOT}/build/os-packages.list"

mkdir -p "${OUT}"
# 패키지 목록 로드(주석/빈 줄 제외)
mapfile -t PKGS < <(grep -vE '^\s*#|^\s*$' "${PKG_LIST}")
echo ">> 추출 대상(${#PKGS[@]}): ${PKGS[*]}"
echo ">> 미러: ${RHEL_REPO_BASE}  → ${OUT}"

docker run --rm -u 0 -v "${OUT}:/rpms" "${IMAGE}" bash -lc "
  set -euo pipefail
  cat > /etc/yum.repos.d/airgap-mirror.repo <<EOF
[m-baseos]
name=mirror BaseOS
baseurl=${RHEL_REPO_BASE}/BaseOS/
enabled=1
gpgcheck=0
[m-appstream]
name=mirror AppStream
baseurl=${RHEL_REPO_BASE}/AppStream/
enabled=1
gpgcheck=0
EOF
  dnf -y install dnf-plugins-core createrepo_c >/dev/null
  echo '--- RPM + 전체 의존성 다운로드(--resolve --alldeps) ---'
  dnf download --resolve --alldeps --destdir /rpms ${PKGS[*]}
  echo '--- 로컬 repo 메타데이터 생성(createrepo_c) ---'
  createrepo_c /rpms >/dev/null
  chown -R $(id -u):$(id -g) /rpms 2>/dev/null || true
"

echo ">> RPM 개수: $(ls -1 "${OUT}"/*.rpm 2>/dev/null | wc -l)"
echo ">> repodata: $([ -f "${OUT}/repodata/repomd.xml" ] && echo OK || echo 없음)"
du -sh "${OUT}" 2>/dev/null
echo ">> 완료. 이제 build/package.sh 가 이 로컬 repo 를 번들에 포함한다."
