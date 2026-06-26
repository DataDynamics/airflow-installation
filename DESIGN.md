# Apache Airflow 2.11 Airgap 설치 설계서

> 대상: RHEL 9.4 / 192.168.122.62 (airgap)
> 작성일: 2026-06-26

---

## 1. 확정된 전제 (실측 기반)

### 1.1 대상 서버 (192.168.122.62) — 실측값
| 항목 | 값 |
|---|---|
| OS | Red Hat Enterprise Linux 9.4 (Plow), x86_64 |
| CPU / MEM | 2 vCPU / 7.5 GiB |
| Disk | `/` 44 GB (40 GB 여유) |
| 시스템 Python | 3.9.18 (`/usr/bin/python3`) |
| SELinux | **Enforcing** |
| 인터넷 | 차단됨 (airgap 확인) |
| `/etc/yum.repos.d/` | 비어 있음 → repo 등록 필요 |

### 1.2 RHEL 패키지 저장소 (실측)
- 호스트: `http://10.0.1.102/` (Synology DSM 웹서버)
- 서브트리(둘 다 repodata 200 OK):
  - `http://10.0.1.102/rhel-9.4/BaseOS/`
  - `http://10.0.1.102/rhel-9.4/AppStream/`
- 디렉터리 인덱싱은 비활성(403)이지만 yum repodata 접근은 정상.

### 1.3 결정 사항 (사용자 확정)
| 항목 | 선택 |
|---|---|
| Airflow 버전 | **2.11.x** (2.x 최신) |
| Python 런타임 | **시스템 Python 3.9** |
| 메타DB / 브로커 | **PostgreSQL + Redis** |
| 빌드머신 | 별도 없음 → **오케스트레이터(Ubuntu+docker+인터넷)에서 컨테이너로 wheel 생성** |

### 1.4 빌드 환경 (실측)
- 본 작업 머신: Ubuntu 24.04 / x86_64 / **인터넷 가능** / **docker 사용 가능**
- 10.0.1.102 도달 가능 → 산출물 배포 경로로도 활용 가능.

---

## 2. 토폴로지 설계

### Phase 1 — 단일 노드 (현재 목표)
모든 컴포넌트를 192.168.122.62 한 대에 설치. **Executor = LocalExecutor**.

```
┌─────────────────── 192.168.122.62 ───────────────────┐
│  airflow webserver (gunicorn :8080)                   │
│  airflow scheduler                                    │
│  ─ LocalExecutor (스케줄러 프로세스 내 병렬 실행) ─    │
│  PostgreSQL 15 (메타DB, :5432, localhost)             │
│  Redis (Phase2 대비 설치만, :6379, localhost)         │
└───────────────────────────────────────────────────────┘
```
- 단일 노드에서는 Celery/Redis가 필수 아님. **하지만 Phase 2 무중단 확장을 위해 Redis는 설치만 해두고**, airflow.cfg는 LocalExecutor로 시작.

### Phase 2 — 1 web/scheduler + 3 celery worker (확장 시)
**Executor = CeleryExecutor** 로 전환. 메타DB/브로커는 컨트롤 노드에 두고 워커가 원격 접속.

```
┌──── Control 노드 (192.168.122.62) ────┐     ┌─ worker1 ─┐
│ webserver :8080                        │     │ celery     │
│ scheduler (CeleryExecutor)             │◄────│ worker     │
│ PostgreSQL :5432  (워커에 개방)        │     └────────────┘
│ Redis :6379       (워커에 개방)        │     ┌─ worker2 ─┐
│ flower :5555 (선택)                    │◄────│ celery     │
└────────────────────────────────────────┘     └────────────┘
                                                ┌─ worker3 ─┐
                                          ◄─────│ celery     │
                                                └────────────┘
```
전환 시 변경점은 §8 참조 (executor, broker_url, result_backend, DB/Redis bind 주소, 방화벽).

---

## 3. 설치 디렉터리 / 계정 표준

