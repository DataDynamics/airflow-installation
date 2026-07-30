# Airflow 2.x 4-노드 대칭 HA 클러스터 — 작업 계획 (WIP)

> 브랜치: `feature/sem` (2.x 라인) · 작성: 2026-07-20 · 상태: **설계 확정 직전, 입력 2~3개 대기**
> 이 문서는 내일 이어서 작업하기 위한 작업 노트. 확정되면 DESIGN.md/README.md에 반영.

---

## 1. 요구사항 (사용자)

- 서버 4대: **16.3.225.104 ~ 107**, RHEL 9.4
- Airflow **2.x 최신 = 2.11.0** (현재 저장소 타깃과 일치)
- **모든 노드**에 설치: PostgreSQL · Celery(worker) · Scheduler · Airflow Web UI · Redis
- 4대를 **클러스터(대칭 HA)** 로 구성
- PostgreSQL: **PGPool + 스트리밍 복제**
- Web UI 앞단: **외부 LB 존재** (LB IP는 추후 통보 — 설계엔 무관)

## 2. 현재 저장소 구조 (변경 출발점)

- 모델: **비대칭** `ROLE=control|worker`
  - control 1대 = webserver+scheduler+PG(메타DB)+Redis(브로커)
  - worker N대 = celery worker 전용, DB/Redis는 control 원격 접속
- PG 단일 인스턴스(복제/PGPool 없음), Redis 단일(HA 없음)
- CeleryExecutor(Phase2), 비밀은 `cluster.env` 로 전 노드 공유
- 핵심 파일: `install/{env.sh,00~06,05-airflow-init,install-all,gen-cluster-keys}.sh`, `deploy/{deploy-cluster,print-node-commands}.sh`

## 3. 확정된 결정 (사용자 승인)

