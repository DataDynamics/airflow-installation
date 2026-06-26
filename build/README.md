# build/ — wheelhouse 빌드 & airgap 번들 패키징

인터넷이 되는 **빌드머신**에서 실행하는 스크립트. PyPI에서 Airflow 의존성을 모아
RHEL 9.4 / Python 3.9 호환 **wheel**로 만들고(`build-wheelhouse.sh`), 설치 스크립트까지
합쳐 **단일 airgap 번들**로 묶는다(`package.sh`). 산출물을 폐쇄망으로 옮겨 설치한다.

```
build-wheelhouse.sh ──> artifacts/wheelhouse/*.whl (+constraints)
                                  │
package.sh ───────────> dist/airflow-<버전>-airgap-bundle.tar.gz (+ .sha256)
```

---

## 사전 요구사항 (빌드머신)
- **인터넷 연결** (PyPI / GitHub raw / Red Hat 레지스트리 접근)
- **Docker** 실행 가능 (`docker info` 성공)
- 디스크 여유 ~2GB, x86_64
- 이미지: `registry.access.redhat.com/ubi9/python-39` (공개, 인증 불필요) — 자동 pull

> 왜 컨테이너인가: 컴파일된 wheel은 glibc/Python 버전에 묶인다. 대상(RHEL 9.4 / Py 3.9)과
> ABI가 동일한 `ubi9/python-39` 안에서 빌드해야 폐쇄망에서 그대로 설치된다.

---

## 1) `build-wheelhouse.sh`

Airflow + extras 전체를 **바이너리 wheel**로 빌드/수집한다(대상에서 컴파일 0이 목표).

### 사용
```bash
./build/build-wheelhouse.sh
```

### 환경변수 (override)
| 변수 | 기본값 | 설명 |
|---|---|---|
| `AF_VERSION` | `2.11.0` | Airflow 버전 (constraints도 이 버전으로 매칭) |
| `EXTRAS` | `celery,postgres,redis` | 설치 extras |
| `PY_TAG` | `3.9` (고정) | 대상 Python — 컨테이너 이미지와 일치해야 함 |

### 산출물 (`artifacts/`)
- `artifacts/wheelhouse/*.whl` — 전체 wheel (예: 163개)
- `artifacts/constraints-3.9.txt` — 적용된 공식 constraints
- `artifacts/airflow-<AF_VERSION>-py3.9-airgap.tar.gz` (+`.sha256`) — wheelhouse만 묶은 보조 산출물

### 예시
```bash
AF_VERSION=2.11.0 EXTRAS="celery,postgres,redis" ./build/build-wheelhouse.sh
```

---

## 2) `package.sh`

`build-wheelhouse.sh` 산출물 + `install/` 스크립트 + `DESIGN.md` + `MANIFEST.txt`를
**서버 업로드용 단일 번들**로 묶는다.

### 사전조건
- 먼저 `build-wheelhouse.sh`를 실행해 `artifacts/wheelhouse`가 있어야 함
  (없으면 에러로 중단).

### 사용
```bash
./build/package.sh
```

### 환경변수 (override)
| 변수 | 기본값 | 설명 |
|---|---|---|
| `AIRFLOW_VERSION` | `2.11.0` | 번들 파일명/매니페스트 버전 (※ `build-wheelhouse.sh`의 `AF_VERSION`과 동일하게 맞출 것) |

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
# 빌드머신 (인터넷)
./build/build-wheelhouse.sh        # 1) wheel 수집/빌드
./build/package.sh                 # 2) 단일 번들 생성

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
