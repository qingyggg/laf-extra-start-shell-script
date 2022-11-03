#!/usr/bin/env sh
# Usage:
# - sh start_vm.sh
# - sh start_vm.sh laf-dev ~/.kube/config

NAME="laf-dev"
# if set first param in command line
if [ -n "$1" ]; then
    NAME="$1"
fi

#BASE_DIR=$(pwd)/$(dirname "$0")
KUBECONF=$(pwd)/.kube/config

# if set second param in command line, use it as KUBECONF_DIR
if [ -n "$2" ]; then
    KUBECONF="$2"
fi

KUBECONF_DIR=$(dirname "$KUBECONF")
set -e
# check if .kube path is exist
if [ ! -d "$KUBECONF_DIR" ]; then
    mkdir "$KUBECONF_DIR"
    echo "$KUBECONF_DIR created"
fi

# check if multipass is installed(faild excute in Ubuntu)
# if ! command -v multipass &> /dev/null
# then
#     echo "ERROR: multipass could not be found, please install it first. @see https://multipass.run/install"
#     exit 1
# fi


#in linux(has tested in Ubuntu22)
if !  [ -x "$(command -v multipass)" ];
then
    echo "ERROR: multipass could not be found, please install it first. @see https://multipass.run/install"
    exit 1
fi

# delete the vm if it already exists
if multipass list | grep -e "^$NAME "; then
    echo "Deleting the existing vm $NAME"
    multipass delete -p "$NAME"
fi

echo "Creating VM..."
echo "\tmultipass launch --name $NAME --cpus 2 --mem 4G --disk 20G"
multipass launch --name "$NAME" --cpus 2 --mem 4G --disk 20G
# shellcheck disable=SC2181
if [ $? -eq 0 ]; then
    echo "vm is created"
else
    echo "ERROR: failed to create vm, please retry"
    exit 1
fi

# shellcheck disable=SC2139


#if you use bash(not zsh) to source this file
#You may encounter an error that `m_root_exec command not found `,you can cancel the following command to fix this problem
# other wise,you should set command on the following line
#why should do this: https://fog.ccsf.edu/~gboyd/cs160b/shotts/8-advanced/shopt.html
# shopt -s expand_aliases

alias vm_root_exec="multipass exec $NAME -- sudo -u root"

echo "Installing sealos..."
set -x
vm_root_exec -s << EOF
echo "deb [trusted=yes] https://apt.fury.io/labring/ /" | tee /etc/apt/sources.list.d/labring.list
apt update
sudo apt install sealos=4.1.3
EOF

arch=$(arch | sed s/aarch64/arm64/ | sed s/x86_64/amd64/)

vm_root_exec echo "download buildah in https://github.com/labring/cluster-image/releases/download/depend/buildah.linux.${arch}"
vm_root_exec wget -qO "buildah" "https://github.com/labring/cluster-image/releases/download/depend/buildah.linux.${arch}"
vm_root_exec chmod a+x buildah
vm_root_exec mv buildah /usr/bin

set +x

echo "Installing k8s..."
set -x

# vm_root_exec sealos run labring/kubernetes:v1.24.0  labring/calico:v3.24.1 --single
vm_root_exec sealos run labring/kubernetes:v1.24.0 labring/flannel:v0.19.0 --single
vm_root_exec kubectl taint node $NAME node-role.kubernetes.io/master-
vm_root_exec kubectl taint node $NAME node-role.kubernetes.io/control-plane-
set +x
set +e

i=0
while true; do
    echo "Waiting for k8s cluster ready..."
    state=$(vm_root_exec kubectl get nodes | grep Ready | awk '{print $2}')
    if [ "$state" = "Ready" ]; then
        break
    fi
    i=$((i+1))
    if [ $i -gt 30 ]; then
        echo "ERROR: k8s cluster is not ready"
        exit 1
    fi
    sleep 6
done

echo "k8s cluster is ready."

vm_root_exec sealos run labring/helm:v3.8.2
vm_root_exec sealos run labring/openebs:v1.9.0
vm_root_exec sealos run labring/cert-manager:v1.8.0

# create the nessary secret config
cat << EOF | kubectl apply -f -
apiVersion: v1
kind: Secret
metadata:
  name: payment-secret
  namespace: user-system 
type: Opaque
data:
  MchID: MTYyNzUwMjQwMg==
  AppID: d3g1OTRjNTI3OWI1ZmY0NjY3
  MchAPIv3Key: c3owZWg3MmVxZmw0dDk5OGdiMTlxdjBkdjBlM2VxY2c=
  MchCertificateSerialNumber: NTdGMkM0QTAyOTdFQTVFNTE0REM1OUY0QzNCNzU2Qzc3OTYyMzM1MA==
  WechatPrivateKey: c3owZWg3MmVxZmw0dDk5OGdiMTlxdjBkdjBlM2VxY2c=
EOF

#this need to set proxy
vm_root_exec sealos run docker.io/labring/user-controller:dev 


set -x
set -e

multipass exec "$NAME" -- sudo -u root cat /root/.kube/config > "$KUBECONF"

# replace ip address in kubeconf
vm_ip=$(multipass info "$NAME" | grep IPv4: | awk '{print $2}')
sed -i -e "s/apiserver.cluster.local/$vm_ip/g" "$KUBECONF"
set +x

