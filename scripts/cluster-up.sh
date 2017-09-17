#!/bin/bash

# This script creates a Kubernetes cluster with kubeadm
# It downloads the relevant binaries from the Kubernetes CI
# to a staging directory for the given version.
# Then a cluster is created with "kubeadm init"
# Lastly, kubectl and the e2e.test binary (containing the Kubernetes
# end-to-end tests) are packaged into an image locally.

set -x

CI_VERSION=${1:-""}
RESULTS_DIR=${2:-"$(pwd)/k8s-e2e"}
TMP_DIR=${RESULTS_DIR}/tmp/${CI_VERSION}
UPDATE_KUBELET=${UPDATE_KUBELET:-0}
ARCH=${ARCH:-"amd64"}
# If there is an conflict here, set this to 172.30.0.0/16 and see if it works
POD_CIDR=${POD_CIDR:-"10.32.0.0/16"}
CI_VERSION_TAG=$(printf ${CI_VERSION} | sed "s/+/-/")
E2E_IMAGE=${3}

echo "Running on architecture: ${ARCH}"

if [[ ${UPDATE_KUBELET} == 1 ]]; then
	systemctl stop kubelet

	echo "Downloading kubelet..."
	curl -sSL https://dl.k8s.io/ci-cross/${CI_VERSION}/bin/linux/${ARCH}/kubelet > ${TMP_DIR}/kubelet
	chmod +x ${TMP_DIR}/kubelet

	curl -sSL https://raw.githubusercontent.com/kubernetes/kubernetes/master/build/debs/kubeadm-10.conf > /etc/systemd/system/kubelet.service.d/10-kubeadm.conf

	systemctl daemon-reload
fi

echo "Downloading kubectl..."
mkdir -p ${TMP_DIR}
curl -sSL https://dl.k8s.io/ci-cross/${CI_VERSION}/bin/linux/${ARCH}/kubectl > ${TMP_DIR}/kubectl
echo "Downloading kubeadm..."
mkdir -p ${TMP_DIR}
curl -sSL https://dl.k8s.io/ci-cross/${CI_VERSION}/bin/linux/${ARCH}/kubeadm > ${TMP_DIR}/kubeadm
echo "Downloading e2e.test..."
curl -sSL https://dl.k8s.io/ci-cross/${CI_VERSION}/kubernetes-test.tar.gz | tar -xz -C ${TMP_DIR} kubernetes/platforms/linux/${ARCH}/e2e.test --strip-components=4
chmod +x ${TMP_DIR}/kubectl ${TMP_DIR}/kubeadm ${TMP_DIR}/e2e.test

echo "Running kubeadm init..."
${TMP_DIR}/kubeadm init --kubernetes-version ci/latest 
export KUBECONFIG=/etc/kubernetes/admin.conf

echo "Outputting the client/server versions..."
kubectl version

${TMP_DIR}/kubectl apply -n kube-system -f "https://cloud.weave.works/k8s/net?k8s-version=$(kubectl version | base64 | tr -d '\n')&env.IPALLOC_RANGE=${POD_CIDR}"
${TMP_DIR}/kubectl taint no --all node-role.kubernetes.io/master-

echo "Building e2e image..."
if [[ ${ARCH} == "amd64" ]]; then
	BASEIMAGE="debian"
elif [[ ${ARCH} == "arm" ]]; then
	BASEIMAGE="arm32v7/debian"
elif [[ ${ARCH} == "arm64" ]]; then
	BASEIMAGE="arm64v8/debian"
elif [[ ${ARCH} == "ppc64le" ]]; then
	BASEIMAGE="ppc64le/debian"
elif [[ ${ARCH} == "s390x" ]]; then
	BASEIMAGE="s390x/debian"
fi

cat > ${TMP_DIR}/Dockerfile <<EOF
FROM ${BASEIMAGE}
COPY kubectl e2e.test /usr/bin/
EOF

docker build -t ${E2E_IMAGE} ${TMP_DIR}
