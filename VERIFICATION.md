# Airflow 3.3.0 Airgap 설치 — 검증 보고서

> 검증일: 2026-07-16 · 검증자 커밋: `9d1ae50`(3.3.0 개편) → `b5c943e`(Phase 2 수정) → `f404df5`(모드 A)
> 상세 설계·AS-BUILT는 [`DESIGN.md`](./DESIGN.md) §13/§13-B/§13-C 참고. 본 문서는 검증 절차·결과·발견사항 요약.

---

## 1. 검증 환경

| 노드 | IP | OS | Python | 역할 | OS 패키지 소스 |
|---|---|---|---|---|---|
| control | 192.168.122.191 | RHEL 9.2 | 3.11.2 | Phase1 단일노드 → Phase2 control | `RPM_SOURCE=system` (DVD ISO repo) |
| worker-1 | 192.168.122.62 | RHEL 9.4 | 3.11.7 | celery worker (구 2.11 데모 노드 재활용) | `system` (사내 미러 repo 기등록) |
| worker-2 | 192.168.122.92 | **Rocky 9.7** | 3.11.13 | celery worker (fresh 노드) | `system` (자체 repo) |

- 전 노드 2~4 vCPU / 7.5GB / SELinux **Enforcing** 유지.
- wheelhouse는 ubi9/python-311 컨테이너에서 1회 빌드(**209 wheels**, cp311) → 세 OS에 재빌드 없이 동일 사용.
- 번들: `airflow-3.3.0-airgap-bundle.tar.gz` (142MB), 전체 설치는 `--no-index` 오프라인 pip.

## 2. 검증 매트릭스 (3경로 전부 통과)

```mermaid
flowchart LR
  P1["① Phase 1<br/>단일노드 LocalExecutor<br/>(install-all.sh)"] --> P2B["② Phase 2 모드 B<br/>각 서버 직접 설치<br/>control 전환 + worker 62"] --> P2A["③ Phase 2 모드 A<br/>deploy-cluster.sh 한번에<br/>3노드 (worker 92 추가)"]
```

| # | 검증 항목 | 결과 |
|---|---|---|
| 1 | 오프라인 설치 (wheelhouse `--no-index` + constraints-3.11) | ✅ 3개 노드 모두 |
| 2 | 4개 서비스 기동 (api-server·scheduler·dag-processor·triggerer) | ✅ systemd active + 재부팅 enable |
| 3 | health `/api/v2/monitor/health` | ✅ 4개 컴포넌트 healthy |
| 4 | FAB 인증 (`auth_manager=FabAuthManager`) | ✅ `users create` 동작, `POST /auth/token` JWT 발급, UI 200 |
| 5 | E2E DAG 실행 (3.x TaskFlow, `airflow.sdk`) | ✅ Phase1 및 클러스터 누적 **8/8 런 success**, XCom 전달 |
| 6 | 태스크의 Execution API 경유 실행 | ✅ 워커 cfg `execution_api_server_url=http://191:8080/execution/`, 로그가 워커에만 생성됨으로 증명 |
| 7 | celery 워커 등록 | ✅ `inspect ping` → worker-1·worker-2 **2 nodes online** |
| 8 | 태스크 분산 | ✅ 최근 4런 8태스크 = worker-1 5개 / worker-2 3개 |
| 9 | 원격 태스크 로그 (control REST → 워커 :8793) | ✅ 두 워커 모두 fetch 성공 |
| 10 | 모드 A 자동화 (push→control→health 게이트→워커 순차) | ✅ exit 0, 게이트 정상 작동 |
| 11 | 장애 회복 | ✅ DAG 미배포로 실패한 태스크가 파일 배포 후 retry(try 2)로 자동 성공 |
| 12 | 이기종 RHEL 계열 (RHEL 9.2/9.4 + Rocky 9.7) | ✅ 동일 wheelhouse로 혼합 구성 동작 |

## 3. 검증 중 발견·수정한 결함 (스크립트 반영 완료)

