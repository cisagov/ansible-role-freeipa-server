#!/usr/bin/env bash

set -o nounset
set -o errexit
set -o pipefail

# These variables must be set before server installation:
#
# admin_pw: The password for the IPA server's Kerberos admin role.
#
# directory_service_pw: The password for the IPA server's directory service.
#
# domain: The domain for the IPA server (e.g. example.com).
#
# hostname: The hostname of this IPA server (e.g. ipa1.example.com).
#
# realm: The realm for the IPA server (e.g. EXAMPLE.COM).
# replicate (e.g. ipa0.example.com).
#
#
# These variables must be set before replica installation:
#
# admin_pw: The password for the IPA server's Kerberos admin role.
#
# hostname: The hostname of this IPA server (e.g. ipa1.example.com).
#
# master_hostname: The hostname of the IPA server to which to
# replicate (e.g. ipa0.example.com).

# Load above variables from a file installed by cloud-init:
freeipa_vars_file=/var/lib/cloud/instance/freeipa-vars.sh

if [[ -f "$freeipa_vars_file" ]]; then
    # Disable this warning since the file is only available at runtime
    # on the server.
    #
    # shellcheck disable=SC1090
    source "$freeipa_vars_file"
else
    echo "FreeIPA variables file does not exist: $freeipa_vars_file"
    echo "It should have been created by cloud-init at boot."
    exit 254
fi

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

# Install FreeIPA as a server or replica
function setup {
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

    case "$1" in
        master)
            # Install the server
            #
            # realm, domain, directory_service_pw, admin_pw, and
            # hostname are defined in the FreeIPA variables file that
            # is sourced toward the top of this file.  Hence we can
            # ignore the "undefined variable" warnings from shellcheck.
            #
            # shellcheck disable=SC2154
            ipa-server-install --realm="$realm" \
                               --domain="$domain" \
                               --ds-password="$directory_service_pw" \
                               --admin-password="$admin_pw" \
                               --hostname="$hostname" \
                               --ip-address="$ip_address" \
                               --no-ntp \
                               --no_hbac_allow \
                               --unattended

            echo "$admin_pw" | kinit admin
            # Create the dhs_certmapdata rule
            ipa certmaprule-add dhs_certmapdata \
                --matchrule '<ISSUER>O=U.S. Government' \
                --maprule '(ipacertmapdata=X509:<I>{issuer_dn!nss_x500}<S>{subject_dn!nss_x500})'
            kdestroy
            ;;
        replica)
            # Wait until the master is up and running before installing.
            #
            # master_hostname is defined in the FreeIPA variables file
            # that is sourced toward the top of this file.  Hence we
            # can ignore the "undefined variable" warnings from shellcheck.
            #
            # shellcheck disable=SC2154
            until ipa-replica-conncheck --replica="$master_hostname"
            do
                sleep 60
            done

            # Install the replica
            #
            # admin_pw and hostname are defined in the FreeIPA variables file that
            # is sourced toward the top of this file.  Hence we can ignore the
            # "undefined variable" warnings from shellcheck.
            #
            # shellcheck disable=SC2154
            ipa-replica-install --setup-ca \
                                --admin-password="$admin_pw" \
                                --hostname="$hostname" \
                                --ip-address="$ip_address" \
                                --no-ntp \
                                --unattended
            ;;
        *)
            echo "Unknown installation type.  Valid installation types are: master | replica"
            exit 255
            ;;
    esac

    # Add the DHS CA to the pkinit anchors
    sed -i \
        "/pkinit_anchors = FILE:\/var\/kerberos\/krb5kdc\/cacert\.pem/a \ \ pkinit_anchors = FILE:/usr/local/share/dhsca_fullpath.pem" \
        /var/kerberos/krb5kdc/kdc.conf
    systemctl restart krb5kdc.service

    # Remove passwords from FreeIPA variables file
    sed -i \
        "s/^admin_pw=.*/admin_pw=/g;s/^directory_service_pw=.*/directory_service_pw=/g" \
        $freeipa_vars_file
}


if [ $# -lt 1 ]
then
    echo "Installation type required: master | replica"
    exit 255
fi

setup "$1"
