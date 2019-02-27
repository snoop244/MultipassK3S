#!/usr/bin/env bash

# Configure your settings
# Name for the cluster/configuration files
NAME=""
# Ubuntu image to use (xenial/bionic)
IMAGE="xenial"
# How many machines to create
SERVER_COUNT_MACHINE="1"
# How many machines to create
AGENT_COUNT_MACHINE="1"
# How many CPUs to allocate to each machine
CPU_MACHINE="1"
# How much disk space to allocate to each machine
DISK_MACHINE="5G"
# How much memory to allocate to each machine
MEMORY_MACHINE="1G"

## Nothing to change after this line

# Cloud init template
read -r -d '' SERVER_CLOUDINIT_TEMPLATE << EOM
#cloud-config

runcmd:
 - '\curl -sfL https://get.k3s.io | sh -'
EOM

# Cloud init template
read -r -d '' AGENT_CLOUDINIT_TEMPLATE << EOM
#cloud-config

runcmd:
 - '\sudo wget -O /usr/local/bin/k3s https://github.com/rancher/k3s/releases/download/v0.1.0/k3s'
 - '\sudo chmod +x /usr/local/bin/k3s'
 - '\sudo /usr/local/bin/k3s agent -s __SERVER_URL__ -t __NODE_TOKEN__ &'
EOM


if ! [ -x "$(command -v multipass)" > /dev/null 2>&1 ]; then
    echo "The multipass binary is not available or not in your \$PATH"
    exit 1
fi

# Check if name is given or create random string
if [ -z $NAME ]; then
    NAME=$(cat /dev/urandom | base64 | tr -dc 'a-zA-Z0-9' | fold -w 6 | head -n 1 | tr '[:upper:]' '[:lower:]')
    echo "No name given, generated name: ${NAME}"
fi

echo "Creating cluster ${NAME} with ${SERVER_COUNT_MACHINE} servers and ${AGENT_COUNT_MACHINE} agents"

# Prepare cloud-init
echo "$SERVER_CLOUDINIT_TEMPLATE" > "${NAME}-cloud-init.yaml"
echo "Cloud-init is created at ${NAME}-cloud-init.yaml"

for i in $(eval echo "{1..$SERVER_COUNT_MACHINE}"); do
    echo "Running multipass launch --cpus $CPU_MACHINE --disk $DISK_MACHINE --mem $MEMORY_MACHINE $IMAGE --name k3s-server-$NAME-$i --cloud-init ${NAME}-cloud-init.yaml"                                                                                                                                           
    multipass launch --cpus $CPU_MACHINE --disk $DISK_MACHINE --mem $MEMORY_MACHINE $IMAGE --name k3s-server-$NAME-$i --cloud-init "${NAME}-cloud-init.yaml"
    if [ $? -ne 0 ]; then
        echo "There was an error launching the instance"
        exit 1
    fi
done

for i in $(eval echo "{1..$SERVER_COUNT_MACHINE}"); do
    echo "Checking for Node being Ready on k3s-server-${NAME}-${i}"
    multipass exec k3s-server-$NAME-$i -- /bin/bash -c 'while [[ $(k3s kubectl get nodes --no-headers 2>/dev/null | grep -c -v "NotReady") -eq 0 ]]; do sleep 2; done'
    echo "Node is Ready on k3s-server-${NAME}-${i}"
done

# Retrieve info to join agent to cluster
SERVER_IP=$(multipass info k3s-server-$NAME-1 | grep IPv4 | awk '{ print $2 }')
URL="https://${SERVER_IP}:6443"
NODE_TOKEN=$(multipass exec k3s-server-$NAME-1 -- /bin/bash -c 'sudo cat /var/lib/rancher/k3s/server/node-token' | sed 's/.$//')

# Prepare agent cloud-init
echo "$AGENT_CLOUDINIT_TEMPLATE" | sed -e "s^__SERVER_URL__^$URL^" -e "s^__NODE_TOKEN__^$NODE_TOKEN^" > "${NAME}-agent-cloud-init.yaml"
echo "Cloud-init is created at ${NAME}-agent-cloud-init.yaml"

for i in $(eval echo "{1..$AGENT_COUNT_MACHINE}"); do
    echo "Running multipass launch --cpus $CPU_MACHINE --disk $DISK_MACHINE --mem $MEMORY_MACHINE $IMAGE --name k3s-agent-$NAME-$i --cloud-init ${NAME}-agent-cloud-init.yaml"
    multipass launch --cpus $CPU_MACHINE --disk $DISK_MACHINE --mem $MEMORY_MACHINE $IMAGE --name k3s-agent-$NAME-$i --cloud-init "${NAME}-agent-cloud-init.yaml"
    if [ $? -ne 0 ]; then
        echo "There was an error launching the instance"
        exit 1
    fi
    echo "Checking for Node k3s-agent-$NAME-$i being registered"
    multipass exec k3s-server-$NAME-1 -- bash -c "until k3s kubectl get nodes --no-headers | grep -c k3s-agent-$NAME-1 >/dev/null; do sleep 2; done" 
    echo "Checking for Node k3s-agent-$NAME-$i being Ready"
    multipass exec k3s-server-$NAME-1 -- bash -c "until k3s kubectl get nodes --no-headers | grep k3s-agent-$NAME-1 | grep -c -v NotReady >/dev/null; do sleep 2; done" 
    echo "Node k3s-agent-$NAME-$i is Ready on k3s-server-${NAME}-1"
done

multipass exec k3s-server-$NAME-1 -- cat /etc/rancher/k3s/k3s.yaml | sed -e "/^[[:space:]]*server:/ s_:.*_: \"https://$SERVER_IP:6443\"_" > ${NAME}-kubeconfig.yaml

echo "k3s setup finished"
multipass exec k3s-server-$NAME-1 -- k3s kubectl get nodes
echo "You can now use the following command to connect to your cluster"
echo "multipass exec k3s-server-${NAME}-1 -- k3s kubectl get nodes"
echo "Or use kubectl directly"
echo "kubectl --kubeconfig ${NAME}-kubeconfig.yaml get nodes"