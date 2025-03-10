#!/bin/bash -euvx

# shellcheck disable=SC1091

. ../common/prepare.sh

export QM_HOST_REGISTRY_DIR="/var/qm/lib/containers/registry"
export QM_REGISTRY_DIR="/var/lib/containers/registry"
export NUMBER_OF_NODES="${NUMBER_OF_NODES:-2}"
WAIT_BLUECHI_AGENT_CONNECT="${WAIT_BLUECHI_AGENT_CONNECT:-5}"

setup_test_containers_in_qm() {

    #Prepare quadlet files for testing containers
    for ((i=1;i<=NUMBER_OF_NODES;i++)); do
        info_message "setup_test_containers_in_qm(): prepare quadlet files for bluechi-tester-${i}.container"
        cat >> "/etc/qm/containers/systemd/bluechi-tester-${i}.container" <<EOF
[Unit]
Description=bluechi-tester-X
After=local-fs.target

[Container]
Image=dir:/var/lib/containers/registry/tools-ffi:latest
Exec=/root/tests/FFI/bin/bluechi-tester --url="tcp:host=localhost,port=842" \
     --nodename=bluechi-tester-X \
     --numbersignals=11111111 \
     --signal="JobDone"
Network=host
EOF
        sed -i -e "s/tester-X/tester-${i}/g" "/etc/qm/containers/systemd/bluechi-tester-${i}.container"

        info_message "setup_test_containers_in_qm(): updating AllowedNodeNames in /etc/bluechi/controller.conf"
        #Update controller configuration
        sed -i -e '/^AllowedNodeNames=/ s/$/,bluechi-tester-'"${i}"'/' /etc/bluechi/controller.conf

        info_message "setup_test_containers_in_qm(): bluechi-controller reload & restart"
        #Reload bluechi-controller
        exec_cmd "systemctl daemon-reload"
        exec_cmd "systemctl restart bluechi-controller"

    done

    #Restart bluechi-agent for clean connection logs
    exec_cmd "systemctl restart bluechi-agent"
    sleep "${WAIT_BLUECHI_AGENT_CONNECT}"
    if [ "$(systemctl is-active bluechi-agent)" != "active" ]; then
        info_message "setup_test_containers_in_qm(): bluechi-agent is not active"
        exit 1
    fi
}

run_test_containers(){
    for ((i=1;i<=NUMBER_OF_NODES;i++)); do
        #Reload bluechi-testers in qm
        info_message "run_test_containers(): bluechi-tester-${i} reload & restart"
        exec_cmd "podman exec qm systemctl daemon-reload"
        exec_cmd "podman exec qm systemctl restart bluechi-tester-${i}"
    done
}

disk_cleanup
prepare_test
reload_config
prepare_images

#Stop QM bluechi-agent
exec_cmd "podman exec -it qm /bin/bash -c \
         \"systemctl stop bluechi-agent\""

#Prepare quadlet files for testing containers
setup_test_containers_in_qm
#Run containers through systemd
run_test_containers

#Check both tests services are on
for ((i=1;i<=NUMBER_OF_NODES;i++)); do
    if [ "$(podman exec qm systemctl is-active bluechi-tester-"${i}")" != "active" ]; then
        info_message "test() bluechi-tester-${i} is not active"
        exit 1
    fi
done

#check ASIL bluechi-agent is connected
connection_cnt="$(grep -e Connected -e "'localrootfs'" \
    -oc <<< "$(systemctl status -l --no-pager bluechi-agent)")"
if [ "${connection_cnt}" -ne 1 ]; then
    info_message "test() expects ASIL bluechi-agent connection not disturbed"
    agent_log="$(grep "bluechi-agent\[.*\]:" <<< "$(systemctl status -l --no-pager bluechi-agent)")"
    info_message "test() agent logs..."
    info_message "test() ${agent_log}"
    info_message "test() number of connections found ${connection_cnt}"
    exit "${connection_cnt}"
fi
