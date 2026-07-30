"""HA 클러스터 워커 분산 실행 검증용 DAG.

의존관계 없는 병렬 태스크를 뿌려 Celery 가 3대 워커에 나눠 배정하는지 확인한다.
Airflow 는 TaskInstance 마다 실제 실행 호스트를 기록하므로, 실행 후 메타DB 를 조회하면
어느 노드에서 돌았는지 정확히 알 수 있다:

    SELECT task_id, hostname, state
      FROM task_instance
     WHERE dag_id = 'ha_worker_distribution_test'
     ORDER BY hostname, task_id;

수동 트리거 전용(schedule=None). 검증이 끝나면 지워도 무방하다.
"""

from datetime import datetime

from airflow import DAG
from airflow.providers.standard.operators.bash import BashOperator

# 3 노드 × worker_concurrency(4) = 12 슬롯. 슬롯 수만큼 뿌리고 잠깐 붙잡아 두면
# 한 워커가 전부 선점하지 못하고 분산된다.
PROBE_COUNT = 12
HOLD_SECONDS = 10

with DAG(
    dag_id="ha_worker_distribution_test",
    description="워커 분산 실행 확인용 스모크 테스트",
    start_date=datetime(2026, 1, 1),
    schedule=None,
    catchup=False,
    tags=["ha", "smoke"],
) as dag:
    for i in range(1, PROBE_COUNT + 1):
        BashOperator(
            task_id=f"probe_{i:02d}",
            bash_command=(
                f'echo "probe={i:02d} host=$(hostname -f) pid=$$"; '
                f"sleep {HOLD_SECONDS}"
            ),
        )
