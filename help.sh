#!/usr/bin/env bash
#
# 이 저장소 사용법 출력기. 아무것도 실행하지 않고 명령만 보여준다.
#
#   ./help.sh              # 전체
#   ./help.sh ha           # Ansible HA 배포 (3노드 · Patroni 위)
#   ./help.sh info         # 접속 정보 확인
#   ./help.sh test         # 테스트 / 검증
#   ./help.sh build        # 빌드·패키징 (인터넷 빌드머신)
#   ./help.sh single       # 단일 노드 / Celery 수동 설치 (구 Phase 1·2)
#   ./help.sh teardown     # 재테스트용 제거
#   ./help.sh vars         # 자주 바꾸는 변수
set -euo pipefail

if [[ -t 1 && -z "${NO_COLOR:-}" ]]; then
  B=$'\033[1m'; C=$'\033[36m'; Y=$'\033[33m'; R=$'\033[0m'
else
  B=''; C=''; Y=''; R=''
fi

h() { printf '\n%s%s%s\n' "$B$C" "$1" "$R"; }
note() { printf '%s%s%s\n' "$Y" "$1" "$R"; }

topic_ha() {
  h "■ Ansible HA 배포 — 3노드 대칭 (기존 Patroni PostgreSQL 클러스터 위)"
  cat <<'EOF'
  작업 디렉터리는 항상 ansible/ 이다 (ansible.cfg 가 인벤토리·vault 경로를 잡는다).

    cd ansible

  준비 (최초 1회)
    ansible-galaxy collection install -r requirements.yml   # 컬렉션
    ./scripts/gen-vault.sh                                  # 비밀 생성 → group_vars/all/vault.yml + .vault_pass
    vi inventory/hosts.yml                                   # 노드 IP · redis_initial_role
    ls ../dist/airflow-3.3.0-airgap-bundle.tar.gz            # airgap 번들 (없으면 ./help.sh build)

  배포
    ansible all -m ping                        # 연결 확인
    ansible-playbook site.yml --tags always    # 사전 검증만 (읽기 전용)
    ansible-playbook site.yml                  # 전체 배포
    ansible-playbook site.yml --check --diff   # 드라이런

  부분 실행
    ansible-playbook site.yml --tags dags      # DAG 만 재배포
    ansible-playbook site.yml --tags config    # 설정만 갱신
    ansible-playbook site.yml --tags services  # 롤링 재시작 (serial:1 + health 게이트)
    ansible-playbook site.yml --limit pg-node-2

  운영
    ansible-playbook playbooks/cluster-status.yml         # 상태 요약 (무변경)
    ansible-playbook playbooks/deploy-dags.yml            # DAG 만 rsync
    ansible-playbook playbooks/rolling-restart.yml        # 강제 롤링 재시작
    ansible-playbook playbooks/reset-admin-password.yml   # 관리자 비밀번호를 vault 값으로 재설정
EOF
  note "  ⚠ .vault_pass 를 잃으면 비밀값을 복구할 수 없다. 저장소 밖에 따로 보관할 것."
}

topic_info() {
  h "■ 접속 정보 — 어디로 붙는지 한 장으로"
  cat <<'EOF'
    cd ansible
    ansible-playbook playbooks/connection-info.yml                     # 비밀번호는 가림
    ansible-playbook playbooks/connection-info.yml -e show_secrets=true # 비밀번호까지 표시

  출력 내용
    · 웹 UI 주소 · 관리자 계정 · 현재 VIP 보유 노드 · 노드 직결 URL
    · REST API 호출 예시 (health · JWT 토큰 발급 · DAG 목록)
    · 메타DB DSN/psql 명령 + 현재 Patroni Leader
    · Redis Sentinel 목록 + 현재 master
    · 노드별 서비스 상태 · SSH/CLI/journalctl · 주요 경로

  손으로 확인할 때
    curl -s http://<VIP>:8081/api/v2/monitor/health
    ansible-playbook playbooks/cluster-status.yml
EOF
  note "  ⚠ show_secrets=true 는 vault 비밀번호를 화면에 그대로 찍는다 — 화면 공유 중에는 쓰지 말 것."
}