| 항목 | 값 |
|---|---|
| 서비스 계정 | `airflow` (시스템 계정, nologin) |
| AIRFLOW_HOME | `/opt/airflow` |
| Python venv | `/opt/airflow/venv` (시스템 py3.9 기반) |
| DAGs | `/opt/airflow/dags` |
| Logs | `/opt/airflow/logs` |
| Plugins | `/opt/airflow/plugins` |
| 설정 | `/opt/airflow/airflow.cfg` |
| 배포 산출물 적재 | `/opt/airflow-install/` (wheelhouse, rpm 등) |
| PostgreSQL data | `/var/lib/pgsql/data` (기본 경로 — SELinux 컨텍스트 정합 유지) |

---

## 4. 패키지 인벤토리

### 4.1 OS 패키지 (RHEL repo: BaseOS/AppStream에서 dnf 설치)
airgap 대상은 repo가 사내에 있으므로 **dnf로 직접 설치**(별도 RPM 반출 불필요).

핵심 목록:
- 런타임/빌드: `python3` `python3-pip` `python3-devel` `gcc` `gcc-c++` `make`
- DB 클라이언트 빌드용: `libpq` `libpq-devel` (psycopg2 빌드/실행)
- DB 서버: `postgresql-server` `postgresql-contrib`
- 브로커: `redis`
- 보조: `tar` `gzip` `which` `procps-ng` `policycoreutils-python-utils`(SELinux 관리) `firewalld`(선택)

> 비고: wheel을 컨테이너에서 **완전 바이너리(wheel)** 로 빌드하므로 대상에서 컴파일이 필요 없도록 설계. 단 안전망으로 `gcc`/`*-devel` 은 설치해 둠.

> **Python 3.9는 RHEL 9.4 기본 제공** → 별도 빌드/패키징하지 않고 시스템 `python3` 를 그대로 사용.
> **OS 패키지(RPM) 두 경로** (`RPM_SOURCE`):
> - `mirror`(기본): 설치 시 사내 미러(10.0.1.102)에서 `dnf`. target 이 미러에 접근 가능할 때.
> - `bundle`: `build/extract-rpms-*.sh` 가 `os-packages.list` + **전체 의존성**을 미러에서 추출(`dnf download --resolve --alldeps` + `createrepo_c`)해 `artifacts/rpms` 로컬 repo 생성 → 번들에 포함 → target 이 **미러 없이 완전 오프라인**(`file://` 로컬 repo)으로 설치. (검증: `--network none` 컨테이너에서 266 RPM 로컬 repo만으로 설치 성공)

### 4.2 Python 패키지 (wheelhouse — 컨테이너에서 생성)
- 설치 extras: `apache-airflow[celery,postgres,redis]==2.11.0`
- 제약: 공식 constraints
  `constraints-2.11.0/constraints-3.9.txt`
- 부트스트랩 포함: `pip` `setuptools` `wheel` (대상 venv용, 오프라인)

---

## 5. 빌드 단계 (빌드머신: 인터넷 필요)

목표: RHEL9 ABI/Python3.9 와 **완전히 호환되는 wheel 묶음** 생성. 두 가지 빌드 변형 제공(택1, 동일 산출물):
- **`build/build-wheelhouse-docker.sh`** — docker 되는 아무 OS(Ubuntu 등)에서 `registry.access.redhat.com/ubi9/python-39` 컨테이너로 빌드(RHEL9 glibc/Python3.9 동일).
- **`build/build-wheelhouse-rhel.sh`** — RHEL 9.4(또는 Rocky/Alma 9) 빌드머신에서 **시스템 python3.9로 네이티브 빌드**(docker 불필요, 임시 venv 격리). 대상과 동일 OS라 가장 정합.

아래 5.1은 docker 변형의 핵심 로직(네이티브 변형도 동일하게 `pip wheel`로 수집).

