#!/usr/bin/env bash

set -o nounset
set -o errexit
set -o pipefail

###
# Let's use a temporary kerberos cred cache file so we don't clobber
# anyone else's
###
KRB5CCNAME=$(mktemp)
export KRB5CCNAME

###
# We're running as root, so login to kerberos using the host's keytab
#
# It would be better to create a kerberos service instead, but
# that is left as a future improvement.
###
kinit -k -t /etc/krb5.keytab

###
# Extract the domain from the host keytab
#
# This is some potent sed fu.  Match the first line containing
# "host/something1@something2", then convert something2 to lower case
# and print it, and finally quit sed.
###
domain=$(klist -k /etc/krb5.keytab \
  | sed --quiet "/.*host\/\(.*\)@\(.*\)/{s//\L\2/p;q}")

###
# Convert the domain into an LDAP searchbase
###
searchbase="cn=users,cn=accounts"
# The "domain" item below that looks like shell variable is actually
# replaced by the Terraform templating engine.  Hence we can ignore
# the "undefined variable" warnings from shellcheck.
#
# shellcheck disable=SC2154
g="${domain}"
# While g still contains a dot character...
while grep --quiet --fixed-strings "." <<< "$g"
do
  # Extract the longest non-dot-containing string from the beginning
  # of $g
  tmp=$(expr "$g" : '\([^\.]*\)')
  # Append $tmp onto the end of $searchbase
  searchbase=$searchbase,dc=$tmp
  # Remove $tmp and its trailing period from $g.  We use {% raw %}
  # here to tell Jinja that there are no templates in this line,
  # since otherwise it is confused by the braces and special
  # characters.
  # {% raw %}
  g=${g:${#tmp} + 1}
  # {% endraw %}
done
# There are no more dots in $g, so we just have to append the last bit
# of $g onto $searchbase
searchbase=$searchbase,dc=$g

###
# Determine the date corresponding to days_to_become_inactive days
# ago, in a format that ldapsearch likes
###
distant_past=$(date \
    --date="$(date) -{{ days_before_inactive }} days" \
  +%Y%m%d%H%M%SZ)

###
# Query LDAP to determine all users that are inactive
###
users_to_disable=$(ldapsearch \
    -b "$searchbase" \
    "(krbLastSuccessfulAuth<=$distant_past)" \
    uid \
    2>/dev/null \
  | sed --quiet "/^uid: \(.*\)/{s//\1/p}")

###
# Disable the users
###
for user in $users_to_disable
do
  # The ipa user-disable command may fail if the user is already
  # disabled, for example, but that's not really an error condition
  # for us.  If it fails for any other reason, the reason should be
  # discernible from the cron logs.
  #
  # In any event, it makes sense to disable errexit for the ipa
  # user-disable command since, even if the disabling of a
  # particular user fails, we want the script to proceed with
  # attempting to disable any other inactive users.
  set +o errexit
  ipa user-disable "$user"
  set -o errexit
done

###
# Discard the kerberos credentials
###
kdestroy
