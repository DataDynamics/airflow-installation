"""페일오버 중에도 태스크 실행이 이어지는지 확인하는 DAG.

`ha_worker_distribution_test` 보다 오래 돌도록 만들어(2 웨이브 × 25초 ≈ 60초),
실행 도중에 Patroni switchover / Redis master 종료 / 노드 정지를 일으킬 시간을 준다.

    ansible-playbook playbooks/deploy-dags.yml
    airflow dags trigger ha_failover_test
    # 실행 중에 장애 주입 → 완료 후 아래로 결과 확인

    SELECT hostname, state, count(*)
      FROM task_instance
     WHERE dag_id = 'ha_failover_test'
     GROUP BY hostname, state;
"""

from datetime import datetime

from airflow import DAG
from airflow.providers.standard.operators.bash import BashOperator

# 3 노드 × worker_concurrency(4) = 12 슬롯. 그 두 배를 뿌려 2 웨이브로 돌린다.
PROBE_COUNT = 24
HOLD_SECONDS = 25

with DAG(
    dag_id="ha_failover_test",
    description="페일오버 중 태스크 실행 지속 확인",
    start_date=datetime(2026, 1, 1),
    schedule=None,
    catchup=False,
    tags=["ha", "failover"],
) as dag:
    for i in range(1, PROBE_COUNT + 1):
        BashOperator(
            task_id=f"probe_{i:02d}",
            bash_command=(
                f'echo "probe={i:02d} host=$(hostname -f) start=$(date -Is)"; '
                f"sleep {HOLD_SECONDS}"
            ),
        )
