#!/usr/bin/env bash
# 공유 비밀을 난수로 1회 생성해 group_vars/all/vault.yml 로 암호화 저장한다.
# 이미 파일이 있으면 덮어쓰지 않는다(키가 바뀌면 기존 암호 Connection 이 깨짐).
set -euo pipefail
HERE="$(cd "$(dirname "$0")/.." && pwd)"
OUT="${HERE}/group_vars/all/vault.yml"
PASS_FILE="${HERE}/.vault_pass"

[ -f "${OUT}" ] && { echo "이미 존재: ${OUT} — 덮어쓰지 않음"; exit 0; }

if [ ! -f "${PASS_FILE}" ]; then
  ( umask 077; openssl rand -base64 32 > "${PASS_FILE}" )
  echo ">> vault 암호 생성: ${PASS_FILE} (600) — 이 파일을 안전하게 백업하세요"
fi

# Fernet 키는 32바이트 urlsafe base64. 비밀번호는 URL 파서 안전을 위해 특수문자 제외.
FERNET="$(head -c32 /dev/urandom | base64 | tr '+/' '-_')"
rand_pw() { openssl rand -base64 24 | tr -d '/+=' | cut -c1-20; }

( umask 077
cat > "${OUT}" <<EOF
---
vault_fernet_key: "${FERNET}"
vault_api_secret_key: "$(openssl rand -hex 32)"
vault_jwt_secret: "$(openssl rand -hex 32)"
vault_db_password: "$(rand_pw)"
vault_redis_password: "$(rand_pw)"
vault_admin_password: "$(rand_pw)"
# airflow_db_backend=external + airflow_db_bootstrap=true 일 때만 필요하다.
# (외부 DB 에 롤/DB 를 만들 관리 계정의 비밀번호 — 그 DB 의 실제 값으로 채울 것)
vault_db_admin_password: ""
EOF
)

# ansible.cfg 의 vault_password_file 과 --vault-password-file 이 둘 다 'default' id 라
# 모호해진다. --encrypt-vault-id 로 명시한다.
ansible-vault encrypt \
  --vault-id "default@${PASS_FILE}" --encrypt-vault-id default "${OUT}"
echo ">> 생성·암호화 완료: ${OUT}"
echo ">> 확인: ansible-vault view ${OUT}"
