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
# load_balancer_hostname: The hostname of the AWS load balancer in
# front of this IPA server (e.g. ipa.example.com).
#
# netbios_name: The NETBIOS name to be used by this IPA server
# (e.g. EXAMPLE).  Note that NETBIOS names are restricted to at most
# 15 characters.  These characters must consist only of uppercase
# letters, numbers, and dashes.
#
# realm: The realm for the IPA server (e.g. EXAMPLE.COM).
#
#
# These variables must be set before replica installation:
#
# domain: The domain for the IPA server (e.g. example.com).
#
# hostname: The hostname of this IPA server (e.g. ipa1.example.com).
#
# load_balancer_hostname: The hostname of the AWS load balancer in
# front of this IPA server (e.g. ipa.example.com).
#
# netbios_name: The NETBIOS name to be used by this IPA server
# (e.g. EXAMPLE).  Note that NETBIOS names are restricted to at most
# 15 characters.  These characters must consist only of uppercase
# letters, numbers, and dashes.

# Load above variables from a file installed by cloud-init:
freeipa_vars_file=/var/lib/cloud/instance/freeipa-vars.sh

# This file contains the part of the FreeIPA Apache configuration that
# we want to modify.
apache_config_file=/etc/httpd/conf.d/ipa-rewrite.conf

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
  ip --family inet address show dev "$1" \
    | grep --perl-regexp --only-matching 'inet \K[\d.]+'
}

function modify_apache_config {
  # FreeIPA insists that the Referer header match the hostname of
  # the instance where the request is received.
  #
  # We don't want to expand the $1 at the end of the line, so we
  # intentionally enclose it in single quotes; hence, we can ignore
  # the SC2016 warning.
  #
  # hostname and load_balancer_hostname are defined in the FreeIPA
  # variables file that is sourced toward the top of this file.
  # Hence we can ignore the "undefined variable" warnings coming
  # from shellcheck (SC2154).
  #
  # shellcheck disable=SC2016,SC2154
  printf '\nRequestHeader edit Referer ^https://%b/(.*) https://%b/$1\n' "${load_balancer_hostname//./\\.}" "$hostname" >> $apache_config_file

  # Change all 301 HTTP status codes to 308, so that methods other
  # than GET and HEAD are left unaltered.  See these links for more
  # details about 301 and 308 status codes:
  # * https://developer.mozilla.org/en-US/docs/Web/HTTP/Status/301
  # * https://developer.mozilla.org/en-US/docs/Web/HTTP/Status/308
  sed --in-place "s/R=301/R=308/g" $apache_config_file

  # Restart Apache so the changes take effect.
  systemctl restart httpd.service
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
        --netbios-name="$netbios_name" \
        --no-ntp \
        --no_hbac_allow \
        --mkhomedir

      kinit admin
      # Get kerberos credentials and create the dhs_certmapdata
      # rules.  These rules are necessary in order to associate
      # a certificate with a user during PKINIT.
      #
      # There is currently a bug in sssd where it does not
      # properly escape parentheses in the certificate subject
      # when performing an LDAP query.  See these links for more
      # about this bug:
      # * https://github.com/SSSD/sssd/issues/5135
      # * https://github.com/SSSD/sssd/pull/1036
      #
      # This bug inhibits us from matching on user certmap data
      # in the case of contractors, whose CNs contain the text
      # "(affiliate)".  Hence we require two certmap rules: one
      # for certificates whose CNs contain parentheses
      # (e.g. contractor certificates) and therefore must match
      # on the full certificate, and one for certificates whose
      # CNs do not contain parentheses (e.g. fed certificates)
      # and therefore can match on user certmap data.  It is
      # preferable to match on user certmap data, since it
      # should change less often than the full certificate.
      #
      # Once the sssd pull request mentioned above is approved,
      # merged, and appears in a release, we should be able to
      # use a single certmap rule for all users that leverages
      # the user certmap data.  This has been documented in:
      # https://github.com/cisagov/ansible-role-freeipa-server/issues/31
      #
      # For more details about FreeIPA, certmap rules, and
      # certmap data, see here:
      # https://access.redhat.com/documentation/en-us/red_hat_enterprise_linux/8/html/configuring_and_managing_identity_management/conf-certmap-idm_configuring-and-managing-idm
      ipa certmaprule-add dhs_certmapdata \
        --matchrule '<ISSUER>O=U\.S\. Government' \
        --maprule '(ipacertmapdata=X509:<I>{issuer_dn!nss_x500}<S>{subject_dn!nss_x500})' \
        --desc 'For PIV certificates WITHOUT parentheses in the CN. No priority means lowest priority according to man sss-certmap.'
      ipa certmaprule-add dhs_certmapdata_parens \
        --matchrule '<ISSUER>O=(U\.S\. Government|Entrust)<SUBJECT>CN=.*[\(\)].*' \
        --maprule '(userCertificate;binary={cert})' \
        --desc 'For PIV certificates WITH parentheses in the CN.  Entrust issuer covers DOE certificates used by INL contractors.  Zero is highest priority according to man sss-certmap.' \
        --priority 0

      # We make use of user certmap data in order to match
      # certificates with FreeIPA users.  It follows that folks
      # who are in the user administrator role need permission
      # to manage users' certmap data.  This permission is
      # lacking from that role by default, but this command
      # remedies that.
      ipa privilege-add-permission "User Administrators" \
        --permissions="System: Manage User Certificate Mappings"
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
      ipa-replica-install \
        --netbios-name="$netbios_name" \
        --setup-ca \
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

  # Grab the instance ID from the AWS Instance Meta-Data Service
  # (IMDSv2)
  imds_token=$(curl --silent \
    --request PUT \
    --header "X-aws-ec2-metadata-token-ttl-seconds: 10" \
    http://169.254.169.254/latest/api/token)
  instance_id=$(curl --silent \
    --header "X-aws-ec2-metadata-token: $imds_token" \
    http://169.254.169.254/latest/meta-data/instance-id)
  # Verify that the instance ID is valid
  if [[ $instance_id =~ ^i-[0-9a-f]{17}$ ]]; then
    # Add a principal alias for the instance ID so folks can ssh in
    # via SSM Session Manager.
    ipa host-add-principal "$hostname" host/"$instance_id"."$domain"
  else
    echo Invalid AWS instance ID "$instance_id" - not attempting to \
      create principal alias for instance ID
  fi

  # Enable features in the active authselect profile so that all necessary
  # hardened rules will be activated.
  # Notes:
  #  - These features are enabled in ansible-role-hardening, however
  #    ipa-server-install and ipa-client-install clobber them, so we must
  #    re-enable them here.
  #  - These authselect commands are RedHat-only (but so are FreeIPA servers).
  authselect enable-feature with-faillock
  authselect enable-feature with-fingerprint
  authselect enable-feature with-smartcard

  # Tweak the Apache configuration to cirrectly handle being placed
  # behind a load balancer.
  modify_apache_config
}

if [ $# -ne 1 ]; then
  echo "Installation type required: master | replica"
  exit 255
fi

setup "$1"
