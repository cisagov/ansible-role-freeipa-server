#!/usr/bin/env bash

set -o nounset
set -o errexit
set -o pipefail

# The admin password for the IPA server's Kerberos admin role
admin_pw=password
# The domain for the IPA server (e.g. example.com)
domain=example.com
# The hostname of this IPA server (e.g. ipa.example.com)
hostname=ipa1.$domain
# The hostname of the IPA server to which to replicate (e.g. ipa0.example.com)
master_hostname=ipa0.$domain

# Get the default Ethernet interface
function get_interface {
    ip route | grep default | sed "s/^.* dev \([^ ]*\).*$/\1/"
}

# Get the IP address corresponding to an interface
function get_ip {
    ip --family inet address show dev "$1" | \
        grep inet | \
        sed "s/^ *//" | \
        cut --delimiter=' ' --fields=2 | \
        cut --delimiter='/' --fields=1
}

# Get the PTR record corresponding to an IP
function get_ptr {
    dig +noall +ans -x "$1" | sed "s/.*PTR[[:space:]]*\(.*\)/\1/"
}

interface=$(get_interface)
ip_address=$(get_ip "$interface")

# Wait until the IP address has a non-Amazon PTR record before
# proceeding
ptr=$(get_ptr "$ip_address")
while grep amazon <<< "$ptr"
do
    sleep 30
    ptr=$(get_ptr "$ip_address")
done

# Wait until the master is up and running before installing.
until ipa-replica-conncheck --replica="$master_hostname"
do
    sleep 60
done

# Install the replica
ipa-replica-install --admin-password="$admin_pw" \
                    --hostname="$hostname" \
                    --ip-address="$ip_address" \
                    --no-ntp \
                    --unattended

# Add the DHS CA to the pkinit anchors
sed -i \
    "/pkinit_anchors = FILE:\/var\/kerberos\/krb5kdc\/cacert\.pem/a \ \ pkinit_anchors = FILE:/usr/local/share/dhsca_fullpath.pem" \
    /var/kerberos/krb5kdc/kdc.conf
systemctl restart krb5kdc.service

# Trust the self-signed FreeIPA CA
echo "$admin_pw" | kinit admin
ipa-certupdate
kdestroy