topic_test() {
  h "■ 테스트 — 배포된 클러스터가 실제로 동작하는지"
  cat <<'EOF'
    cd ansible
    ansible-playbook playbooks/smoke-test.yml                        # 전체 (DAG 실행 포함)
    ansible-playbook playbooks/smoke-test.yml -e smoke_run_dag=false # 읽기 전용 항목만
    ansible-playbook playbooks/smoke-test.yml -e smoke_dag=ha_failover_test

  검사 항목
    [노드]    T1 systemd 5서비스 · T2 api-server health(4컴포넌트) · T3 메타DB 접속
              T4 워커 로그서버 포트 · T5 Sentinel 응답
    [클러스터] T6 UI 진입점 · T7 로그인(JWT 발급) · T8 인증 REST 호출
              T9 DAG 임포트 오류 · T10 Celery 워커 등록 수 · T11 Sentinel master 합의
              T12 DAG 실행 E2E (성공률 + 워커 분산)
    실패해도 중간에 멈추지 않는다 — 전 항목을 돌린 뒤 PASS/FAIL 표를 내고 마지막에 실패시킨다.

  HA 장애 주입 (수동)
    ansible-playbook playbooks/deploy-dags.yml         # ha_failover_test 배포 (24태스크 × 25초)
    airflow dags trigger ha_failover_test              # 실행 중에 아래를 주입
      patronictl -c /etc/patroni/patroni.yml switchover      # 메타DB 페일오버
      systemctl stop redis                                   # 브로커 master 정지
      systemctl stop 'airflow-*'                             # 노드 1대 정지
    ansible-playbook playbooks/smoke-test.yml -e smoke_run_dag=false   # 회복 확인
EOF
  note "  ⚠ smoke_run_dag=true(기본)는 DAG 를 unpause 하고 실제로 한 번 돌린다(메타DB 에 런이 남는다)."
}

topic_build() {
  h "■ 빌드·패키징 — 인터넷 되는 빌드머신에서"
  cat <<'EOF'
    ./build/build-wheelhouse-docker.sh   # wheelhouse 생성 (docker, ubi9/python-311)
    ./build/build-wheelhouse-rhel.sh     #   또는 RHEL 9 네이티브 (docker 불필요)
    ./build/extract-rpms-docker.sh       # (선택) OS RPM 추출 — 완전 오프라인 설치용
    ./build/package.sh                   # dist/airflow-3.3.0-airgap-bundle.tar.gz 생성

  만들어진 번들을 승인된 매체로 airgap 망에 옮긴 뒤 ./help.sh ha 또는 ./help.sh single 로 진행.
EOF
}

topic_single() {
  h "■ 단일 노드 / Celery 수동 설치 (구 Phase 1·2 — bash 경로)"
  cat <<'EOF'
  단일 노드 (LocalExecutor)
    mkdir -p /opt/airflow-install
    tar xzf airflow-3.3.0-airgap-bundle.tar.gz -C /opt/airflow-install --strip-components=1
    cd /opt/airflow-install
    PG_PASSWORD=*** AF_ADMIN_PASSWORD=*** ./install/install-all.sh
    #  OS 패키지 소스: RPM_SOURCE=mirror(기본) | bundle | system
    curl http://127.0.0.1:8080/api/v2/monitor/health

  Celery 다중 노드 (1 control + N worker)
    ./install/gen-cluster-keys.sh ./cluster.env 192.168.0.1 192.168.0.0/24   # 공유 키 1회
    # 모드 A — SSH 가능
    CONTROL_IP=192.168.0.1 WORKER_IPS="192.168.0.2 192.168.0.3" \
      SSH_USER=root SSH_PASS=*** ./deploy/deploy-cluster.sh
    # 모드 B — SSH 불가: 각 노드에 복붙할 명령 시트 출력
    CONTROL_IP=192.168.0.1 WORKER_IPS="192.168.0.2 192.168.0.3" \
      ./deploy/print-node-commands.sh
EOF
  note "  3노드 HA(Patroni 위)를 쓸 거면 이 경로 대신 ./help.sh ha 를 볼 것."
}

