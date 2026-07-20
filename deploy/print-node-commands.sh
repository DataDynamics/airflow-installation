#!/usr/bin/env bash
#
# [모드 B — 각 서버 직접 설치] SSH 원격실행이 불가한 환경용.
# 각 노드에 들어가서 복붙할 '명령 시트'를 출력한다. (실행하지 않고 안내만)
# 사용: CONTROL_IP=192.168.0.1 WORKER_IPS="192.168.0.2 192.168.0.3 192.168.0.4" ./deploy/print-node-commands.sh
set -euo pipefail
AIRFLOW_VERSION="${AIRFLOW_VERSION:-2.11.0}"
BUNDLE="airflow-${AIRFLOW_VERSION}-airgap-bundle.tar.gz"
CONTROL_IP="${CONTROL_IP:-192.168.0.1}"
WORKER_IPS="${WORKER_IPS:-192.168.0.2 192.168.0.3 192.168.0.4}"
DIR=/opt/airflow-install

cat <<EOF
================================================================
 모드 B: 각 서버 직접 설치 (SSH 원격실행 불가 환경)
 - root 로그인 불필요: sudo 권한 계정으로 아래 명령을 그대로 실행
   (install-all.sh 는 root가 아니면 sudo 자동 승격도 지원)
================================================================
[0] 준비(조정자/안전한 곳에서 1회): 클러스터 공통 구성 생성
    ./install/gen-cluster-keys.sh ./cluster.env ${CONTROL_IP} ${WORKER_IPS%% *}/24 의 CIDR
    → cluster.env 와 ${BUNDLE} 두 파일을 '승인된 매체'로 각 노드에 복사.
    ※ cluster.env 는 모든 노드에 '동일'해야 함(키 불일치 시 워커 미동작).

[공통] 각 노드에서 번들 해제:
    sudo mkdir -p ${DIR}
    sudo tar xzf /path/${BUNDLE} -C ${DIR} --strip-components=1
    sudo cp /path/cluster.env ${DIR}/cluster.env && sudo chmod 600 ${DIR}/cluster.env
    cd ${DIR}

----------------------------------------------------------------
[1] CONTROL 노드 = web (${CONTROL_IP})  ← 반드시 '먼저' 설치
----------------------------------------------------------------
    sudo bash -c 'set -a; source ./cluster.env; set +a; ROLE=control ./install/install-all.sh'
    # 확인:
    curl -s http://127.0.0.1:8080/health; echo
    # webserver+scheduler+PostgreSQL(메타DB)+Redis(브로커) 가 이 노드에 구성됨
EOF

i=1
for w in ${WORKER_IPS}; do
cat <<EOF

----------------------------------------------------------------
[$((i+1))] CELERY 워커 노드 #${i} (${w})  ← control 설치/검증 '후' 진행
----------------------------------------------------------------
    sudo bash -c 'set -a; source ./cluster.env; set +a; ROLE=worker ./install/install-all.sh'
    # 확인(워커 서비스):
    systemctl is-active airflow-worker
EOF
  i=$((i+1))
done

cat <<EOF

----------------------------------------------------------------
[검증] CONTROL 노드에서 워커 등록 확인:
    sudo -u ${AIRFLOW_USER:-airflow} bash -c 'set -a; source /opt/airflow/airflow-secrets.env; set +a; \\
      AIRFLOW_HOME=/opt/airflow /opt/airflow/venv/bin/celery -A airflow.providers.celery.executors.celery_executor.app inspect ping'
    # 3개 워커가 pong 응답하면 정상. (또는 ENABLE_FLOWER=true 로 flower :5555)
================================================================
EOF
