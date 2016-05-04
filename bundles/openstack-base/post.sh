#!/bin/bash

. /usr/share/conjure-up/hooklib/common.sh

configOpenrc()
{
	cat <<-EOF
		export OS_USERNAME=$1
		export OS_PASSWORD=$2
		export OS_TENANT_NAME=$3
		export OS_AUTH_URL=$4
		export OS_REGION_NAME=$5
		EOF
}

keystone_status=$(unitStatus keystone 0)
if [ $keystone_status != "active" ]; then
    exposeResult "Waiting for Keystone..." 1 "false"
fi

glance_status=$(unitStatus glance 0)
if [ $glance_status != "active" ]; then
    exposeResult "Waiting for Glance..." 1 "false"
fi

nova_controller_status=$(unitStatus nova-cloud-controller 0)
if [ $nova_controller_status != "active" ]; then
    exposeResult "Waiting for Nova Cloud Controller..." 1 "false"
fi

nova_compute_status=$(unitStatus nova-compute 0)
if [ $nova_compute_status != "active" ]; then
    exposeResult "Waiting for Nova Compute..." 1 "false"
fi

mkdir -m 0700 -p cloud
controller_address=$(unitAddress keystone 0)
configOpenrc admin password admin http://$controller_address:5000/v2.0 RegionOne > cloud/admin-openrc
chmod 0600 cloud/admin-openrc

machine=$(unitMachine nova-cloud-controller 0)
juju scp cloud-setup.sh cloud/admin-openrc ~/.ssh/id_rsa.pub $machine:
juju run --machine $machine ./cloud-setup.sh

# setup contrail routing
juju set contrail-configuration "floating-ip-pools=[ { project: admin, network: public-net, pool-name: floatingip_pool, target-projects: [ admin ] } ]"
juju set neutron-contrail "virtual-gateways=[ { project: admin, network: public-net, interface: vgw, subnets: [ 10.0.10.0/24 ], routes: [ 0.0.0.0/0 ] } ]"

machine=$(unitMachine glance 0)
juju scp glance.sh cloud/admin-openrc $machine:
juju run --machine $machine ./glance.sh

# setup host routing
if [ -n "$CONFIGURE_HOST_ROUTING" ]; then
	compute_address=$(dig +short $(unitAddress nova-compute 0) | tail -n 1)
	sudo ip route replace 10.0.10.0/24 via $compute_address
	sudo iptables -C FORWARD -s 10.0.10.0/24 -j ACCEPT 2> /dev/null || sudo iptables -I FORWARD 1 -s 10.0.10.0/24 -j ACCEPT
	sudo iptables -C FORWARD -d 10.0.10.0/24 -j ACCEPT 2> /dev/null || sudo iptables -I FORWARD 2 -d 10.0.10.0/24 -j ACCEPT
	sudo iptables -t nat -C POSTROUTING -s 10.0.10.0/24 ! -d 10.0.10.0/24 -j MASQUERADE 2> /dev/null || sudo iptables -t nat -A POSTROUTING -s 10.0.10.0/24 ! -d 10.0.10.0/24 -j MASQUERADE
fi

contrail_webui=$(unitAddress contrail-webui 0)
exposeResult "Visit Contrail WebUI http://$contrail_webui:8143" 0 "true"
