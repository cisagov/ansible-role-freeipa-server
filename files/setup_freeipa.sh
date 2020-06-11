#!/usr/bin/env bash

set -o nounset
set -o errexit
set -o pipefail

# These variables must be set before server installation:
#
# domain: The domain for the IPA server (e.g. example.com).
#
# hostname: The hostname of this IPA server (e.g. ipa1.example.com).
#
# realm: The realm for the IPA server (e.g. EXAMPLE.COM).
#
#
# These variables must be set before replica installation:
#
# domain: The domain for the IPA server (e.g. example.com).
#
# hostname: The hostname of this IPA server (e.g. ipa1.example.com).

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

# Install FreeIPA as a server or replica
function setup {
    case "$1" in
        master)
            # Grab our IP address
            interface=$(get_interface)
            ip_address=$(get_ip "$interface")

            # Install the master
            #
            # realm, domain, and hostname are defined in the FreeIPA
            # variables file that is sourced toward the top of this
            # file.  Hence we can ignore the "undefined variable"
            # warnings from shellcheck.
            #
            # shellcheck disable=SC2154
            ipa-server-install --setup-kra \
                               --realm="$realm" \
                               --domain="$domain" \
                               --hostname="$hostname" \
                               --ip-address="$ip_address" \
                               --no-ntp \
                               --no_hbac_allow \
                               --mkhomedir

            # Get kerberos credentials and create the dhs_certmapdata
            # rule.  This rule is necessary in order to associate a
            # cert with one or more users during PKINIT, which is
            # itself necessary for FreeIPA to utilize the certmapdata
            # in said users' LDAP configurations.  Without such a rule
            # FreeIPA can only make use of the full certificate data
            # in the users' LDAP entries, if present.  It is much
            # easier and simpler to create certmapdata than to upload
            # each users' full certificate.
            #
            # In other words, without this rule users cannot kinit
            # with only their PIVs unless their entire certificate is
            # uploaded into their LDAP entry.
            #
            # For more details, see here:
            # https://access.redhat.com/documentation/en-us/red_hat_enterprise_linux/8/html/configuring_and_managing_identity_management/conf-certmap-idm_configuring-and-managing-idm
            kinit admin
            ipa certmaprule-add dhs_certmapdata \
                --matchrule '<ISSUER>O=U.S. Government' \
                --maprule '(ipacertmapdata=X509:<I>{issuer_dn!nss_x500}<S>{subject_dn!nss_x500})'
            ;;
        replica)
            # Install the replica
            #
            # For some reason ipa-server-install does not appear to
            # pass the principal to ipa-client-install, so we first
            # run ipa-client-install manually.
            #
            # hostname is defined in the FreeIPA variables file that
            # is sourced toward the top of this file.  Hence we can
            # ignore the "undefined variable" warning from shellcheck.
            #
            # shellcheck disable=SC2154
            ipa-client-install --hostname="$hostname" \
                               --mkhomedir \
                               --no-ntp
            ipa-replica-install --setup-ca \
                                --setup-kra
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

    # Add a principal alias for the instance ID so folks can ssh in
    # via SSM Session Manager.
    ipa host-add-principal \
        "$hostname" \
        host/"$(curl http://169.254.169.254/latest/meta-data/instance-id)"."$domain"
}


if [ $# -ne 1 ]
then
    echo "Installation type required: master | replica"
    exit 255
fi

setup "$1"