| # | 증상 | 원인 | 수정 (커밋) |
|---|---|---|---|
| 1 | 설치 시 `ResolutionImpossible: async-timeout` | 빌드 컨테이너(py 3.11.9+)와 대상(py 3.11.2)의 **패치버전 마커 차이** — redis-py의 `async-timeout; python_full_version<"3.11.3"`이 빌드 시 미수집 | 빌드 스크립트가 async-timeout 명시 수집 (`9d1ae50`) |
| 2 | celery 워커 기동 즉시 사망: `Port could not be cast to integer value as 'Airflow'` | 비밀번호의 `#`가 kombu URL 파서를 깨뜨림 (SQLAlchemy는 관대해 Phase1에선 잠복) | env.sh가 URL 조립 시 비밀번호 **percent-encoding** (`b5c943e`) |
| 3 | worker 설치가 완료됐는데 exit 1 | `set -e` 하에서 마지막 줄 `[ control ] && echo`가 worker에서 false | `\|\| true` (`b5c943e`) |
| 4 | `OPEN_FIREWALL=true`여도 8080/8793 미개방 | 3.x에서 8080은 워커의 태스크 실행 경로, 8793은 로그 서빙인데 개방 로직 부재 | 05가 control:8080·worker:8793 개방 (`b5c943e`) |

## 4. 실측 확인된 운영 필수 요건 (DESIGN §8.6)

1. **노드별 고유 hostname + control에서 resolve** — 로그 fetch가 `task_instance.hostname:8793`을 사용.
   `localhost.localdomain`이면 control이 자기 자신에서 로그를 찾아 실패. `/etc/hosts` 또는 DNS 등록 필요.
2. **DAG 파일 전 노드 동일 배포** — 워커가 태스크 시작 시 로컬 dag bundle에서 파싱.
   없으면 `Dag not found during start up` → 3회 재스케줄 후 실패(NFS/GitOps/rsync 동기화 필수).
3. **공유 비밀 3종 일치** — fernet/secret에 더해 3.x는 **JWT secret** 불일치 시 워커 Execution API 401.
   `gen-cluster-keys.sh`가 cluster.env에 포함.
4. 모드 A는 **전 노드 동일 SSH 계정**(보통 root) 전제 — root ssh 불가 환경은 모드 B.
5. Phase 2 포트: 워커→control `6379/8080/5432`, control→워커 `8793`, 운영자→control `8080`.

## 5. 재현 절차 (요약)

```bash
# 빌드 (인터넷 빌드머신, 1회)
./build/build-wheelhouse-docker.sh && ./build/package.sh

# Phase 1 (단일노드)
tar xzf dist/airflow-3.3.0-airgap-bundle.tar.gz -C /opt/airflow-install --strip-components=1
cd /opt/airflow-install && RPM_SOURCE=system PG_PASSWORD=*** AF_ADMIN_PASSWORD=*** ./install/install-all.sh

# Phase 2 (모드 A)
./install/gen-cluster-keys.sh dist/cluster.env <CONTROL_IP> <WORKER_CIDR>
CONTROL_IP=<ip> WORKER_IPS="<w1> <w2> ..." SSH_USER=root SSH_PASS=*** ./deploy/deploy-cluster.sh
# 사후: 각 워커 hostname 지정·control hosts 등록, DAG 배포

# 판정
curl http://<control>:8080/api/v2/monitor/health          # 4개 healthy
celery ... inspect ping                                    # N nodes online
airflow dags trigger <dag> → 런 success + 워커 로그 확인
```

## 6. 미검증/후속 항목

- flower(:5555) 모니터링 (`ENABLE_FLOWER=true` 경로) — 스크립트 존재, 미가동.
- `RPM_SOURCE=bundle`(RPM 동봉 완전 오프라인)의 3.3.0 재검증 — 2.11에서 검증됐고 로직 불변이나,
  `os-packages.list`가 python3.11로 바뀌어 RPM 재추출 필요.
- PostgreSQL 15 모듈(`dnf module enable postgresql:15`) 구성 — PG13은 업스트림 EOL(2025-11), 운영 전 권장.
- 대규모(워커 3+대) 및 실제 운영 IP 대역(192.168.0.x)에서의 배포.