topic_teardown() {
  h "■ teardown — 재테스트를 위해 지운다"
  cat <<'EOF'
    cd ansible
    # ① Airflow 만 제거 (Patroni 클러스터는 건드리지 않음)
    ansible-playbook playbooks/teardown.yml -e teardown_confirm=yes
    # ② Airflow + 패키지까지
    ansible-playbook playbooks/teardown.yml -e teardown_confirm=yes -e teardown_remove_packages=true
    # ③ 랩 완전 초기화 — Patroni/etcd/pgbouncer/keepalived 까지
    ansible-playbook playbooks/teardown.yml -e teardown_confirm=yes \
      -e teardown_remove_packages=true -e teardown_include_patroni=true

  단일 노드 설치본: ./install/99-teardown.sh
EOF
  note "  ⚠ 되돌릴 수 없다. 메타DB 스키마·DAG·로그·설정이 사라진다(확인 변수 없이는 아무것도 하지 않음)."
}

topic_vars() {
  h "■ 자주 바꾸는 변수 (ansible/group_vars/all/main.yml · -e 로 덮어쓰기 가능)"
  cat <<'EOF'
    airflow_cluster_vip        VIP (Keepalived, Patroni 프로젝트 소유)          기본 192.168.122.100
    airflow_lb_ui_enabled      UI 로드밸런서(:8080) 켜기                         기본 false
    airflow_db_proxy_enabled   메타DB RW 프록시(127.0.0.1:5433) — 끄면 접속 불가  기본 true
    airflow_base_url           운영자 진입 주소(실제 접속 주소와 달라지면 UI 링크가 깨진다)
    airflow_api_port / 8081    api-server (8080 은 LB 가 점유)
    airflow_worker_concurrency 워커 동시 실행 수                                 기본 4
    airflow_dags_src           배포할 DAG 원본 경로                              기본 ../dags/
    airflow_load_examples      예제 DAG                                          기본 false

    ansible-playbook site.yml -e airflow_lb_ui_enabled=true
    ansible-playbook playbooks/deploy-dags.yml -e airflow_dags_src=/path/to/dags/

  비밀값은 group_vars/all/vault.yml (ansible-vault):
    vault_fernet_key · vault_api_secret_key · vault_jwt_secret
    vault_db_password · vault_redis_password · vault_admin_password
    ansible-vault edit group_vars/all/vault.yml
EOF
}

topic_docs() {
  h "■ 문서"
  cat <<'EOF'
    README.md                      저장소 개요 · 빌드/설치 파이프라인
    AIRFLOW-HA-ANSIBLE-DESIGN.md   3노드 HA 설계서 (판단 근거 · 함정 · 해결 기록)
    ansible/README.md              Ansible 사용법 · 포트 배치 · HA 검증 결과
    DESIGN.md / VERIFICATION.md    단일·Celery 경로 설계서 / 검증 결과
EOF
}

usage() {
  printf '%s\n' "${B}Apache Airflow airgap 설치 저장소 — 사용법${R}"
  cat <<'EOF'

  ./help.sh [주제]

    (없음)     전체 출력
    ha         Ansible HA 배포 (3노드 · Patroni 위)   ← 기본 경로
    info       접속 정보 출력
    test       테스트 / 검증
    build      빌드·패키징 (인터넷 빌드머신)
    single     단일 노드 / Celery 수동 설치 (bash 경로)
    teardown   재테스트용 제거
    vars       자주 바꾸는 변수
    docs       문서 목록
EOF
}

main() {
  case "${1:-all}" in
    ha|deploy)        topic_ha ;;
    info|conn|접속)   topic_info ;;
    test|smoke|검증)  topic_test ;;
    build|package)    topic_build ;;
    single|phase1|phase2|legacy) topic_single ;;
    teardown|clean)   topic_teardown ;;
    vars|var|config)  topic_vars ;;
    docs|doc)         topic_docs ;;
    all)
      usage
      topic_ha; topic_info; topic_test; topic_build; topic_single
      topic_teardown; topic_vars; topic_docs
      ;;
    -h|--help|help)   usage ;;
    *)
      printf '알 수 없는 주제: %s\n' "$1" >&2
      usage >&2
      exit 1
      ;;
  esac
  printf '\n'
}

main "$@"
