#!/bin/bash
 
cd /home/ubuntu/
ACTIVATIONURL='dsm://agents.deepsecurity.trendmicro.com:443/'
MANAGERURL='https://app.deepsecurity.trendmicro.com:443'
CURLOPTIONS='--silent --tlsv1.2'
linuxPlatform='';
isRPM='';
 
if [[ $(/usr/bin/id -u) -ne 0 ]]; then
    echo You are not running as the root user.  Please try again with root privileges.;
    logger -t You are not running as the root user.  Please try again with root privileges.;
    exit 1;
fi;
 
if ! type curl >/dev/null 2>&1; then
    echo "Please install CURL before running this script."
    logger -t Please install CURL before running this script
    exit 1
fi
 
CURLOUT=$(eval curl $MANAGERURL/software/deploymentscript/platform/linuxdetectscriptv1/ -o /tmp/PlatformDetection $CURLOPTIONS;)
err=$?
if [[ $err -eq 60 ]]; then
    echo "TLS certificate validation for the agent package download has failed. Please check that your Deep Security Manager TLS certificate is signed by a trusted root certificate authority. For more information, search for \"deployment scripts\" in the Deep Security Help Center."
    logger -t TLS certificate validation for the agent package download has failed. Please check that your Deep Security Manager TLS certificate is signed by a trusted root certificate authority. For more information, search for \"deployment scripts\" in the Deep Security Help Center.
    exit 1;
fi
 
if [ -s /tmp/PlatformDetection ]; then
    . /tmp/PlatformDetection
else
    echo "Failed to download the agent installation support script."
    logger -t Failed to download the Deep Security Agent installation support script
    exit 1
fi
 
platform_detect
if [[ -z "${linuxPlatform}" ]] || [[ -z "${isRPM}" ]]; then
    echo Unsupported platform is detected
    logger -t Unsupported platform is detected
    exit 1
fi
 
echo Downloading agent package...
if [[ $isRPM == 1 ]]; then package='agent.rpm'
    else package='agent.deb'
fi
curl -H "Agent-Version-Control: on" $MANAGERURL/software/agent/${runningPlatform}${majorVersion}/${archType}/$package?tenantID=73293 -o /tmp/$package $CURLOPTIONS
 
echo Installing agent package...
rc=1
if [[ $isRPM == 1 && -s /tmp/agent.rpm ]]; then
    rpm -ihv /tmp/agent.rpm
    rc=$?
elif [[ -s /tmp/agent.deb ]]; then
    dpkg -i /tmp/agent.deb
    rc=$?
else
    echo Failed to download the agent package. Please make sure the package is imported in the Deep Security Manager
    logger -t Failed to download the agent package. Please make sure the package is imported in the Deep Security Manager
    exit 1
fi
if [[ ${rc} != 0 ]]; then
    echo Failed to install the agent package
    logger -t Failed to install the agent package
    exit 1
fi
 
echo Install the agent package successfully
 
sleep 15
/opt/ds_agent/dsa_control -r
/opt/ds_agent/dsa_control -a $ACTIVATIONURL "tenantID:207FC65B-590D-9784-8504-DB36F734F163" "token:7B7CB647-1DB3-649B-B67B-27B1D518E4D9" "policyid:299"
# /opt/ds_agent/dsa_control -a dsm://agents.deepsecurity.trendmicro.com:443/ "tenantID:207FC65B-590D-9784-8504-DB36F734F163" "token:7B7CB647-1DB3-649B-B67B-27B1D518E4D9" "policyid:299"
 
 
sleep 10
#K8s prereq for crio https://kubernetes.io/docs/setup/production-environment/container-runtimes/#cri-o
modprobe overlay
modprobe br_netfilter
 
# Set up required sysctl params, these persist across reboots.
cat >/etc/sysctl.d/99-kubernetes-cri.conf <<EOF
net.bridge.bridge-nf-call-iptables = 1
net.ipv4.ip_forward = 1
net.bridge.bridge-nf-call-ip6tables = 1
EOF
 
sysctl --system
 
 
#Add repo
add-apt-repository -y ppa:projectatomic/ppa
apt update
 
#Install cri-o 1.15
apt-get install -y cri-o-1.15
 
