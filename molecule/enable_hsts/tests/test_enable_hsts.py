"""Module containing the tests for the enable_hsts scenario."""

# Standard Python Libraries
import os

# Third-Party Libraries
import pytest
import testinfra.utils.ansible_runner

testinfra_hosts = testinfra.utils.ansible_runner.AnsibleRunner(
    os.environ["MOLECULE_INVENTORY_FILE"]
).get_hosts("all")


@pytest.mark.parametrize(
    "f",
    [
        "/etc/httpd/conf.d/enable_hsts.conf",
    ],
)
def test_apache_config_files(host, f):
    """Test that the appropriate Apache configuration files were installed."""
    assert host.file(f).exists
    assert host.file(f).is_file
    assert host.file(f).user == "root"
    assert host.file(f).group == "root"


def test_apache_config(host):
    """Verify Apache can parse the config with the additions we made."""
    # The ssl.conf file is invalid until FreeIPA's self-signed
    # certificate is present.  This can only be true after
    # ipa-server-install has been run, so we need to temporarily move
    # this file out of the way.  This does not affect the results of
    # the test, since we are not touching ssl.conf anyway.
    cmd = host.run("mv /etc/httpd/conf.d/ssl.conf /etc/httpd/conf.d/ssl.conf.xxx")
    assert cmd.rc == 0

    # Now verify that Apache is OK with the configuration _with_ the
    # modification(s) we have made.
    cmd = host.run("apachectl configtest")
    assert cmd.rc == 0

    # Put back the ssl.conf file.
    cmd = host.run("mv /etc/httpd/conf.d/ssl.conf.xxx /etc/httpd/conf.d/ssl.conf")
    assert cmd.rc == 0
