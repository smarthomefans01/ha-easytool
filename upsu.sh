#!/bin/sh
# shellcheck disable=SC1091
# ==============================================================================
# Supervisor Docker容器与中国Docker注册表镜像配置
# ==============================================================================
set -e

systemctl stop hassio-supervisor.service
systemctl stop hassio-apparmor.service
echo "已停止Supervisor服务."

systemctl disable hassio-supervisor.service
systemctl disable hassio-apparmor.service
echo "已禁止Supervisor自动启动."

echo "检查并停止/删除hassio_supervisor容器"
read -p "继续操作吗？(y/n): " confirm
if [[ $confirm != "y" && $confirm != "Y" ]]; then
    echo "已取消操作."
    exit 0
fi
if docker ps -a --format "{{.Names}}" | grep -q "hassio_supervisor"; then
    echo "停止hassio_supervisor容器..."
    docker stop hassio_supervisor
    echo "已停止hassio_supervisor容器."
    
    echo "删除hassio_supervisor容器..."
    docker rm hassio_supervisor
    echo "已删除hassio_supervisor容器."
else
    echo "未找到hassio_supervisor容器，无需操作."
fi

# 定义Docker守护进程配置文件路径
DAEMON_JSON_FILE="/etc/docker/daemon.json"

# 读取现有的daemon.json文件并添加registry-mirrors键
if [ -f "$DAEMON_JSON_FILE" ]; then
    # 添加registry-mirrors键并设置所需的镜像URL
    cat <<EOF > "$DAEMON_JSON_FILE"
{
    "log-driver": "journald",
    "storage-driver": "overlay2",
    "ip6tables": true,
    "experimental": true,
    "log-opts": {
        "tag": "{{.Name}}"
    },
    "registry-mirrors": [
        "https://docker.nju.edu.cn"
    ]
}
EOF

    echo "已将中国Docker注册表镜像添加到$DAEMON_JSON_FILE"
else
    echo "错误：$DAEMON_JSON_FILE文件不存在."
fi

# 重启Docker服务以应用更改
sudo systemctl restart docker

# 加载Supervisor配置
CONFIG_FILE=/etc/hassio.json

# 初始化supervisor
SUPERVISOR_DATA="$(jq --raw-output '.data // "/usr/share/hassio"' ${CONFIG_FILE})"
SUPERVISOR_STARTUP_MARKER="/run/supervisor/startup-marker"
SUPERVISOR_STARTSCRIPT_VERSION="${SUPERVISOR_DATA}/supervisor-version"
SUPERVISOR_MACHINE="$(jq --raw-output '.machine' ${CONFIG_FILE})"
SUPERVISOR_IMAGE="smarthomefansbox/aarch64-hassio-supervisor"

SUPERVISOR_IMAGE_ID=$(docker images --no-trunc --filter "reference=${SUPERVISOR_IMAGE}:latest" --format "{{.ID}}" || echo "")
SUPERVISOR_CONTAINER_ID=$(docker inspect --format='{{.Image}}' hassio_supervisor || echo "")

# 检查上次运行是否留下了启动标记。如果是，我们假设容器镜像或容器已损坏。
# 删除容器，删除镜像，拉取新的
if [ -f "${SUPERVISOR_STARTUP_MARKER}" ]; then
    echo "[警告] Supervisor容器没有移除启动标记文件。假设容器镜像或容器已损坏."
    docker container rm --force hassio_supervisor || true
    SUPERVISOR_CONTAINER_ID=""
    # 确保删除所有supervisor镜像
    SUPERVISOR_IMAGE_IDS=$(docker images --no-trunc --filter "reference=${SUPERVISOR_IMAGE}" --format "{{.ID}}" | uniq || echo "")
    docker image rm --force "${SUPERVISOR_IMAGE_IDS}" || true
    SUPERVISOR_IMAGE_ID=""
fi

