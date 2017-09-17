
RESULTS_DIR=${RESULTS_DIR:-"$(pwd)/k8s-e2e-results"}
PREVIOUS_CI_VERSION=""
RUNONCE=${RUNONCE:-0}
PROJECT=${1}
JOB=${2}
ARCH=${ARCH:-"amd64"}

cd "$(dirname ${BASH_SOURCE[0]})"

if [[ $# != 2 ]]; then
	cat <<-EOF
	Welcome to the script that will run e2e tests and upload the test results on your behalf.

	Usage:
		${0} GCS_BUCKET JOB_SUITE

	Where
	- GCS_BUCKET points to a valid gs:// bucket that you own.
	- JOB_SUITE points to a subdirectory in GCS_BUCKET. That is: gs://${GCS_BUCKET}/logs/${JOB_SUITE}
	EOF
	exit 1
fi

main() {
	while true; do
		CI_VERSION=$(curl -sSL https://dl.k8s.io/ci-cross/latest.txt)
		E2E_IMAGE="kubeadm-e2e:$(printf ${CI_VERSION} | sed "s/+/-/")"
		TMP_DIR=${RESULTS_DIR}/tmp/${CI_VERSION}

		echo "Using commit: ${CI_VERSION}"

		if [[ ${PREVIOUS_CI_VERSION} == ${CI_VERSION} ]]; then
			echo "No new updates to test, sleeping 100 seconds and testing again"
			sleep 100
			continue
		fi

		NUM=$(gsutil cat gs://${PROJECT}/logs/${JOB}/latest.txt)
		NEWNUM=$((NUM+1))
		echo "New number: ${NEWNUM}"
		mkdir -p ${RESULTS_DIR}/${JOB}
		echo ${NEWNUM} > ${RESULTS_DIR}/${JOB}/latest.txt

		JOB_DIR=${RESULTS_DIR}/${JOB}/${NEWNUM}
		mkdir -p ${JOB_DIR}/artifacts

		writeStartedJSON ${JOB_DIR} ${CI_VERSION}
		startTime=$(date +%s)

		gsutil rsync -r ${RESULTS_DIR}/${JOB} gs://${PROJECT}/logs/${JOB}

		POD_CIDR=${POD_CIDR} ARCH=${ARCH} ./cluster-up.sh ${CI_VERSION} ${RESULTS_DIR} ${E2E_IMAGE} | tee -a ${JOB_DIR}/build-log.txt
		clusterUpTime=$(date +%s)

		echo "Submitting the e2e Batch Job to the cluster"
		export KUBECONFIG=/etc/kubernetes/admin.conf
		cat e2e-job.yaml | sed -e "s|E2EIMAGE|${E2E_IMAGE}|g;" | ${TMP_DIR}/kubectl apply -f -
		E2E_NAMESPACE="e2e-job"

		while [[ $(${TMP_DIR}/kubectl -n ${E2E_NAMESPACE} get po -l app=k8s-e2e-job --no-headers | awk '{print $3}') != "Running" ]]; do
			echo "Waiting for Pod to become Running"
			sleep 5
		done

		pod_name=$(${TMP_DIR}/kubectl -n ${E2E_NAMESPACE} get po -l app=k8s-e2e-job --no-headers | awk '{print $1}')

		${TMP_DIR}/kubectl -n ${E2E_NAMESPACE} logs ${pod_name} -c e2e -f | tee -a ${JOB_DIR}/build-log.txt

		passed="true"
		if [[ $(${TMP_DIR}/kubectl -n ${E2E_NAMESPACE} logs ${pod_name} -c e2e --tail 1) == "FAIL" ]]; then
			passed="false"
		fi

		${TMP_DIR}/kubectl cp conformance/${pod_name}:/var/log/kubernetes/e2e/junit_01.xml ${JOB_DIR}/artifacts/junit_01.xml -c proxy
		writeNodesYAML ${JOB_DIR}

		doneTestingTime=$(date +%s)
		./cluster-down.sh ${CI_VERSION} | tee -a ${JOB_DIR}/build-log.txt
		finishTime=$(date +%s)

		writeMetadataJSON ${JOB_DIR} ${CI_VERSION}
		writeJunitRunnerXML ${JOB_DIR} ${passed} $((clusterUpTime-${startTime})) $((doneTestingTime-${clusterUpTime})) $((finishTime-${doneTestingTime}))
		writeFinishedJSON ${JOB_DIR} ${passed} ${CI_VERSION}

		gsutil rsync -r ${RESULTS_DIR}/${JOB} gs://${PROJECT}/logs/${JOB}

		PREVIOUS_CI_VERSION=${CI_VERSION}

		if [[ ${RUNONCE} == 1 ]]; then
			exit
		fi
	done
}


writeStartedJSON(){
	echo "Writing started.json"
	cat > $1/started.json <<-EOF
	{
	    "node": "unknown", 
	    "jenkins-node": "unknown", 
	    "version": "${2}", 
	    "timestamp": $(date +%s), 
	    "repos": {
	        "k8s.io/kubernetes": "master"
	    }, 
	    "repo-version": "${2}"
	}
	EOF
}

writeMetadataJSON() {
	echo "Writing metadata.json"
	cat > $1/artifacts/metadata.json <<-EOF
	{"job-version":"${2}","version":"${2}"}
	EOF
}

writeNodesYAML() {
	echo "Writing nodes.yaml"
	${TMP_DIR}/kubectl get no -oyaml > $1/artifacts/nodes.yaml
}

writeJunitRunnerXML(){
	if [[ $2 == "true" ]]; then
		test_status="<testcase classname=\"e2e.go\" name=\"Test\" time=\"${4}\"/>"
		failures="0"
	else
		test_status="<testcase classname=\"e2e.go\" name=\"Test\" time=\"${4}\">
<failure>
An error occured when running e2e tests or all e2e tests did not pass
</failure>
</testcase>"
		failures="1"
	fi

	echo "Writing junit_runner.xml"
	cat > $1/artifacts/junit_runner.xml <<-EOF
	<testsuite failures="${failures}" tests="12" time="0">
	    <testcase classname="e2e.go" name="Extract" time="0"/>
	    <testcase classname="e2e.go" name="TearDown Previous" time="0"/>
	    <testcase classname="e2e.go" name="Up" time="${3}"/>
	    <testcase classname="e2e.go" name="Check APIReachability" time="0"/>
	    <testcase classname="e2e.go" name="list nodes" time="0"/>
	    <testcase classname="e2e.go" name="test setup" time="0"/>
	    <testcase classname="e2e.go" name="kubectl version" time="0"/>
	    <testcase classname="e2e.go" name="IsUp" time="0"/>
	    ${test_status}
	    <testcase classname="e2e.go" name="DumpClusterLogs" time="0"/>
	    <testcase classname="e2e.go" name="TearDown" time="${5}"/>
	    <testcase classname="e2e.go" name="Deferred TearDown" time="0"/>
	</testsuite>
	EOF
}

writeFinishedJSON(){
	echo "Writing finished.json"

	if [[ $2 == "true" ]]; then
		result="SUCCESS"
	else
		result="FAILED"
	fi

	cat > $1/finished.json <<-EOF
	{
	    "timestamp": $(date +%s), 
	    "version": "${3}", 
	    "result": "${result}", 
	    "passed": ${2}, 
	    "job-version": "${3}", 
	    "metadata": {
	        "repo": "k8s.io/kubernetes", 
	        "version": "${3}",
	        "repos": {
	            "k8s.io/kubernetes": "master"
	        }, 
	        "job-version": "${3}"
	    }
	}
	EOF
}

main
