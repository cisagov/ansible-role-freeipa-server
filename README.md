# ansible-role-freeipa-server #

[![GitHub Build Status](https://github.com/cisagov/ansible-role-freeipa-server/workflows/build/badge.svg)](https://github.com/cisagov/ansible-role-freeipa-server/actions)
[![Total alerts](https://img.shields.io/lgtm/alerts/g/cisagov/ansible-role-freeipa-server.svg?logo=lgtm&logoWidth=18)](https://lgtm.com/projects/g/cisagov/ansible-role-freeipa-server/alerts/)
[![Language grade: Python](https://img.shields.io/lgtm/grade/python/g/cisagov/ansible-role-freeipa-server.svg?logo=lgtm&logoWidth=18)](https://lgtm.com/projects/g/cisagov/ansible-role-freeipa-server/context:python)

This is an Ansible role for installing
[FreeIPA](https://www.freeipa.org) server.

## Requirements ##

None.

## Role Variables ##

The variable `days_before_inactive` determines the number of days a
user can go without logging in before his or her account is determined
to be inactive and is disabled.  If not set, this variable takes on
the default value of 45 days.

## Dependencies ##

None.

## Example Playbook ##

Here's how to use it in a playbook:

```yaml
- hosts: freeipa_servers
  become: yes
  become_method: sudo
  roles:
    - freeipa_server
```

## Contributing ##

We welcome contributions!  Please see [here](CONTRIBUTING.md) for
details.

## License ##

This project is in the worldwide [public domain](LICENSE).

This project is in the public domain within the United States, and
copyright and related rights in the work worldwide are waived through
the [CC0 1.0 Universal public domain
dedication](https://creativecommons.org/publicdomain/zero/1.0/).

All contributions to this project will be released under the CC0
dedication. By submitting a pull request, you are agreeing to comply
with this waiver of copyright interest.

## Author Information ##

Shane Frasier - <jeremy.frasier@trio.dhs.gov>