#Change cgroup manager from systemd to cgroupfs to avoid issue https://github.com/cri-o/cri-o/issues/896 and add docker.io as default repo
#Download crio.conf from our phdsaasdevops git repo
curl -LO https://raw.githubusercontent.com/phdsaasdevops/MB2020_Script_ContainerRuntime_K8s_Deployment/master/CRI-O/1.15/crio.conf
mv crio.conf /etc/crio/crio.conf
 
#issue with crio networking https://github.com/cri-o/cri-o/issues/2411#issuecomment-540006558
rm -rf /etc/cni/net.d/*
 
systemctl stop crio
systemctl start crio
systemctl enable crio
 
 
#install crictl 1.17.0
VERSION="v1.17.0"
curl -L https://github.com/kubernetes-sigs/cri-tools/releases/download/$VERSION/crictl-${VERSION}-linux-amd64.tar.gz --output crictl-${VERSION}-linux-amd64.tar.gz
tar zxvf crictl-$VERSION-linux-amd64.tar.gz -C /usr/local/bin
rm -f crictl-$VERSION-linux-amd64.tar.gz
crictl info
 
 
#install kubernetes
curl -s https://packages.cloud.google.com/apt/doc/apt-key.gpg | apt-key add -
cat >/etc/apt/sources.list.d/kubernetes.list <<EOF
deb http://apt.kubernetes.io/ kubernetes-xenial main
EOF
 
apt-get update
apt-get install -y kubeadm=1.15.12-00 kubelet=1.15.12-00 kubectl=1.15.12-00 kubernetes-cni
systemctl enable kubelet
#https://github.com/kidlj/kube/blob/master/README.md
swapoff -a
 
 
#initialize cluster
kubeadm init --cri-socket=unix:///var/run/crio/crio.sock --apiserver-bind-port=443
 
 
#configure kubectl
mkdir -p /home/ubuntu/.kube
cp -i /etc/kubernetes/admin.conf /home/ubuntu/.kube/config
chown $(id -u):$(id -g) /home/ubuntu/.kube/config
 
 
#Taint the master node to be able to deploy coredns pods properly
kubectl taint nodes --all node-role.kubernetes.io/master- >> debug.txt
 
 
#install Weave Pod Network
kubectl apply -f "https://cloud.weave.works/k8s/net?k8s-version=$(kubectl version | base64 | tr -d '\n')" >> debug.txt
sleep 20
 
#install helm
curl -O https://get.helm.sh/helm-v3.0.1-linux-amd64.tar.gz
tar -zxvf helm-v3.0.1-linux-amd64.tar.gz
mv linux-amd64/helm /usr/bin/
 
#Install Smartcheck - no PV
cat >overrides.yaml <<EOF
## activationCode is the product activation code.
##
## Default value: (none)
activationCode: AP-R9RM-92WHD-B2UR5-BV2YB-HZYM8-HYYVA
 
auth:
## secretSeed is used as part of the password generation process for
## all auto-generated internal passwords, ensuring that each installation of
## Deep Security Smart Check has different passwords.
##
## Default value: {must be provided by the installer}
  secretSeed: N0virus1
EOF
 
cat >static-service.yaml <<EOF
apiVersion: v1
kind: Service
metadata:
  name: static-proxy
  labels:
    service: static-proxy
spec:
  type: NodePort
  ports:
   - port: 8443
     targetPort: 8443
     nodePort: 30443
     protocol: TCP
     name: https
   - port: 8080
     targetPort: 8080
     nodePort: 30080
     protocol: TCP
     name: http
   - port: 5000
     targetPort: 5000
     protocol: TCP
     name: registryhttps
  selector:
    service: proxy
    release: deepsecurity-smartcheck
EOF
 
helm install --values overrides.yaml --set persistence.enabled=false --set service.type=ClusterIP deepsecurity-smartcheck https://github.com/deep-security/smartcheck-helm/archive/master.tar.gz
kubectl apply -f static-service.yaml
 
mkdir -p /root/.kube >> debug.txt
cp -i /etc/kubernetes/admin.conf /root/.kube/config >> debug.txt
chown $(id -u):$(id -g) /root/.kube/config >> debug.txt
