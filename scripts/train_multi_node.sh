
# export WANDB_BASE_URL=https://api.bandw.top
export WANDB_BASE_URL=http://47.251.42.82:8080
export WANDB_API_KEY=fed2085defe840fda97b44d017cd7c5426903a4b
export HF_DATASETS_CACHE="/user/ranchizhao/models/datasets"
export HF_HOME="/user/ranchizhao/models/"

WORLD_SIZE=${WORLD_SIZE:-1}
RANK=${RANK:-0}
MASTER_ADDR=${MASTER_ADDR:-"localhost"}
MASTER_PORT=${MASTER_PORT:-12348}
GPUS_PER_NODE=${GPUS_PER_NODE:-8}
CPUS_PER_TASK=80

echo "MASTER_ADDR: $MASTER_ADDR"
echo "MASTER_PORT: $MASTER_PORT"
echo "GPUS_PER_NODE: $GPUS_PER_NODE"
echo "CPUS_PER_TASK: $CPUS_PER_TASK"
echo "WORLD_SIZE: $WORLD_SIZE"
echo "RANK: $RANK"

while getopts "b:d:" opt; do
    case $opt in
        b)
            bash_file=$OPTARG
            ;;
        d)
            dist_flag=$OPTARG
            ;;
        \?)
            echo "Invalid option: -$OPTARG"
            exit 1
            ;;
    esac
done

# Multi-node launch (migrated from train_qwen2vl.sh:180-210)
if [ "$dist_flag" = "1" ]; then
    if [ -z "${bash_file}" ]; then
        echo "Error: missing training script. Use -b <bash_file>"
        exit 1
    fi

    if ! command -v ray >/dev/null 2>&1; then
        echo "Error: ray is not installed or not in PATH"
        exit 1
    fi

    if [ "$RANK" = "0" ]; then
        echo "Starting Ray head node on $MASTER_ADDR"
        if [ -f "./ray_runtime_env.json" ]; then
            RAY_RUNTIME_ENV_JSON=$(cat ./ray_runtime_env.json) ray start --head \
                --port=$MASTER_PORT \
                --num-cpus="${CPUS_PER_TASK}" \
                --num-gpus=${GPUS_PER_NODE} \
                --verbose \
                --block &
        else
            ray start --head \
                --port=$MASTER_PORT \
                --num-cpus="${CPUS_PER_TASK}" \
                --num-gpus=${GPUS_PER_NODE} \
                --verbose \
                --block &
        fi

        # Wait for Ray to be ready (up to ~120s)
        for i in $(seq 1 30); do
            if ray status --address="${MASTER_ADDR}:${MASTER_PORT}" >/dev/null 2>&1; then
                break
            fi
            sleep 4
        done

        ray status --address="${MASTER_ADDR}:${MASTER_PORT}" || echo "Warning: ray status not ready; proceeding anyway"

        # Verify expected workers joined before launching training
        expected_nodes=${WORLD_SIZE:-1}
        echo "Waiting for ${expected_nodes} Ray nodes to join (including head)..."
        connected_nodes=0
        for i in $(seq 1 60); do
            connected_nodes=$(python3 /user/hezhihui/projects/verl_mm/scripts/ray_cluster_tools.py count --address "${MASTER_ADDR}:${MASTER_PORT}" 2>/dev/null | grep -oE '[0-9]+' | tail -1 || echo 0)
            echo "Ray nodes connected: $connected_nodes / $expected_nodes"
            if [ "$connected_nodes" -ge "$expected_nodes" ]; then
                break
            fi
            sleep 2
        done

        echo "Ray nodes connected: $connected_nodes / $expected_nodes"
        if [ "$connected_nodes" -lt "$expected_nodes" ]; then
            echo "Warning: Not all Ray nodes joined. Set ENFORCE_RAY_NODES=1 to fail."
            if [ "${ENFORCE_RAY_NODES}" = "1" ]; then
                echo "Exiting due to insufficient nodes."
                exit 2
            fi
        fi

        # Print node details
        python3 /user/hezhihui/projects/verl_mm/scripts/ray_cluster_tools.py list --address "${MASTER_ADDR}:${MASTER_PORT}" || true

        # Export address for Ray CLI (no scheme)
        export RAY_ADDRESS="${MASTER_ADDR}:${MASTER_PORT}"

        set -x
        bash "$bash_file"
    else
        echo "Starting Ray worker node; connecting to $MASTER_ADDR:$MASTER_PORT"
        sleep 10
        if [ -f "./ray_runtime_env.json" ]; then
            RAY_RUNTIME_ENV_JSON=$(cat ./ray_runtime_env.json) ray start --address="$MASTER_ADDR:$MASTER_PORT" \
                --num-cpus="${CPUS_PER_TASK}" \
                --verbose \
                --block
        else
            ray start --address="$MASTER_ADDR:$MASTER_PORT" \
                --num-cpus="${CPUS_PER_TASK}" \
                --verbose \
                --block
        fi
    fi
else
    set -x
    bash $bash_file
fi