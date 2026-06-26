#!/usr/bin/env bash
#
# OS RPM 추출 — RHEL 9.4 네이티브 (docker 불필요)
# 사내 RHEL 미러에 접근 가능한 RHEL 9 빌드머신에서 직접 실행한다.
# os-packages.list + 전체 의존성을 받아 로컬 repo(artifacts/rpms)로 만든다.
# (docker 버전: extract-rpms-docker.sh)
#
set -euo pipefail

RHEL_REPO_BASE="${RHEL_REPO_BASE:-http://10.0.1.102/rhel-9.4}"
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
OUT="${REPO_ROOT}/artifacts/rpms"
PKG_LIST="${REPO_ROOT}/build/os-packages.list"
TMP_REPO="/etc/yum.repos.d/airgap-extract-mirror.repo"

mkdir -p "${OUT}"
mapfile -t PKGS < <(grep -vE '^\s*#|^\s*$' "${PKG_LIST}")
echo ">> 추출 대상(${#PKGS[@]}): ${PKGS[*]}"
echo ">> 미러: ${RHEL_REPO_BASE}  → ${OUT}"

. /etc/os-release 2>/dev/null || true
case "${PRETTY_NAME:-}" in
  *"Red Hat"*" 9."*|*Rocky*9*|*AlmaLinux*9*) : ;;
  *) echo "WARN: RHEL 9 계열이 아님 — 추출 RPM이 대상과 다를 수 있음";;
esac

SUDO=""; [ "$(id -u)" -ne 0 ] && command -v sudo >/dev/null && SUDO="sudo"

# 미러 repo 등록(추출용 임시) — 이미 사내 repo 가 있으면 그걸 써도 됨
${SUDO} tee "${TMP_REPO}" >/dev/null <<EOF
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
trap '${SUDO} rm -f "${TMP_REPO}"' EXIT

${SUDO} dnf -y install dnf-plugins-core createrepo_c >/dev/null 2>&1 || \
  echo "WARN: dnf-plugins-core/createrepo_c 설치 실패(이미 설치/권한). 계속 진행."

echo ">> RPM + 전체 의존성 다운로드(--resolve --alldeps)"
dnf download --resolve --alldeps --destdir "${OUT}" "${PKGS[@]}"
echo ">> 로컬 repo 메타데이터 생성(createrepo_c)"
createrepo_c "${OUT}" >/dev/null

echo ">> RPM 개수: $(ls -1 "${OUT}"/*.rpm 2>/dev/null | wc -l)"
echo ">> repodata: $([ -f "${OUT}/repodata/repomd.xml" ] && echo OK || echo 없음)"
du -sh "${OUT}" 2>/dev/null
echo ">> 완료. 이제 build/package.sh 가 이 로컬 repo 를 번들에 포함한다."
