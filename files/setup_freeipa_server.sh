#!/usr/bin/env bash

set -o nounset
set -o errexit
set -o pipefail

# The admin password for the IPA server's Kerberos admin role
admin_pw=password
# The password for the IPA server's directory service
directory_service_pw=password
# The domain for the IPA server (e.g. example.com)
domain=example.com
# The hostname of the IPA server (e.g. ipa.example.com)
hostname=ipa.$domain
# Realm for the IPA server (e.g. EXAMPLE.COM)
realm=${domain^^}

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

# Install the server
ipa-server-install --realm="$realm" \
                   --domain="$domain" \
                   --ds-password="$directory_service_pw" \
                   --admin-password="$admin_pw" \
                   --hostname="$hostname" \
                   --ip-address="$ip_address" \
                   --no_hbac_allow \
                   --unattended

# Add the DHS CA to the pkinit anchors
sed -i \
    "/pkinit_anchors = FILE:\/var\/kerberos\/krb5kdc\/cacert\.pem/a \ \ pkinit_anchors = /usr/local/share/dhsca_fullpath.pem" \
    /var/kerberos/krb5kdc/kdc.conf
systemctl restart krb5kdc.service

echo "$admin_pw" | kinit admin
# Trust the self-signed FreeIPA CA
ipa-certupdate
# Create the dhs_certmapdata rule
ipa certmaprule-add dhs_certmapdata --matchrule '<ISSUER>O=U.S. Government'
kdestroy
