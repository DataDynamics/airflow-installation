#!/usr/bin/env bash
# OS 패키지 설치 (사내 repo에서 dnf). 대상 서버에서 root로 실행.
#
# 설계 원칙:
#  - 오프라인 wheelhouse 는 psycopg2-binary(자체 libpq 내장) 등 "빌드 불필요" 휠을 담으므로
#    gcc/make/*-devel/libpq-devel 은 필수가 아니다 → best-effort(실패해도 계속).
#  - 대상 노드에 이미 다른 PostgreSQL(예: PGDG 16, libpq 16)이 설치돼 있으면 AppStream
#    libpq-devel(13.x)이 버전 충돌로 트랜잭션 전체를 실패시킨다. 이를 하드 실패시키지 않도록
#    (a) 이미 libpq.so.5 를 제공하면 libpq 설치를 건너뛰고,
#    (b) PGDG 저장소는 이 단계에서 비활성(--disablerepo='pgdg*')해 후보 간섭을 막고,
#    (c) --nobest --skip-broken + '|| true' 로 개별 충돌이 전체를 막지 않게 한다.
set -euo pipefail
source "$(dirname "$0")/env.sh"

# PGDG 저장소가 있으면 이 단계에서만 비활성(없으면 glob 이 매칭 안 돼 무해).
DISPGDG=(--disablerepo='pgdg*')

# 1) 필수 런타임 (이미 설치돼 있으면 그대로) — python3.11 + 인증/로깅 런타임 라이브러리
dnf -y install python3.11 python3.11-pip policycoreutils-python-utils tar gzip which procps-ng \
    openldap cyrus-sasl-lib krb5-libs "${DISPGDG[@]}" --nobest --skip-broken || true

# 2) libpq 런타임: 이미 libpq.so.5 를 제공하는 패키지(PGDG postgresql*-libs 등)가 있으면 설치 생략
ldconfig -p 2>/dev/null | grep -q 'libpq\.so\.5' || \
  dnf -y install libpq "${DISPGDG[@]}" --nobest --skip-broken || true

# 3) 빌드 도구/-devel: 오프라인 wheelhouse 사용 시 불필요 → best-effort(설치 실패해도 계속).
#    (소스 빌드가 필요한 특수 wheel 을 쓰는 환경 대비. 충돌 시 조용히 건너뜀)
dnf -y install gcc gcc-c++ make python3.11-devel libpq-devel "${DISPGDG[@]}" --nobest --skip-broken || true

# 4) 로컬 DB 모드에서만 PostgreSQL 서버 설치 (external 모드는 클라이언트 libpq 만 필요)
if [ "${DB_MODE}" = "local" ]; then
  dnf -y install postgresql-server postgresql-contrib --nobest --skip-broken || true
fi

# 5) 로컬 Redis 설치 토글 (Sentinel 모드 포함 — redis 패키지가 redis-sentinel 도 제공)
if [ "${INSTALL_REDIS}" = "true" ]; then
  rpm -q redis >/dev/null 2>&1 || dnf -y install redis "${DISPGDG[@]}" --nobest --skip-broken || true
fi

# 필수 인터프리터 존재는 하드 체크(없으면 이후 단계가 의미 없음)
"${PYTHON_BIN}" --version
echo ">> OS 패키지 설치 완료 (best-effort; DB_MODE=${DB_MODE}, INSTALL_REDIS=${INSTALL_REDIS})"