# 如果缺少Supervisor镜像，拉取它
mkdir -p "$(dirname ${SUPERVISOR_STARTUP_MARKER})"
touch ${SUPERVISOR_STARTUP_MARKER}
if [ -z "${SUPERVISOR_IMAGE_ID}" ]; then
    # 从更新信息中获取最新的
    # 使用更新器信息而不是配置。如果配置版本有问题，这提供了一种方式（例如，错误的发布）。
    SUPERVISOR_VERSION=$(jq -r '.supervisor // "latest"' "${SUPERVISOR_DATA}/updater.json" || echo "latest")

    echo "[警告] 缺少Supervisor镜像，正在下载新的: ${SUPERVISOR_VERSION}"

    # 拉取Supervisor
    if docker pull "${SUPERVISOR_IMAGE}:${SUPERVISOR_VERSION}"; then
        # 如果版本化了，标记为最新
        if [ "${SUPERVISOR_VERSION}" != "latest" ]; then
            docker tag "${SUPERVISOR_IMAGE}:${SUPERVISOR_VERSION}" "ghcr.io/home-assistant/aarch64-hassio-supervisor:${SUPERVISOR_VERSION}"
            # 也标记为ghcr.io的最新
            docker tag "${SUPERVISOR_IMAGE}:${SUPERVISOR_VERSION}" "ghcr.io/home-assistant/aarch64-hassio-supervisor:latest"
        fi
    else
        # 拉取失败，更新器信息可能已损坏，重试最新的
        echo "[警告] Supervisor下载失败，尝试使用: 最新"
        if docker pull "${SUPERVISOR_IMAGE}:latest"; then
            docker tag "${SUPERVISOR_IMAGE}:latest" "ghcr.io/home-assistant/aarch64-hassio-supervisor:latest"
        fi
    fi

    SUPERVISOR_IMAGE_ID=$(docker inspect --format='{{.Id}}' "ghcr.io/home-assistant/aarch64-hassio-supervisor" || echo "")
fi

if [ -n "${SUPERVISOR_CONTAINER_ID}" ]; then
    # 镜像变更，移除之前的容器
    if [ "${SUPERVISOR_IMAGE_ID}" != "${SUPERVISOR_CONTAINER_ID}" ]; then
        echo "[信息] Supervisor镜像已更新，销毁之前的容器..."
        docker container rm --force hassio_supervisor || true
        SUPERVISOR_CONTAINER_ID=""
    fi

    # 启动脚本变更，移除之前的容器
    if [ ! -f "${SUPERVISOR_STARTSCRIPT_VERSION}" ] || [ "${SUPERVISOR_STARTSCRIPT_VERSION}" -nt "$0" ] || [ "${SUPERVISOR_STARTSCRIPT_VERSION}" -ot "$0" ]; then
        echo "[信息] Supervisor启动脚本已更改，销毁之前的容器..."
        docker container rm --force hassio_supervisor || true
        SUPERVISOR_CONTAINER_ID=""
    fi
fi

# 如果缺少Supervisor容器，创建它
if [ -z "${SUPERVISOR_CONTAINER_ID}" ]; then
    echo "[信息] 正在创建新的Supervisor容器..."
    docker container create \
        --name hassio_supervisor \
        --privileged --security-opt apparmor="hassio-supervisor" \
        -v /run/docker.sock:/run/docker.sock:rw \
        -v /run/systemd-journal-gatewayd.sock:/run/systemd-journal-gatewayd.sock:rw \
        -v /run/dbus:/run/dbus:ro \
        -v /run/supervisor:/run/os:rw \
        -v /run/udev:/run/udev:ro \
        -v /etc/machine-id:/etc/machine-id:ro \
        -v ${SUPERVISOR_DATA}:/data:rw,slave \
        -e SUPERVISOR_SHARE=${SUPERVISOR_DATA} \
        -e SUPERVISOR_NAME=hassio_supervisor \
        -e SUPERVISOR_MACHINE=${SUPERVISOR_MACHINE} \
        ghcr.io/home-assistant/aarch64-hassio-supervisor:latest

    # 存储这个脚本的时间戳。如果脚本更改了，自动重新创建容器。
    touch --reference="$0" "${SUPERVISOR_STARTSCRIPT_VERSION}"
fi

# 运行supervisor
mkdir -p ${SUPERVISOR_DATA}

systemctl start hassio-supervisor.service
systemctl start hassio-apparmor.service
echo "已启动加载的镜像."

systemctl enable hassio-supervisor.service
systemctl enable hassio-apparmor.service
echo "已启用自动重启服务."

echo "[信息] 正在启动Supervisor..."
docker container start hassio_supervisor
exec docker container wait hassio_supervisor