### 5.1 wheelhouse 생성
```bash
# 오케스트레이터에서 실행 (인터넷 필요)
mkdir -p ./artifacts/wheelhouse
AF=2.11.0; PY=3.9
CONSTRAINTS="https://raw.githubusercontent.com/apache/airflow/constraints-${AF}/constraints-${PY}.txt"

docker run --rm -v "$PWD/artifacts/wheelhouse:/wh" \
  registry.access.redhat.com/ubi9/python-39 bash -lc "
    set -e
    pip install --upgrade pip wheel
    # 부트스트랩 도구도 오프라인 설치용으로 함께 수집
    pip download -d /wh pip setuptools wheel
    # airflow + extras 전체를 '바이너리 wheel'로 빌드/수집
    pip wheel 'apache-airflow[celery,postgres,redis]==${AF}' \
      -c '${CONSTRAINTS}' -w /wh
  "
# constraints 파일도 함께 보관
curl -fsSL "$CONSTRAINTS" -o ./artifacts/constraints-${PY}.txt
```
산출물: `./artifacts/wheelhouse/*.whl` + `constraints-3.9.txt`

### 5.2 산출물 패키징
```bash
tar czf airflow-2.11-py39-airgap.tar.gz -C ./artifacts .
sha256sum airflow-2.11-py39-airgap.tar.gz > airflow-2.11-py39-airgap.tar.gz.sha256
```

---

## 6. 전송 단계

```bash
# 오케스트레이터 → 대상
scp airflow-2.11-py39-airgap.tar.gz* root@192.168.122.62:/opt/airflow-install/
# 대상에서 검증/해제
ssh root@192.168.122.62 '
  cd /opt/airflow-install && sha256sum -c airflow-2.11-py39-airgap.tar.gz.sha256 &&
  tar xzf airflow-2.11-py39-airgap.tar.gz'
```

---

## 7. 설치 단계 (대상 192.168.122.62)

### 7.1 RHEL repo 등록
`/etc/yum.repos.d/local-rhel94.repo`:
```ini
[local-baseos]
name=RHEL 9.4 BaseOS (local)
baseurl=http://10.0.1.102/rhel-9.4/BaseOS/
enabled=1
gpgcheck=0

[local-appstream]
name=RHEL 9.4 AppStream (local)
baseurl=http://10.0.1.102/rhel-9.4/AppStream/
enabled=1
gpgcheck=0
```
> `gpgcheck=0` 은 사내 미러 신뢰 전제. GPG 키가 미러에 있으면 `gpgcheck=1`+`gpgkey=` 권장.
검증: `dnf clean all && dnf repolist && dnf makecache`

### 7.2 OS 패키지 설치
```bash
dnf -y install python3 python3-pip python3-devel gcc gcc-c++ make \
  libpq libpq-devel postgresql-server postgresql-contrib redis \
  policycoreutils-python-utils tar gzip which procps-ng
```

### 7.3 서비스 계정/디렉터리
```bash
useradd --system --home-dir /opt/airflow --shell /sbin/nologin airflow || true
mkdir -p /opt/airflow/{dags,logs,plugins}
chown -R airflow:airflow /opt/airflow
```

### 7.4 venv + 오프라인 pip 설치
```bash
sudo -u airflow python3 -m venv /opt/airflow/venv
WH=/opt/airflow-install/wheelhouse
# 부트스트랩(오프라인)
sudo -u airflow /opt/airflow/venv/bin/pip install \
  --no-index --find-links "$WH" --upgrade pip setuptools wheel
# airflow 본체(오프라인, constraints 적용)
sudo -u airflow /opt/airflow/venv/bin/pip install \
  --no-index --find-links "$WH" \
  -c /opt/airflow-install/constraints-3.9.txt \
  "apache-airflow[celery,postgres,redis]==2.11.0"
```

