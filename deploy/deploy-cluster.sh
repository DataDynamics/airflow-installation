#!/usr/bin/env bash
#
# [모드 A — 한번에 설치] SSH 가 가능한 환경에서 조정자(이 호스트)가 전 노드에 배포.
# control 먼저 설치·검증 후 워커들을 순차 설치(스키마는 control 이 소유).
#
# 사용 예:
#   CONTROL_IP=192.168.0.1 WORKER_IPS="192.168.0.2 192.168.0.3 192.168.0.4" \
#   SSH_USER=root SSH_PASS=*** \
#   ./deploy/deploy-cluster.sh
#
# 사전: build-wheelhouse-{docker,rhel}.sh 중 하나 && package.sh 로 dist/번들 생성, cluster.env 준비(없으면 자동 생성).
set -euo pipefail
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
AIRFLOW_VERSION="${AIRFLOW_VERSION:-2.11.0}"
BUNDLE="${REPO_ROOT}/dist/airflow-${AIRFLOW_VERSION}-airgap-bundle.tar.gz"
CLUSTER_ENV="${CLUSTER_ENV:-${REPO_ROOT}/dist/cluster.env}"
REMOTE_DIR="${REMOTE_DIR:-/opt/airflow-install}"

: "${CONTROL_IP:?CONTROL_IP 필요}"; : "${WORKER_IPS:?WORKER_IPS 필요(공백구분)}"
SSH_USER="${SSH_USER:-root}"
WORKER_CIDR="${WORKER_CIDR:-192.168.0.0/24}"

[ -f "${BUNDLE}" ] || { echo "ERROR: 번들 없음 ${BUNDLE} — package.sh 먼저"; exit 1; }
[ -f "${CLUSTER_ENV}" ] || "${REPO_ROOT}/install/gen-cluster-keys.sh" "${CLUSTER_ENV}" "${CONTROL_IP}" "${WORKER_CIDR}"

# SSH/SCP 래퍼 (SSH_PASS 있으면 sshpass, 없으면 키기반)
SSHO="-o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o ConnectTimeout=10"
if [ -n "${SSH_PASS:-}" ]; then export SSHPASS="${SSH_PASS}"; SSH="sshpass -e ssh ${SSHO}"; SCP="sshpass -e scp ${SSHO}"; else SSH="ssh ${SSHO}"; SCP="scp ${SSHO}"; fi

push_and_install() {  # $1=IP $2=ROLE
  local ip="$1" role="$2"
  echo "==================== ${role} @ ${ip} ===================="
  $SCP "${BUNDLE}" "${CLUSTER_ENV}" "${SSH_USER}@${ip}:/opt/"
  $SSH "${SSH_USER}@${ip}" "
    set -e
    rm -rf ${REMOTE_DIR} && mkdir -p ${REMOTE_DIR}
    tar xzf /opt/$(basename "${BUNDLE}") -C ${REMOTE_DIR} --strip-components=1
    cp -f /opt/$(basename "${CLUSTER_ENV}") ${REMOTE_DIR}/cluster.env && chmod 600 ${REMOTE_DIR}/cluster.env
    cd ${REMOTE_DIR}
    set -a; source ./cluster.env; set +a
    ROLE=${role} ./install/install-all.sh
  "
}

# 1) control 먼저
push_and_install "${CONTROL_IP}" control
echo ">> control health 대기..."
for i in $(seq 1 30); do
  c=$($SSH "${SSH_USER}@${CONTROL_IP}" "curl -s -m3 -o /dev/null -w '%{http_code}' http://127.0.0.1:8080/health" 2>/dev/null || echo 000)
  [ "$c" = 200 ] && { echo "control healthy"; break; }; sleep 3
done

# 2) 워커 순차
for w in ${WORKER_IPS}; do push_and_install "${w}" worker; done

echo ">> 클러스터 배포 완료. control=${CONTROL_IP}, workers=[${WORKER_IPS}]"
echo ">> 워커 등록 확인: control 에서 'airflow celery worker' / flower 또는 'celery -A ... inspect ping'"
