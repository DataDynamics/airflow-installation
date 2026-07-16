#!/usr/bin/env bash
# OS 패키지 설치 (사내 repo에서 dnf). 대상 서버에서 root로 실행.
set -euo pipefail
source "$(dirname "$0")/env.sh"

# 공통(런타임/빌드안전망/관리) — Airflow 3.x 는 python3.11 (RHEL 9 AppStream)
PKGS=(python3.11 python3.11-pip python3.11-devel gcc gcc-c++ make
      libpq libpq-devel
      openldap cyrus-sasl-lib krb5-libs
      policycoreutils-python-utils tar gzip which procps-ng)

# 로컬 DB 모드에서만 PostgreSQL 서버 설치 (external 모드는 클라이언트 libpq 만 필요)
if [ "${DB_MODE}" = "local" ]; then
  PKGS+=(postgresql-server postgresql-contrib)
fi
# 로컬 Redis 설치 토글
if [ "${INSTALL_REDIS}" = "true" ]; then
  PKGS+=(redis)
fi

dnf -y install "${PKGS[@]}"
"${PYTHON_BIN}" --version
echo ">> OS 패키지 설치 완료 (DB_MODE=${DB_MODE}, INSTALL_REDIS=${INSTALL_REDIS})"