### 7.5 PostgreSQL 초기화
```bash
postgresql-setup --initdb           # /var/lib/pgsql/data 생성 (SELinux 정합)
systemctl enable --now postgresql
sudo -u postgres psql <<'SQL'
CREATE ROLE airflow LOGIN PASSWORD 'CHANGE_ME_STRONG';
CREATE DATABASE airflow OWNER airflow ENCODING 'UTF8';
GRANT ALL PRIVILEGES ON DATABASE airflow TO airflow;
SQL
```
Phase1은 localhost 접속이라 `pg_hba.conf` 기본(ident/peer→md5) 조정만. Phase2에서 워커 서브넷 개방(§8).

### 7.6 Redis (Phase2 대비, 설치/기동만)
```bash
systemctl enable --now redis        # 기본 127.0.0.1:6379
```

### 7.7 airflow.cfg 핵심 (Phase 1 = LocalExecutor)
`/opt/airflow/airflow.cfg` (또는 환경변수):
```ini
[core]
executor = LocalExecutor
dags_folder = /opt/airflow/dags
load_examples = False
parallelism = 16
[database]
sql_alchemy_conn = postgresql+psycopg2://airflow:CHANGE_ME_STRONG@127.0.0.1:5432/airflow
[logging]
base_log_folder = /opt/airflow/logs
[webserver]
web_server_port = 8080
secret_key = <openssl rand -hex 32 로 생성>
```

### 7.8 DB 마이그레이션 / 관리자 계정
```bash
export AIRFLOW_HOME=/opt/airflow
sudo -u airflow AIRFLOW_HOME=/opt/airflow /opt/airflow/venv/bin/airflow db migrate
sudo -u airflow AIRFLOW_HOME=/opt/airflow /opt/airflow/venv/bin/airflow users create \
  --username admin --firstname A --lastname D --role Admin \
  --email admin@example.com --password CHANGE_ME_ADMIN
```

### 7.9 systemd 유닛
`/etc/systemd/system/airflow-webserver.service`, `airflow-scheduler.service`
(공통: `User=airflow`, `EnvironmentFile`로 `AIRFLOW_HOME=/opt/airflow`,
`ExecStart=/opt/airflow/venv/bin/airflow webserver|scheduler`).
```bash
systemctl daemon-reload
systemctl enable --now airflow-scheduler airflow-webserver
```

### 7.10 SELinux / 방화벽
- SELinux **Enforcing 유지**. 표준 경로(PG 기본 data dir, gunicorn 8080 바인딩)는 추가 정책 불필요.
  - `/opt/airflow` 하위 접근 문제 발생 시: `semanage fcontext`/`restorecon` 로 컨텍스트 정리(설치 스크립트에 점검 단계 포함).
- 방화벽(firewalld 사용 시): Phase1은 8080만 개방.
  ```bash
  firewall-cmd --permanent --add-port=8080/tcp && firewall-cmd --reload
  ```

---

## 8. Phase 2 — CeleryExecutor (1 web + 3 celery) 설계 [구현 반영]

### 8.0 토폴로지 / IP 계획
| 역할(`ROLE`) | 노드 | 구성 |
|---|---|---|
| `control` | **web 192.168.0.1** | webserver + scheduler + **PostgreSQL(메타DB)** + **Redis(브로커)** (+선택 flower) |
| `worker` | **celery 192.168.0.2 ~ .4** | celery worker 전용. DB/Redis는 **control(192.168.0.1) 원격 접속**, 로컬 미설치 |

> 별도 DB 노드 가정 없음 → 메타DB/브로커는 web 노드에 동거. 관리형 외부 DB로 바꾸려면 `DB_MODE=external`(§12.4)로 스왑.
> 모든 노드는 DB/브로커 엔드포인트로 **CONTROL_IP(192.168.0.1)** 를 바라봄(엔드포인트 통일).

### 8.1 역할 모델 (스크립트 자동 분기)
`ROLE` 한 변수로 전 단계가 갈린다(`env.sh`가 worker면 `DB_MODE=external`,`INSTALL_REDIS=false` 강제).

