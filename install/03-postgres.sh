#!/usr/bin/env bash
# [DB_MODE=local 전용] PostgreSQL 초기화 + airflow DB/롤 생성. 대상 서버 root 실행.
# 외부 제공 PostgreSQL(DB_MODE=external)은 이 스크립트를 건너뛰고 03b-db-external.sh 사용.
set -euo pipefail
source "$(dirname "$0")/env.sh"

if [ "${DB_MODE}" != "local" ]; then
  echo ">> DB_MODE=${DB_MODE} → 로컬 PostgreSQL 구성 건너뜀. 03b-db-external.sh 를 사용하세요."
  exit 0
fi

# 기본 data dir 초기화 (SELinux 컨텍스트 정합). 이미 초기화면 건너뜀.
if [ ! -f /var/lib/pgsql/data/PG_VERSION ]; then
  postgresql-setup --initdb
fi
systemctl enable --now postgresql

# 롤/DB 생성 (idempotent)
sudo -u postgres psql -v ON_ERROR_STOP=1 <<SQL
DO \$\$ BEGIN
  IF NOT EXISTS (SELECT FROM pg_roles WHERE rolname='${PG_USER}') THEN
    CREATE ROLE ${PG_USER} LOGIN PASSWORD '${PG_PASSWORD}';
  END IF;
END \$\$;
SELECT 'CREATE DATABASE ${PG_DB} OWNER ${PG_USER} ENCODING ''UTF8'''
WHERE NOT EXISTS (SELECT FROM pg_database WHERE datname='${PG_DB}')\gexec
GRANT ALL PRIVILEGES ON DATABASE ${PG_DB} TO ${PG_USER};
SQL

# 로컬 TCP 인증을 md5로. RHEL 기본은 127.0.0.1/::1 가 ident 라서
# 끝에 규칙을 추가해도 ident 가 먼저 매칭됨 → 기존 localhost 라인을 md5로 교체.
PGHBA=/var/lib/pgsql/data/pg_hba.conf
PGCONF=/var/lib/pgsql/data/postgresql.conf
sed -ri "s#^(host\s+all\s+all\s+127\.0\.0\.1/32\s+)(ident|peer)#\1md5#" "${PGHBA}"
sed -ri "s#^(host\s+all\s+all\s+::1/128\s+)(ident|peer)#\1md5#" "${PGHBA}"

# --- Phase2: 워커 원격 접속 개방(값이 있을 때만; 비우면 Phase1 localhost 전용) ---
if [ -n "${PG_LISTEN_ADDRESSES}" ]; then
  if grep -qE "^[#\s]*listen_addresses" "${PGCONF}"; then
    sed -ri "s#^[#\s]*listen_addresses\s*=.*#listen_addresses = '${PG_LISTEN_ADDRESSES}'#" "${PGCONF}"
  else
    echo "listen_addresses = '${PG_LISTEN_ADDRESSES}'" >> "${PGCONF}"
  fi
  echo ">> listen_addresses = '${PG_LISTEN_ADDRESSES}'"
fi
if [ -n "${PG_ALLOW_CIDR}" ]; then
  # md5 사용(기존 롤 해시·RHEL13 기본과 정합). scram 원하면 password_encryption=scram-sha-256 후 롤 재생성.
  HBALINE="host    ${PG_DB}    ${PG_USER}    ${PG_ALLOW_CIDR}    md5"
  grep -qF "${PG_ALLOW_CIDR}" "${PGHBA}" || echo "${HBALINE}" >> "${PGHBA}"
  echo ">> pg_hba 워커 허용: ${PG_ALLOW_CIDR}"
fi
# listen_addresses 변경은 reload 로 부족 → 변경 시 restart
if [ -n "${PG_LISTEN_ADDRESSES}" ]; then systemctl restart postgresql; else systemctl reload postgresql; fi

# --- Phase2: 방화벽 5432 개방(control) ---
if [ "${OPEN_FIREWALL}" = "true" ] && systemctl is-active --quiet firewalld; then
  firewall-cmd --permanent --add-port=5432/tcp >/dev/null && firewall-cmd --reload >/dev/null
  echo ">> firewalld: 5432/tcp 개방"
fi

PGPASSWORD="${PG_PASSWORD}" "${VENV}/bin/python" - <<PY 2>/dev/null || \
  echo "(연결 테스트는 airflow 설치 후 db check로 수행)"
import psycopg2; psycopg2.connect(host="${PG_HOST}",port=${PG_PORT},dbname="${PG_DB}",user="${PG_USER}",password="${PG_PASSWORD}").close(); print(">> PostgreSQL 연결 OK")
PY
echo ">> PostgreSQL 준비 완료"
