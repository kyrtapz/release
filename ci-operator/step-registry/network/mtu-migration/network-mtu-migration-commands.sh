#!/usr/bin/env bash

set -x
set -o errexit
set -o pipefail

. "${SHARED_DIR}/mtu-migration-config"

if [ -z "${MTU_OFFSET}" ]; then
  echo "MTU_OFFSET not defined"
  exit 1
fi

wait_for_mcp() {
  timeout=${1}
  # Wait until MCO starts applying new machine config to nodes
  oc wait mcp --all --for='condition=UPDATING=True' --timeout=300s

  echo "Waiting for all MachineConfigPools to update..."
  timeout "${timeout}" bash <<EOT
    until
      oc wait mcp --all --for='condition=UPDATED=True' --timeout=10s 2>/dev/null && \
      oc wait mcp --all --for='condition=UPDATING=False' --timeout=10s 2>/dev/null && \
      oc wait mcp --all --for='condition=DEGRADED=False' --timeout=10s;
    do
      sleep 10
    done
EOT
}

wait_for_co() {
  timeout=${1}
  echo "Waiting for all ClusterOperators to update..."
  timeout "${timeout}" bash <<EOT
  until
    oc wait co --all --for='condition=AVAILABLE=True' --timeout=10s 2>/dev/null && \
    oc wait co --all --for='condition=PROGRESSING=False' --timeout=10s 2>/dev/null && \
    oc wait co --all --for='condition=DEGRADED=False' --timeout=10s;
  do
    sleep 10
  done
EOT
}

patch_host_mtu() {
  # shellcheck disable=SC2016
  data=$(target_mtu="${1}" envsubst '$target_mtu' << 'EOF' | base64 -w 0
#!/bin/sh

set -ex

MTU=${target_mtu}

IFACE=$1
STATUS=$2

host_iface=$(ip route show default | awk '{ if ($4 == "dev") { print $5; exit } }')
if [ -z "${host_iface}" ]; then
  host_iface=$(ip -6 route show default | awk '{ if ($4 == "dev") { print $5; exit } }')
fi
if [ -z "${host_iface}" ]; then
  echo "Failed to get default interface"
  exit 1
fi

if [ "$IFACE" = "${host_iface}" -a "$STATUS" = "pre-up" ]; then
    ip link set "$IFACE" mtu $MTU
fi
if [ "$IFACE" = "br-ex" -a "$STATUS" = "pre-up" ]; then
    ovs-vsctl set int "$IFACE" mtu_request=$MTU
    host_if=$(ovs-vsctl --bare --columns=name find Interface type=system)
    ip link set "$host_if" mtu $MTU
fi

EOF
  )

  for role in master worker
  do
    cat << EOF | oc apply -f -
      kind: MachineConfig
      apiVersion: machineconfiguration.openshift.io/v1
      metadata:
       name: 90-${role}-mtu
       labels:
         machineconfiguration.openshift.io/role: ${role}
      spec:
       osImageURL: ''
       config:
         ignition:
           version: 3.2.0
         storage:
           files:
           - filesystem: root
             path: "/etc/NetworkManager/dispatcher.d/pre-up.d/30-mtu.sh"
             contents:
               source: data:text/plain;charset=utf-8;base64,${data}
               verification: {}
             mode: 0755
EOF
  done
}

cluster_mtu=$(oc get network.config --output=jsonpath='{.items..status.clusterNetworkMTU}')
if [ -z "${cluster_mtu}" ]; then
  echo "Unable to get clusterNetworkMTU"
  exit 1
fi

node=$(oc get nodes -o jsonpath='{.items[0].metadata.name}')
host_iface=$(oc debug node/"${node}" -- ip route show default | awk '{ if ($4 == "dev") { print $5; exit } }')
if [ -z "${host_iface}" ]; then
  host_iface=$(oc debug node/"${node}" --ip -6 route show default | awk '{ if ($4 == "dev") { print $5; exit } }')
fi

if [ -z "${host_iface}" ]; then
  echo "Unable to get host default route interface"
  exit 1
fi

host_mtu=$(oc debug node/"${node}" -- cat /sys/class/net/"${host_iface}"/mtu)
if [ -z "${host_mtu}" ]; then
  echo "Unable to get host MTU"
  exit 1
fi

wait_for_co "1200s"

if [[ ${MTU_OFFSET} -ne 0 ]]; then
  from=${cluster_mtu}
  to=$((from+MTU_OFFSET))
  host_to=$((host_mtu+MTU_OFFSET))
  oc patch Network.operator.openshift.io cluster --type='merge'   --patch '{"spec":{"migration":null}}'
  timeout 60s bash <<EOT
  until
    ! oc get network -o yaml | grep migration > /dev/null
  do
    echo "migration field is not cleaned by CNO"
    sleep 3
  done
EOT
  oc patch Network.operator.openshift.io cluster --type='merge' --patch "{\"spec\": { \"migration\": { \"mtu\": { \"network\": { \"from\": ${from}, \"to\": ${to} } , \"machine\": { \"to\" : ${host_to}} } } } }"
else
  network_type=$(oc get network.config --output=jsonpath='{.items..status.networkType}')
  if [ -z "${network_type}" ]; then
    echo "Unable to get networkType"
    exit 1
  fi
  network_config="ovnKubernetesConfig"
  if [ "${network_type}" = "OpenShiftSDN" ]; then
    network_config="openshiftSDNConfig"
  fi

  host_to=$(oc get network.config --output=jsonpath='{.items..status.migration.mtu.machine.to}')
  if [ -z "${host_to}" ]; then
    echo "Unable to get migration.host.to"
    exit 1
  fi

  oc patch MachineConfigPool master --type='merge' --patch '{ "spec": { "paused": true } }'
  oc patch MachineConfigPool worker --type='merge' --patch '{ "spec":{ "paused" :true } }'
  oc patch Network.operator.openshift.io cluster --type=merge --patch "{ \"spec\": { \"migration\": null, \"defaultNetwork\":{ \"${network_config}\":{ \"mtu\":${cluster_mtu} }}}}"
  patch_host_mtu "${host_to}"
  oc patch MachineConfigPool master --type='merge' --patch '{ "spec": { "paused": false } }'
  oc patch MachineConfigPool worker --type='merge' --patch '{ "spec":{ "paused" :false } }'
fi

# Check all machine config pools are updated
wait_for_mcp "2700s"

# Check all cluster operators are operational
wait_for_co "2700s"

oc get co