| 단계 | control | worker |
|---|---|---|
| 01 OS패키지 | +postgresql-server, +redis | 클라이언트(libpq)만 |
| 03 DB | 로컬 PG init + **원격개방** | (03b) control DB **연결검증만** |
| 04 Redis | bind+requirepass+방화벽 | 스킵 |
| 05 init | `db migrate`+admin+**web/scheduler 기동** | **migrate 금지**, `db check`+**worker 기동** |
| 키 | 신규생성 가능 | **control과 동일 키 주입 필수**(없으면 에러) |

### 8.2 control 노드 원격 개방 (env 값으로 활성)
- PostgreSQL: `listen_addresses='localhost,192.168.0.1'`(restart), `pg_hba` 에 `host airflow airflow <WORKER_CIDR> md5` 추가.
- Redis: `requirepass`, `bind 127.0.0.1 192.168.0.1`, `protected-mode no`(인증으로 보호).
- 방화벽(`OPEN_FIREWALL=true`): 5432·6379·8080 개방.

### 8.3 클러스터 시크릿 (키 일치가 핵심)
- `gen-cluster-keys.sh` 가 **`cluster.env` 1회 생성**: `AF_FERNET_KEY`/`AF_SECRET_KEY`(전 노드 동일), `PG_PASSWORD`/`REDIS_PASSWORD`/`AF_ADMIN_PASSWORD`, `CONTROL_IP`, `PG_ALLOW_CIDR` 등.
- 이 파일을 **모든 노드에 동일 배포** → fernet 불일치로 인한 Connection 복호화 실패/워커 미동작 방지.

### 8.4 설치 모드 (요청사항: 한번에 vs 각 서버 직접)
**모드 A — 한번에 (SSH 가능):** `deploy/deploy-cluster.sh`
- 조정자가 번들+cluster.env를 push, **control 먼저 설치·health 대기 후 워커 순차** 설치.
- 사용: `CONTROL_IP=192.168.0.1 WORKER_IPS="192.168.0.2 192.168.0.3 192.168.0.4" SSH_USER=root SSH_PASS=*** ./deploy/deploy-cluster.sh`

**모드 B — 각 서버 직접 (SSH 원격실행 불가):** `deploy/print-node-commands.sh` 가 노드별 복붙 명령 출력
- 각 노드에서 번들 해제 후:
  - control(먼저): `sudo bash -c 'set -a; source ./cluster.env; set +a; ROLE=control ./install/install-all.sh'`
  - worker(이후): `… ROLE=worker ./install/install-all.sh`
- 검증: control에서 `celery … inspect ping` 으로 3워커 응답 확인.

> 공통 제약: **control 선행 → 워커**(스키마는 control이 소유). 두 모드 모두 이 순서를 강제/안내.

### 8.5 운영 주의
- 전 노드 **시간동기(chrony)**. DAGs 일관성: 시작은 NFS, 운영권장 GitOps/이미지 배포로 `/opt/airflow/dags` 동기.
- worker 미생성 단계에선 control만 설치해 운영(LocalExecutor 아님, CeleryExecutor지만 워커 0). 워커는 추후 추가만 하면 됨.

---

## 9. 검증 체크리스트
1. `dnf repolist` 에 local-baseos/appstream 정상.
2. `/opt/airflow/venv/bin/airflow version` → 2.11.0.
3. `airflow db check` 성공(PostgreSQL 연결).
4. `systemctl status airflow-scheduler airflow-webserver` active.
5. 브라우저 `http://192.168.122.62:8080` 로그인.
6. 예제 DAG 1개 트리거 → 성공(LocalExecutor 실행 확인).
7. (Phase2) `airflow celery worker` 기동 후 워커에서 태스크 실행 로그 확인.

---

