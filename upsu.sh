#!/bin/sh
# shellcheck disable=SC1091
# ==============================================================================
# Supervisor Docker container
# ==============================================================================
set -e

# Load configs
CONFIG_FILE=/etc/hassio.json

# Init supervisor
SUPERVISOR_DATA="$(jq --raw-output '.data // "/usr/share/hassio"' ${CONFIG_FILE})"
SUPERVISOR_STARTUP_MARKER="/run/supervisor/startup-marker"
SUPERVISOR_STARTSCRIPT_VERSION="${SUPERVISOR_DATA}/supervisor-version"
SUPERVISOR_MACHINE="$(jq --raw-output '.machine' ${CONFIG_FILE})"
SUPERVISOR_IMAGE="$(jq --raw-output '.supervisor' ${CONFIG_FILE})"

SUPERVISOR_IMAGE_ID=$(docker images --no-trunc --filter "reference=${SUPERVISOR_IMAGE}:latest" --format "{{.ID}}" || echo "")
SUPERVISOR_CONTAINER_ID=$(docker inspect --format='{{.Image}}' hassio_supervisor || echo "")

# Check if previous run left the startup-marker in place. If so, we assume the
# Container image or container is somehow corrupted.
# Delete the container, delete the image, pull a fresh one
if [ -f "${SUPERVISOR_STARTUP_MARKER}" ]; then
    echo "[WARNING] Supervisor container did not remove the startup marker file. Assuming container image or container corruption."
    docker container rm --force hassio_supervisor || true
    SUPERVISOR_CONTAINER_ID=""
    # Make sure we delete all supervisor images
    SUPERVISOR_IMAGE_IDS=$(docker images --no-trunc --filter "reference=${SUPERVISOR_IMAGE}" --format "{{.ID}}" | uniq || echo "")
    docker image rm --force "${SUPERVISOR_IMAGE_IDS}" || true
    SUPERVISOR_IMAGE_ID=""
fi

# If Supervisor image is missing, pull it
mkdir -p "$(dirname ${SUPERVISOR_STARTUP_MARKER})"
touch ${SUPERVISOR_STARTUP_MARKER}
if [ -z "${SUPERVISOR_IMAGE_ID}" ]; then
    # Get the latest from update information
    # Using updater information instead of config. If the config version is
    # broken, this creates a way (e.g., bad release).
    SUPERVISOR_VERSION=$(jq -r '.supervisor // "latest"' "${SUPERVISOR_DATA}/updater.json" || echo "latest")

    echo "[WARNING] Supervisor image missing, downloading a fresh one: ${SUPERVISOR_VERSION}"

    # Pull in the Supervisor
    if docker pull "${SUPERVISOR_IMAGE}:${SUPERVISOR_VERSION}"; then
        # Tag as latest if versioned
        if [ "${SUPERVISOR_VERSION}" != "latest" ]; then
            docker tag "${SUPERVISOR_IMAGE}:${SUPERVISOR_VERSION}" "${SUPERVISOR_IMAGE}:latest"
        fi
    else
        # Pull failed, updater info might be corrupted, re-trying with latest
        echo "[WARNING] Supervisor downloading failed trying: latest"
        docker pull "${SUPERVISOR_IMAGE}:latest"
    fi

    SUPERVISOR_IMAGE_ID=$(docker inspect --format='{{.Id}}' "${SUPERVISOR_IMAGE}" || echo "")
fi

if [ -n "${SUPERVISOR_CONTAINER_ID}" ]; then
    # Image changed, remove previous container
    if [ "${SUPERVISOR_IMAGE_ID}" != "${SUPERVISOR_CONTAINER_ID}" ]; then
        echo "[INFO] Supervisor image has been updated, destroying previous container..."
        docker container rm --force hassio_supervisor || true
        SUPERVISOR_CONTAINER_ID=""
    fi

    # Start script changed, remove previous container
    # shellcheck disable=SC3013
    if [ ! -f "${SUPERVISOR_STARTSCRIPT_VERSION}" ] || [ "${SUPERVISOR_STARTSCRIPT_VERSION}" -nt "$0" ] || [ "${SUPERVISOR_STARTSCRIPT_VERSION}" -ot "$0" ]; then
        echo "[INFO] Supervisor start script has changed, destroying previous container..."
        docker container rm --force hassio_supervisor || true
        SUPERVISOR_CONTAINER_ID=""
    fi
fi

# If Supervisor container is missing, create it
if [ -z "${SUPERVISOR_CONTAINER_ID}" ]; then
    echo "[INFO] Creating a new Supervisor container..."
    # shellcheck disable=SC2086
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
        "${SUPERVISOR_IMAGE}:latest"

    # Store the timestamp of this script. If the script changed, let's
    # recreate the container automatically.
    touch --reference="$0" "${SUPERVISOR_STARTSCRIPT_VERSION}"
fi

# Run supervisor
mkdir -p ${SUPERVISOR_DATA}
echo "[INFO] Starting the Supervisor..."
docker container start hassio_supervisor
exec docker container wait hassio_supervisor
