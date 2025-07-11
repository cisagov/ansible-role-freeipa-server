#!/usr/bin/env bash

set -o nounset
set -o errexit
set -o pipefail

# An array of valid topology suffixes
declare -a TOPOLOGY_SUFFIXES=("domain" "ca")

# Enable replication of the krblastsuccessfulauth timestamps on all
# existing topology segments.  By default these timestamps *are not*
# replicated between servers to avoid a replication storm, but given
# our limited number of users we should be OK.  See here for more
# details: https://pagure.io/freeipa/issue/9821
function enable_last_successful_auth_replication {
  for suffix in "${TOPOLOGY_SUFFIXES[@]}"; do
    # Get all the topology segments for the given topology suffix.  We
    # will need to update each one.
    topology_segments=$(ipa topologysegment-find "$suffix" --pkey-only \
      | sed --quiet "s/^[[:blank:]]*Segment name:[[:blank:]]*\(.*\)$/\1/p")
    for segment in $topology_segments; do
      # Get detailed information about the topology segment so we can
      # modify it.
      cmd_output=$(ipa topologysegment-find "$suffix" --all \
        --name="$segment" --raw)
      # Extract the part where the fractional replication attributes
      # are specified
      old_repl_attr=$(sed --quiet \
        "s/^[[:blank:]]*nsDS5ReplicatedAttributeList:[[:blank:]]*\(.*\)$/\1/p" \
        <<< "$cmd_output")
      # Remove krblastsuccessfulauth from the list of excluded
      # fractional replication attributes
      new_repl_attr=${old_repl_attr// krblastsuccessfulauth/}
      # Extract the part where the total replication attributes are
      # specified
      old_repl_attr_total=$(sed --quiet \
        "s/^[[:blank:]]*nsDS5ReplicatedAttributeListTotal:[[:blank:]]*\(.*\)$/\1/p" \
        <<< "$cmd_output")
      # Remove krblastsuccessfulauth from the list of excluded total
      # replication attributes
      new_repl_attr_total=${old_repl_attr_total// krblastsuccessfulauth/}

      # Update the topology segment so that krblastsuccessfulauth is
      # removed from the lists of fractional and total replication
      # exclusions.
      #
      # Note that it is harmless to run this command when it changes
      # nothing; however, we must temporarily turn off the bash option
      # errexit since in that case the error code indicates a failure.
      set +o errexit
      ipa topologysegment-mod "$suffix" "$segment" \
        --replattrs="$new_repl_attr" --replattrstotal="$new_repl_attr_total"
      set -o errexit
    done
  done
}

# Re-initialize this replica.  This should be run after the topology
# segments are altered by the enable_last_successful_auth_replication
# function.
function reinitialize_replica {
  # The suffix just needs to be valid, since every topology suffix
  # with the same name but a different topology suffix should be
  # otherwise identical.
  first_suffix="${TOPOLOGY_SUFFIXES[0]}"
  my_hostname=$(hostnamectl status --static)
  # Note that we only print the first segment name that is a match
  # since any match will work.
  #
  # The T means "jump if no substitution took place" which means that
  # the p and q commands will ONLY run if a substitution took place;
  # otherwise, we proceed to the next line.
  segment_name=$(ipa topologysegment-find "$first_suffix" --pkey-only \
    --rightnode="$my_hostname" \
    | sed --quiet "s/^[[:blank:]]*Segment name:[[:blank:]]*\(.*\)$/\1/; T; p; q")
  if [ -n "$segment_name" ]; then
    other_hostname=$(sed --quiet "s/^\(.*\)-to-$my_hostname$/\1/p" \
      <<< "$segment_name")
  else
    # No match, so the topology segment name must be the other way
    # around.
    segment_name=$(ipa topologysegment-find "$first_suffix" --pkey-only \
      --leftnode="$my_hostname" \
      | sed --quiet "s/^[[:blank:]]*Segment name:[[:blank:]]*\(.*\)$/\1/; T; p; q")
    other_hostname=$(sed --quiet "s/^$my_hostname-to-\(.*\)$/\1/p" \
      <<< "$segment_name")
  fi
  ipa-replica-manage re-initialize --from="$other_hostname"
}

# Enable replication of the krblastsuccessfulauth timestamps on all
# existing topology segments and then reinitialize this replica.
function setup {
  enable_last_successful_auth_replication
  reinitialize_replica
}

if [ $# -eq 0 ]; then
  setup
elif [ $# -eq 1 ]; then
  $1
else
  echo This command takes zero or one argument.
  exit 255
fi