## 10. 산출물 구조 (이 저장소)
```
airflow-installation/
├─ DESIGN.md                  # 본 문서
├─ build/                     # wheelhouse 빌드 + RPM 추출 + 번들 패키징 (인터넷/미러)
│   ├─ build-wheelhouse-docker.sh   # Python wheel: docker(ubi9/python-39)
│   ├─ build-wheelhouse-rhel.sh     # Python wheel: RHEL 9.4 네이티브
│   ├─ extract-rpms-docker.sh       # OS RPM 추출: docker
│   ├─ extract-rpms-rhel.sh         # OS RPM 추출: RHEL 네이티브
│   ├─ os-packages.list             # OS 패키지 superset 목록
│   └─ package.sh
├─ install/                   # (예정) 대상 서버 설치 스크립트
│   ├─ 00-repo.sh  01-os-packages.sh  02-venv-offline.sh
│   ├─ 03-postgres.sh  04-redis.sh  05-airflow-cfg.sh
│   └─ systemd/*.service
└─ artifacts/                 # 빌드 산출물(wheelhouse, constraints) — git 제외
```

---

## 12. 유연한 구성 — 설치경로 / 실행계정 / DB 외부화 (Phase 1 확장)

Phase 2로 가기 전, Phase 1을 **환경변수 파라미터**로 흡수하도록 일반화. 모든 값은
`install/env.sh`에서 override 가능하며 **기본값은 기존 `/opt`·로컬PG 구성을 그대로 재현**
(따라서 기존 배포에 재실행해도 동일).

### 12.1 변경 요지 (3개 축)
| 축 | 파라미터 | 의미 |
|---|---|---|
| ① 설치 경로 | `INSTALL_ROOT`(기본 `/opt`) | 별도 디스크 `/app` 등으로 전체 트리 이동. `AIRFLOW_HOME`/`VENV`/`INSTALL_DIR` 모두 파생 |
| ② 실행 계정 | `AIRFLOW_USER`/`AIRFLOW_GROUP`/`CREATE_USER` | 계정명 변경, **조직이 이미 만든 계정**이면 `CREATE_USER=false`(생성 안 함) |
| ③ PostgreSQL | `DB_MODE=local\|external` + `PG_*`/`PG_SSLMODE`/`PG_ADMIN_*` | 로컬 직접 구성 vs **서비스로 제공되는 외부 PostgreSQL** |

### 12.2 ① 설치 경로 (예: `/app`)
- `INSTALL_ROOT=/app` 하나만 주면: `AIRFLOW_HOME=/app/airflow`, `VENV=/app/airflow/venv`,
  `INSTALL_DIR=/app/airflow-install` 자동 파생.
- **AIRFLOW_HOME 은 계정 home 과 무관**하게 위치(서비스 계정 home 이 `/home/...`여도 무방).
- `/app` 은 보안 마운트가 아닌 **일반 디렉터리(실행 가능)** 전제 → `noexec` 고려 불필요.
- **SELinux 정합 필요**: 새 파일시스템/비표준 경로는 기본 레이블이 `/opt`와 다름.
  `06-selinux.sh` 가 `semanage fcontext -a -e /opt ${INSTALL_ROOT}` 로 **/opt 규칙을 상속**시키고
  `restorecon` 으로 relabel (Enforcing 유지). `INSTALL_ROOT=/opt`면 자동 스킵.
- systemd 유닛의 `ExecStart`/`User` 는 정적 파일이 아니라 **05가 변수로 렌더링** → 경로 바뀌어도 정합.

### 12.3 ② 실행 계정
- `CREATE_USER=true`(기본): 그룹+시스템계정 생성(없을 때만).
- `CREATE_USER=false`: 조직 제공 계정 사용. 계정이 없으면 **에러로 중단**(오설치 방지).
- 디렉터리/`airflow.cfg`/유닛의 소유·실행 주체를 `AIRFLOW_USER:AIRFLOW_GROUP` 로 일괄 반영.

### 12.4 ③ PostgreSQL: local vs external
**`DB_MODE=local`(기본):** 기존과 동일. `01`이 `postgresql-server` 설치, `03-postgres.sh`가
initdb/기동/`pg_hba`(ident→md5)/DB·롤 생성.

