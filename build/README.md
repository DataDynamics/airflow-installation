# build/ — wheelhouse 빌드 & airgap 번들 패키징

인터넷이 되는 **빌드머신**에서 실행하는 스크립트. PyPI에서 Airflow 의존성을 모아
RHEL 9.4 / Python 3.9 호환 **wheel**로 만들고(`build-wheelhouse-*.sh`), 설치 스크립트까지
합쳐 **단일 airgap 번들**로 묶는다(`package.sh`). 산출물을 폐쇄망으로 옮겨 설치한다.

```
build-wheelhouse-docker.sh  ┐
   또는                       ├─> artifacts/wheelhouse/*.whl (+constraints)
build-wheelhouse-rhel.sh    ┘            │
package.sh ────────────────────> dist/airflow-<버전>-airgap-bundle.tar.gz (+ .sha256)
```

> **명명 규칙**: 빌드 방식별로 접미사를 둔다. docker 기반 = `*-docker.sh`, RHEL 네이티브 = `*-rhel.sh`.
> 두 변형은 **동일한 산출물**(`artifacts/wheelhouse` + `constraints-3.9.txt`)을 만들며, 이후 `package.sh`는 공통이다.

---

## 어느 빌드 변형을 쓸까?

| | `build-wheelhouse-docker.sh` | `build-wheelhouse-rhel.sh` |
|---|---|---|
| 실행 환경 | docker 되는 아무 OS(예: Ubuntu) | **RHEL 9.4(또는 Rocky/Alma 9)** 빌드머신 |
| Python | 컨테이너 `ubi9/python-39` | **시스템 python3.9** |
| 격리 | 컨테이너 | `artifacts/.buildvenv`(임시 venv, 종료 시 삭제) |
| ABI 정합 | RHEL9와 동일(ubi9) | 대상과 **동일 OS**라 가장 정합 |
| 적합 상황 | RHEL 빌드머신이 없을 때 | RHEL 9.4 빌드머신이 이미 있을 때(docker 불필요) |

둘 다 대상(RHEL 9.4 / Py 3.9)에서 그대로 설치되는 wheel을 만든다. **편한 쪽 하나만** 실행하면 된다.

---

## 사전 요구사항 (공통)
- **인터넷 연결** (PyPI / GitHub raw)
- 디스크 여유 ~2GB, x86_64
- 추가:
  - docker 변형: `docker info` 성공. 이미지 `registry.access.redhat.com/ubi9/python-39`(공개, 자동 pull)
  - rhel 변형: RHEL 9 계열 + `python3`(3.9). 빌드 도구(`gcc`,`python3-devel`,`libpq-devel`)는 스크립트가 `dnf`로 설치 시도(실패해도 대부분 manylinux wheel이라 진행). dnf 설치엔 root/sudo 필요.

---

## 1) `build-wheelhouse-docker.sh` / `build-wheelhouse-rhel.sh`

Airflow + extras 전체를 **바이너리 wheel**로 빌드/수집한다(대상에서 컴파일 0이 목표).

### 사용
```bash
./build/build-wheelhouse-docker.sh     # docker 기반
# 또는
./build/build-wheelhouse-rhel.sh       # RHEL 9.4 네이티브
```

### 환경변수 (두 변형 공통)
| 변수 | 기본값 | 설명 |
|---|---|---|
| `AF_VERSION` | `2.11.0` | Airflow 버전 (constraints도 이 버전으로 매칭) |
| `EXTRAS` | `celery,postgres,redis` | 설치 extras |
| `PY_TAG` | `3.9` (고정) | 대상 Python — 이미지/시스템 Python과 일치해야 함 |

### 산출물 (`artifacts/`)
- `artifacts/wheelhouse/*.whl` — 전체 wheel (예: 163개)
- `artifacts/constraints-3.9.txt` — 적용된 공식 constraints
- `artifacts/airflow-<AF_VERSION>-py3.9-airgap.tar.gz` (+`.sha256`) — wheelhouse만 묶은 보조 산출물

### 예시
```bash
AF_VERSION=2.11.0 EXTRAS="celery,postgres,redis" ./build/build-wheelhouse-rhel.sh
```

---

## 2) `package.sh` (공통)

wheelhouse 산출물 + `install/` 스크립트 + `DESIGN.md` + `MANIFEST.txt`를
**서버 업로드용 단일 번들**로 묶는다.

### 사전조건
- 위 빌드 변형 중 하나를 먼저 실행해 `artifacts/wheelhouse`가 있어야 함(없으면 에러 중단).

### 사용
```bash
./build/package.sh
```

### 환경변수
| 변수 | 기본값 | 설명 |
|---|---|---|
| `AIRFLOW_VERSION` | `2.11.0` | 번들 파일명/매니페스트 버전 (※ 빌드의 `AF_VERSION`과 동일하게 맞출 것) |

### 산출물 (`dist/`)
- `dist/airflow-<AIRFLOW_VERSION>-airgap-bundle.tar.gz` (+`.sha256`)
- 번들 내부 레이아웃:
  ```
  airflow-airgap/
    install/              설치 스크립트(00~06, install-all.sh, env.sh, gen-cluster-keys.sh, 99-teardown.sh)
    wheelhouse/           오프라인 wheel
    constraints-3.9.txt
    DESIGN.md
    MANIFEST.txt          구성·설치 절차 안내
  ```

---

## 전체 빌드 흐름
```bash
# 빌드머신 (인터넷) — 변형 택1
./build/build-wheelhouse-docker.sh    # 또는 build-wheelhouse-rhel.sh
./build/package.sh                    # 단일 번들 생성

# 검증(선택): 깨끗한 컨테이너에서 오프라인 설치 리허설
docker run --rm -v "$PWD/artifacts:/out:ro" registry.access.redhat.com/ubi9/python-39 \
  bash -lc 'python -m venv /tmp/v && /tmp/v/bin/pip install --no-index \
    --find-links /out/wheelhouse -c /out/constraints-3.9.txt \
    "apache-airflow[celery,postgres,redis]==2.11.0" && /tmp/v/bin/airflow version'

# airgap 경계로 전송
scp dist/airflow-2.11.0-airgap-bundle.tar.gz* root@<server>:/opt/
```
이후 대상 서버 설치는 [`../install/`](../install) / [`../README.md`](../README.md) 참고.

---

## 참고 / 주의
- `artifacts/`, `dist/`는 `.gitignore` 대상(번들은 커밋하지 않음).
- 번들은 설치 경로/계정/DB 모드/역할과 **무관** — 한 번 빌드해 모든 구성에 재사용.
- `AF_VERSION`(빌드)과 `AIRFLOW_VERSION`(패키징)을 서로 다르게 주면 파일명이 어긋나니 동일하게.
- rhel 변형은 RHEL 9 계열/Python 3.9가 아니면 경고를 출력한다(ABI 불일치 위험).
