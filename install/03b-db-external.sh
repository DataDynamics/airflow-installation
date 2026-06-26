#!/usr/bin/env bash
# [DB_MODE=external 전용] 사내/관리형 PostgreSQL 사용 시:
#  1) 네트워크 도달성 + 자격증명 검증
#  2) (선택) 관리자 자격증명이 있으면 airflow DB/롤을 원격에 생성
# 대상 서버 root 실행. 로컬에 postgresql-server 를 설치하지 않음(클라이언트 psql/libpq만).
set -euo pipefail
source "$(dirname "$0")/env.sh"

[ "${DB_MODE}" = "external" ] || { echo ">> DB_MODE=${DB_MODE} (external 아님) → 건너뜀"; exit 0; }

# psql 클라이언트 확보 (libpq 패키지에 포함 안되면 postgresql 클라이언트 설치)
command -v psql >/dev/null || dnf -y install postgresql >/dev/null

echo "=== 1) 호스트:포트 도달성 (${PG_HOST}:${PG_PORT}) ==="
timeout 5 bash -c "echo > /dev/tcp/${PG_HOST}/${PG_PORT}" 2>/dev/null \
  && echo "TCP reachable" \
  || { echo "ERROR: ${PG_HOST}:${PG_PORT} 도달 불가 — 라우팅/방화벽 확인 필요"; exit 1; }

# 2) (선택) 관리자 자격증명이 있으면 DB/롤을 원격에 생성. 없으면 DBA 사전 프로비저닝 가정.
if [ -n "${PG_ADMIN_USER}" ] && [ -n "${PG_ADMIN_PASSWORD}" ]; then
  echo "=== 2) 관리자 권한으로 DB/롤 생성 (idempotent) ==="
  export PGPASSWORD="${PG_ADMIN_PASSWORD}"
  ADMIN="psql -h ${PG_HOST} -p ${PG_PORT} -U ${PG_ADMIN_USER} -d postgres -v ON_ERROR_STOP=1 --set=sslmode=${PG_SSLMODE}"
  $ADMIN <<SQL
DO \$\$ BEGIN
  IF NOT EXISTS (SELECT FROM pg_roles WHERE rolname='${PG_USER}') THEN
    CREATE ROLE ${PG_USER} LOGIN PASSWORD '${PG_PASSWORD}';
  END IF;
END \$\$;
SELECT 'CREATE DATABASE ${PG_DB} OWNER ${PG_USER} ENCODING ''UTF8'''
WHERE NOT EXISTS (SELECT FROM pg_database WHERE datname='${PG_DB}')\gexec
GRANT ALL PRIVILEGES ON DATABASE ${PG_DB} TO ${PG_USER};
SQL
  unset PGPASSWORD
else
  echo "=== 2) 관리자 자격증명 미제공 → DB/롤은 DBA 사전 생성 가정(스킵) ==="
fi

echo "=== 3) airflow 사용자 자격증명으로 실제 연결 검증 ==="
PGPASSWORD="${PG_PASSWORD}" psql "host=${PG_HOST} port=${PG_PORT} dbname=${PG_DB} user=${PG_USER} sslmode=${PG_SSLMODE}" \
  -tAc "select 'connect-ok', current_user, current_database();" \
  || { echo "ERROR: airflow 자격증명 연결 실패 — DB/롤/권한/sslmode 확인"; exit 1; }

echo ">> 외부 PostgreSQL 사용 준비 완료 (${PG_HOST}:${PG_PORT}/${PG_DB}, sslmode=${PG_SSLMODE})"