**`DB_MODE=external`(서비스 제공 DB):**
- `01`은 `postgresql-server`를 **설치하지 않음**(클라이언트 `libpq`만). `03-postgres.sh`는 자동 스킵.
- 대신 **`03b-db-external.sh`** 사용:
  1. `PG_HOST:PG_PORT` **TCP 도달성** 검사(라우팅/방화벽),
  2. `PG_ADMIN_USER/PASSWORD` 가 있으면 원격에 **DB/롤 생성**(idempotent), 없으면 DBA 사전 프로비저닝 가정,
  3. airflow 자격증명으로 **실연결 검증**.
- 연결 문자열은 `SQLA_CONN`(env.sh 파생)이 **`?sslmode=${PG_SSLMODE}`** 포함.
  관리형 DB는 보통 `require`/`verify-full`. Celery `result_backend`도 동일 DB 지향.
- Airflow 마이그레이션이 테이블을 만들므로 airflow 롤은 해당 DB **스키마 생성 권한** 필요.
- 브로커도 외부면 `INSTALL_REDIS=false` + `REDIS_HOST` 외부 지정(Phase2 연계).

### 12.5 실행 순서(일반화)
```
00-repo.sh
01-os-packages.sh            # DB_MODE/INSTALL_REDIS 에 따라 패키지 가감
06-selinux.sh                # INSTALL_ROOT!=/opt 일 때만 작동
02-venv-offline.sh
# DB:
03-postgres.sh               # DB_MODE=local
#   또는
03b-db-external.sh           # DB_MODE=external
04-redis.sh                  # INSTALL_REDIS=true 일 때만
05-airflow-init.sh           # cfg/migrate/admin/systemd(변수 렌더링)
```

### 12.6 구성 예시
```bash
# 예) /app 경로 + 기존계정 svc_airflow + 외부 관리형 PostgreSQL(SSL)
export INSTALL_ROOT=/app
export AIRFLOW_USER=svc_airflow AIRFLOW_GROUP=svc_airflow CREATE_USER=false
export DB_MODE=external PG_HOST=pg.db.internal PG_PORT=5432 \
       PG_DB=airflow PG_USER=airflow PG_PASSWORD='***' PG_SSLMODE=require
# (DB/롤을 우리가 만들어야 하면) PG_ADMIN_USER/PG_ADMIN_PASSWORD 추가
```

### 12.7 비고 / 주의
- 현재 가동 중인 노드(192.168.122.62)는 `/opt`+로컬PG로 이미 설치됨. 위 일반화는 **신규/재배포**에 적용.
  경로/DB를 바꾸려면 **새 값으로 재설치**가 깔끔(기존 venv·DB 이전은 별도 마이그레이션 작업).
- wheelhouse(빌드 산출물)는 경로·계정·DB 모드와 **무관** — 재빌드 불필요, 그대로 재사용.

---

## 13. airflow.cfg / 비밀(secret) 처리

`05-airflow-init.sh`가 **설정과 비밀을 분리**해 생성한다.

| 파일 | 내용 | 권한 |
|---|---|---|
| `${AIRFLOW_HOME}/airflow.cfg` | 비밀 **제외** 설정(executor/경로/포트 등 최소셋) | 640 `airflow:grp` |
| `${AIRFLOW_HOME}/airflow-secrets.env` | 모든 비밀을 `AIRFLOW__SECTION__KEY` 환경변수로 | **600** `airflow:grp` |

비밀 항목(env): `SQL_ALCHEMY_CONN`(DB비번 포함), `FERNET_KEY`, `WEBSERVER__SECRET_KEY`,
`CELERY__BROKER_URL`, `CELERY__RESULT_BACKEND`. Airflow는 env(`AIRFLOW__*`)가 cfg보다 우선.

