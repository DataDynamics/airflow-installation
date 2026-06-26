#!/usr/bin/env bash
# RHEL 9.4 사내 repo(BaseOS/AppStream) 등록. 대상 서버에서 root로 실행.
set -euo pipefail
source "$(dirname "$0")/env.sh"

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

dnf clean all
dnf repolist
dnf makecache
echo ">> repo 등록 완료"