| 항목 | 결정 |
|------|------|
| Web UI 진입 | **외부 LB** (4대 :8080 분산, 전 노드 동일 `secret_key` 공유 — 이미 처리) |
| Redis HA | **Redis Sentinel** (Celery는 Redis Cluster 브로커 미지원 → sentinel:// 사용) |
| PGPool 로드밸런싱 | **Failover 전용, `load_balance_mode=off`** (Airflow 메타DB read-replica 미지원 → 전 쿼리 프라이머리로) |
| DB VIP | **없음** → 아래 "PGPool 로컬 사이드카" 방식으로 VIP 불필요하게 설계 |

## 4. 확정 설계 — VIP 없는 PGPool 로컬 사이드카

```
각 노드(.104~107):
  Airflow(scheduler/web/worker) ──▶ 127.0.0.1:9999 (로컬 PGPool)
  로컬 PGPool ── 백엔드 목록(전 노드 동일): .104,.105,.106,.107 (PG)
              └─ sr_check 로 현재 Primary 식별 → 그쪽으로만 라우팅(LB off)
```

- **Airflow는 항상 `127.0.0.1:9999`(로컬 PGPool)** 접속 → 엔드포인트 노드 고정, 페일오버해도 Airflow 설정 불변 → VIP 불필요.
- 4개 PGPool 모두 **동일 백엔드 목록** → failover 시 node id 일관.
- **watchdog: VIP(delegate_ip) 없이 quorum + 페일오버 조정 용도만**. 프라이머리 장애 시 watchdog 리더 1대만 `failover_command`(standby 승격)+`follow_primary_command`(나머지 재복제) → 중복 승격 방지.
- `sql_alchemy_conn` / `result_backend` 모두 `127.0.0.1:9999`.

### PostgreSQL 토폴로지
- **1 Primary(초기 .104 가정) + 3 Hot Standby** 스트리밍 복제 (멀티 프라이머리 아님).
- primary: `wal_level=replica`, `max_wal_senders`, 복제 슬롯, 복제 롤, `pg_hba` replication 규칙.
- standby: `pg_basebackup` + `standby.signal` + `primary_conninfo`.

### Redis 토폴로지
- redis master 1 + replica 3 + sentinel(4대) → `broker_url = sentinel://...` + `master_name` 트랜스포트 옵션.
- sentinel `quorum` 홀수 지향(2~3).

### Airflow
- 4대 모두 scheduler+webserver+worker 기동 (다중 스케줄러 HA는 2.x 지원, SKIP LOCKED).
- `db migrate`/`users create` 는 **정확히 1대(프라이머리)에서만** — 동시 마이그레이션 방지 가드 필요.

## 5. 갭 분석 — 변경 대상 파일

| 파일 | 현재 | 필요한 변경 |
|------|------|-------------|
| `install/env.sh` | ROLE=control\|worker, 단일 CONTROL_IP, redis:// | ROLE=primary\|standby(+all-services), VIP없는 노드목록·복제계정·sentinel 변수, broker sentinel:// 파생, DB 엔드포인트 127.0.0.1:9999 |
| `install/01-os-packages.sh` | control만 PG/redis | 전 노드 PG+redis+**pgpool-II**+**sentinel** 설치 |
| `install/03-postgres.sh` | 단일 프라이머리 init | primary(wal/슬롯/복제롤/hba) + **신규 standby 경로**(pg_basebackup) |
| **신규** `03c-pgpool.sh` | 없음 | pgpool.conf(sr mode, LB off, 백엔드4), pcp, watchdog(VIP 없음), failover/follow_primary 스크립트 |
| `install/04-redis.sh` | 단일 | master/replica + **sentinel**(신규 04b 또는 확장) |
| `install/05-airflow-init.sh` | control만 migrate, redis:// | conn→127.0.0.1:9999, broker→sentinel+transport opts, **migrate 1회 가드**, 전 노드 scheduler+web+worker |
| `install/install-all.sh` | control→worker | primary DB→standby clone→pgpool→migrate 1회 순서 재설계 |
| `install/gen-cluster-keys.sh` | CONTROL_IP 단일 | 노드목록, PG_PRIMARY, 복제비번, sentinel master_name, pcp 비번 추가 |
| `deploy/deploy-cluster.sh` | control→worker | primary→standby→pgpool→airflow(migrate 1회) 오케스트레이션 |
| `DESIGN.md`·`README.md` | Phase2=control+worker | 신규 대칭 HA 토폴로지 문서화 |
| `build/*` 패키징 | pgpool 미포함 | **pgpool-II RPM** airgap 소싱(미러/번들) 추가 — RHEL 기본 repo에 없음 |

## 6. 리스크 / 주의

- **노드 간 passwordless SSH 필요**(postgres 계정): PGPool 페일오버가 원격 `pg_ctl promote`/`pg_basebackup`/`pg_rewind` 실행.
- **짝수(4) quorum**: watchdog·sentinel 모두 홀수 권장 → split-brain 방지 위해 quorum/우선순위/fencing 신중.
- **자원 부담**: 각 노드가 PG+PGPool+Redis+Sentinel+scheduler+web+worker 동거 → 노드 스펙 확인 필요.
- **커넥션 수학**: 4 scheduler+4 web+4 worker → PGPool `num_init_children`/`max_pool`, PG `max_connections` 사이징.
- **pgpool-II ↔ PG 메이저 버전 정합**(RHEL AppStream 기본 PG는 13; pgpool 버전 매칭).
- **airgap 패키징**: pgpool-II(및 의존성) RPM을 미러/번들에 추가해야 오프라인 설치 가능.

## 7. 내일 확인할 입력 (BLOCKING)

- [ ] **초기 PG 프라이머리 노드** — 기본 가정 **.104**. 이대로?
- [ ] **노드 스펙(CPU/RAM)** — 전 서비스 동거 사이징용.
- [ ] **노드 간 SSH** — 페일오버용 상호 passwordless SSH 구성 가능?
- [ ] (참고) LB IP는 나중에 통보받아 방화벽/base_url에만 반영.

## 8. 다음 단계 (입력 확정 후)

1. 이 문서를 DESIGN.md에 정식 반영 + README 토폴로지 갱신.
2. `env.sh` 역할/변수 모델 재설계 → `gen-cluster-keys.sh` 확장.
3. `03-postgres.sh` primary/standby 분기 + 신규 `03c-pgpool.sh`.
4. `04-redis.sh` + sentinel.
5. `05-airflow-init.sh` conn/broker/migrate-가드/전서비스 기동.
6. `install-all.sh`/`deploy-cluster.sh` 오케스트레이션.
7. 패키징(pgpool RPM) → 빌드/번들 검증.