### ① 키 영속화
fernet/secret 키 결정 우선순위: **env 주입(`AF_FERNET_KEY`/`AF_SECRET_KEY`) > 기존 secrets파일 재사용 > 신규생성**.
- 재실행해도 키 동일 유지(검증: fernet 앞8 `Ctnmrxb4` 동일) → 기존 암호화 Connection/Variable 보존.
- **다중노드(Phase2)**: `airflow-secrets.env`를 워커에 배포(또는 동일 `AF_*_KEY` 주입)하면 전 노드 키 일치.

### ② cfg 멱등
`airflow.cfg` 존재 시 `airflow.cfg.bak.<타임스탬프>` 로 **백업 후 재생성**(수정본 유실 방지, 검증: 재실행마다 `.bak` 누적).

### ③ 비밀 분리(주입 경로)
- systemd: 유닛에 `EnvironmentFile=` 2개(`airflow.env`=AIRFLOW_HOME, `airflow-secrets.env`=비밀).
- CLI(db migrate 등): `run_af()` 가 secrets를 `source` 로 주입 — **`ps` 인자 노출 없음**.
- cfg에는 평문 비밀이 남지 않음(검증: `grep password|fernet|secret_key|sql_alchemy_conn` → 주석만 매칭).

### 주의
- secrets 값은 **공백 없는 값** 전제(systemd EnvironmentFile/bash source 호환). 공백 포함 비번은 인용 처리 필요.
- 인라인-cfg(구버전)→env 전환 시 **기존 cfg의 키를 추출해 `AF_*_KEY`로 주입**해야 키 보존(이번 마이그레이션에 적용).

## 11-A. 구축 결과 (AS-BUILT, 2026-06-26, 192.168.122.62 단일노드)

| 항목 | 결과 |
|---|---|
| Airflow | 2.11.0 (LocalExecutor), venv `/opt/airflow/venv` |
| wheelhouse | 163 wheel, 60MB, `--no-index` 오프라인 설치 성공 |
| PostgreSQL | **13.14** (AppStream 기본 모듈), DB/롤 `airflow` |
| Redis | 6.2.7 (127.0.0.1:6379, Phase2 대비) |
| 서비스 | postgresql/redis/airflow-scheduler/airflow-webserver 모두 active |
| 검증 | `/health` 200(metadatabase·scheduler healthy), 테스트 DAG 태스크 SUCCESS |
| 접속 | http://192.168.122.62:8080  (admin / `Airflow#Adm2026`) |
| DB 비밀번호 | `Airflow#Pg2026` (운영 전 교체 권장) |

**설계 대비 변경점**
- PostgreSQL은 RHEL AppStream 기본 모듈이라 15가 아닌 **13.14** 설치됨(Airflow 2.11과 호환). 15가 필요하면 `dnf module enable postgresql:15` 후 재설치.
- **pg_hba.conf 수정 필수**: RHEL 기본은 `127.0.0.1/32 ident` 가 먼저 매칭되어 끝에 md5 규칙을 추가해도 무효 → localhost TCP 라인을 `ident`→`md5`로 **교체**해야 함. `03-postgres.sh`에 반영 완료.

## 11. 리스크 / 확인 필요
- **Python 3.9 EOL**: 2025-10 보안지원 종료 예정. 단일 폐쇄망 단기 운영엔 무방하나, 장기 운영은 3.11/3.12 재패키징 권고.
- **constraints의 sdist-only 패키지**: `pip wheel` 단계에서 컨테이너에 빌드툴 필요한 경우 있음 → UBI9/python-39 이미지에 `gcc`/`*-devel` 추가 설치 후 빌드(스크립트에 반영 예정).
- **RHEL repo GPG**: 미러에 GPG 키 존재 여부 확인 후 `gpgcheck` 정책 확정.
- **DAGs 배포 전략(Phase2)**: NFS vs GitOps 결정 필요.
```
```

---

*다음 단계 제안: (1) `build/build-wheelhouse.sh` + `install/*.sh` 스크립트 생성 → (2) wheelhouse 빌드 실행 → (3) 대상 서버 설치. 진행 승인 시 작업 시작.*
