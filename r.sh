#!/bin/bash

unset DRENV_BREAK
unset RAMENDEV_BREAK

args="-v"
env=firefly-dr.yaml

if [[ -z $1 ]]; then
    echo "all start ramendev deploy enable-dr failover relocate disable-dr undeploy delete"
    exit 1
fi

source venv

function log {
    echo "$(date -uIs) $*"
}

function step {
    if [[ $1 = start || $1 = all ]]; then
	pushd test >/dev/null
        rm -f drenv.log
	drenv start envs/$env
	popd >/dev/null
	for c in hub dr1 dr2; do
	    kubectl konfig export $c > $(HOME)/.kube/$c
	done
    fi

    if [[ $1 = ramendev || $1 = all ]]; then
	ramendev deploy $args --image quay.io/ramendr/ramen-operator:canary test/envs/$env
	ramendev config $args test/envs/$env
	kubectl apply -k https://github.com/RamenDR/ocm-ramen-samples.git/channel --context hub
    fi

    if [[ $1 = deploy || $1 = all ]]; then
	test/basic-test/deploy $args test/envs/$env
    fi
    if [[ $1 = enable-dr || $1 = all ]]; then
	test/basic-test/enable-dr $args test/envs/$env
    fi
    if [[ $1 = failover || $1 = all ]]; then
	test/basic-test/failover $args test/envs/$env
    fi
    if [[ $1 = relocate || $1 = all ]]; then
	test/basic-test/relocate $args test/envs/$env
    fi
    if [[ $1 = disable-dr || $1 = all ]]; then
	test/basic-test/disable-dr $args test/envs/$env
    fi
    if [[ $1 = undeploy || $1 = all ]]; then
	test/basic-test/undeploy $args test/envs/$env
    fi
    if [[ $1 = delete ]]; then
	cd test
	drenv delete envs/$env
	exit 0
    fi
}

for s in "$@"; do
    log "Step $s"
    step $s
done
log "Done"
