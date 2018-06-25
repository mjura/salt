from __future__ import absolute_import

import difflib
import os

from salt.ext import six
from salt.utils.odict import OrderedDict

try:
    from salt.exceptions import InvalidConfigError
except ImportError:
    from salt.exceptions import SaltException

    class InvalidConfigError(SaltException):
        '''
        Not yet defined by this version of salt
        '''


class EtcHostsRuntimeException(Exception):
    pass


# the system hosts file to load/save
HOSTS_FILE = '/etc/hosts'

# file where we keep the previous /etc/hosts file
CAASP_HOSTS_FILE = '/etc/caasp/hosts'

PREFACE = '''
#
# This file is automatically generated/managed by CaaSP/Salt
# Please add any custom entries in {file}
# Any other modification will be lost...
#
'''

ADMIN_EXPR = 'G@roles:admin'

MASTER_EXPR = 'G@roles:kube-master'

WORKER_EXPR = 'G@roles:kube-minion'

OTHER_EXPR = 'not ( P@roles:(admin|ca) or P@roles:kube-(master|minion) )'

PILLAR_INTERNAL_INFRA = 'internal_infra_domain'

PILLAR_EXTERNAL_FQDN = 'api:server:external_fqdn'

# minimal set of entries that will be written in /etc/hosts
MINIMAL_ETC_HOSTS = '''
127.0.0.1	localhost

# special IPv6 addresses
::1             localhost ipv6-localhost ipv6-loopback

fe00::0         ipv6-localnet

ff00::0         ipv6-mcastprefix
ff02::1         ipv6-allnodes
ff02::2         ipv6-allrouters
ff02::3         ipv6-allhosts

'''


def __virtual__():
    return "caasp_hosts"


def _concat(lst1, lst2):
    res = list(set(lst1) | set(lst2))  # join both lists (without dups)
    res = [x for x in res if x]  # remove empty strings
    res.sort()  # sort the result (for determinism)
    return res


def _load_lines(filename):
    __utils__['caasp_log.debug']('hosts: loading %s', filename)
    with open(filename, 'r') as f:
        lines = [x.strip().replace('\n', '') for x in f.readlines()]

    # remove any trailing empty lines
    while not lines[-1]:
        del lines[-1]

    __utils__['caasp_log.debug']('hosts: %d lines loaded from %s', len(lines), filename)
    return lines


def _write_lines(dst, contents):
    with open(dst, 'w+') as ofile:
        for line in contents:
            ofile.write(line + six.text_type(os.linesep))

        # note: /etc/hosts needs to end with a newline so
        #       that some utils that read it do not break
        ofile.write(six.text_type(os.linesep))


def _load_hosts(hosts, lines, marker_start=None, marker_end=None):
    blocked = False
    for line in lines:
        line = str(line).strip()

        if not line:
            continue

        if marker_start and line.startswith(marker_start):
            __utils__['caasp_log.debug']('hosts: start of skipped block')
            blocked = True
            continue

        if marker_end and line.startswith(marker_end):
            __utils__['caasp_log.debug']('hosts: end of skipped block')
            blocked = False
            continue

        if line.startswith('#'):
            continue

        if blocked:
            continue

        if '#' in line:
            line = line[:line.index('#')].strip()

        comps = line.split()
        ip = comps.pop(0)
        hosts.setdefault(ip, []).extend(comps)

    return hosts


def _load_hosts_file(hosts, filename, marker_start=None, marker_end=None):
    lines = _load_lines(filename)
    return _load_hosts(hosts, lines,
                       marker_start=marker_start,
                       marker_end=marker_end)


# add a (list of) name(s) to a (maybe existing) IP
# it will remove duplicates, sort names, etc...
def _add_names(hosts, ips, names):
    if not isinstance(names, list):
        names = [names]
    if not isinstance(ips, list):
        ips = [ips]

    for ip in ips:
        __utils__['caasp_log.debug']('hosts: adding %s -> %s', ip, names)
        if ip not in hosts:
            hosts[ip] = _concat([], names)
        else:
            hosts[ip] = _concat(hosts[ip], names)


def _add_names_for(hosts, nodes_dict, infra_domain):
    for id, ifaces in nodes_dict.items():
        ip = __salt__['caasp_net.get_primary_ip'](host=id, ifaces=ifaces)
        if ip:
            _add_names(hosts, ip, [id, id + '.' + infra_domain])

            nodename = __salt__['caasp_net.get_nodename'](host=id)
            if nodename:
                _add_names(hosts, ip, [nodename, nodename + '.' + infra_domain])


# note regarding node removals:
# we need the "node_(addition|removal)_in_progress" nodes here, otherwise
#   - nodes being removed will be immediately banned from the cluster (with a message like:
#    'rejected connection from <NODE> (error tls: <NODE-IP> does not match any of DNSNames [...]')
#    and the cluster will become unhealthy
#   - nodes being added will not be able to join (with some similar TLS verification error)
# doing another /etc/hosts update just for one stale entry seem like an overkill,
# so the /etc/hosts cleanup will have to be delayed for some other moment...


def managed(name=HOSTS_FILE,
            admin_nodes=None,
            master_nodes=None,
            worker_nodes=None,
            other_nodes=None,
            caasp_hosts_file=CAASP_HOSTS_FILE,
            append={},
            marker_start=None,
            marker_end=None,
            **kwargs):
    '''
    Generate a /etc/hosts file.

    name
        The hosts file to load/save.

    admin_nodes
        The list of admin nodes.

    master_nodes
        The list of master nodes.

    worker_nodes
        The list of worker nodes.

    other_nodes
        The list of other nodes.

    .. code-block:: yaml

    /etc/hosts:
      caasp_hosts.managed
    '''
    this_roles = __salt__['grains.get']('roles', [])
    infra_domain = __salt__['caasp_pillar.get'](PILLAR_INTERNAL_INFRA, 'infra.caasp.local')
    assert infra_domain

    def fqdn(name):
        return name + '.' + infra_domain

    # get the previous /etc/hosts file and save it on /etc/caasp/hosts
    # note that this must be done ony once in tthe first run of the
    # salt state
    orig_etc_hosts = name or __salt__['config.option']('hosts.file')
    if orig_etc_hosts is None:
        raise InvalidConfigError('Could not obtain current hosts file name')

    # Load the current /etc/hosts file (for calculating differences later on)
    orig_etc_hosts_contents = []
    if os.path.exists(orig_etc_hosts):
        orig_etc_hosts_contents = _load_lines(orig_etc_hosts)

    hosts = OrderedDict()

    _load_hosts(hosts,
                MINIMAL_ETC_HOSTS.splitlines(),
                marker_start=marker_start,
                marker_end=marker_end)

    # copy the /etc/hosts to caasp_hosts_file the first time we run this
    if caasp_hosts_file:
        if not os.path.exists(caasp_hosts_file):
            __utils__['caasp_log.info']('hosts: saving %s in %s', orig_etc_hosts, caasp_hosts_file)
            _write_lines(caasp_hosts_file, orig_etc_hosts_contents)
            # TODO remove this file if something goes wrong...

            try:
                # remove any previous [marker_start, marker_end] block
                __salt__['file.blockreplace'](caasp_hosts_file,
                                              marker_start,
                                              marker_end,
                                              content='',
                                              backup=False)
            except Exception as e:
                __utils__['caasp_log.warn']('could not remove old blocks in {}: {}'.format(caasp_hosts_file, e))

        assert os.path.exists(caasp_hosts_file)

        __utils__['caasp_log.info']('hosts: loading entries in "%s" file', caasp_hosts_file)
        if not os.path.isfile(caasp_hosts_file):
            raise EtcHostsRuntimeException(
                '{} cannot be loaded: it is not a file'.format(caasp_hosts_file))

        _load_hosts_file(hosts,
                         caasp_hosts_file,
                         marker_start=marker_start,
                         marker_end=marker_end)
        __utils__['caasp_log.debug']('hosts: custom /etc/hosts entries:')
        for k, v in hosts.items():
            __utils__['caasp_log.debug']('hosts:    %s %s', k, v)

    # get the admin, masters and workers
    def get_with_expr(expr):
        return __salt__['caasp_nodes.get_with_expr'](expr, grain='network.interfaces')

    # add all the entries
    try:
        _add_names_for(hosts, admin_nodes or get_with_expr(ADMIN_EXPR), infra_domain)
        _add_names_for(hosts, master_nodes or get_with_expr(MASTER_EXPR), infra_domain)
        _add_names_for(hosts, worker_nodes or get_with_expr(WORKER_EXPR), infra_domain)
        _add_names_for(hosts, other_nodes or get_with_expr(OTHER_EXPR), infra_domain)
    except Exception as e:
        raise EtcHostsRuntimeException(
            'Could not add entries for roles in /etc/hosts: {}'.format(e))

    try:
        for ip, names in append.items():
            _add_names(hosts, ip, names)

        # add some extra names for the API servers and admin nodes
        if "kube-master" in this_roles or "admin" in this_roles:
            external_fqdn_name = __salt__['caasp_pillar.get'](PILLAR_EXTERNAL_FQDN)
            if not __salt__['caasp_filters.is_ip'](external_fqdn_name):
                _add_names(hosts, '127.0.0.1', external_fqdn_name)

        # set the ldap server at the Admin node
        if "admin" in this_roles:
            _add_names(hosts, '127.0.0.1', fqdn('ldap'))

        # try to make Salt happy by adding an ipv6 entry
        # for the local host (not really used for anything else)
        this_hostname = __salt__['grains.get']('localhost', '')
        _add_names(hosts, ['127.0.0.1', '::1'],
                   [this_hostname, fqdn(this_hostname)])

        __utils__['caasp_log.debug']('hosts: adding entry for the API server at 127.0.0.1')
        _add_names(hosts, '127.0.0.1', ['api', fqdn('api')])

    except Exception as e:
        raise EtcHostsRuntimeException(
            'Could not add special entries in /etc/hosts: {}'.format(e))

    # (over)write the /etc/hosts
    try:
        preface = PREFACE.format(file=caasp_hosts_file).splitlines()
        new_etc_hosts_contents = []
        for ip, names in hosts.items():
            names.sort()
            line = '{0}        {1}'.format(ip, ' '.join(names))
            new_etc_hosts_contents.append(line.strip().replace('\n', ''))

        new_etc_hosts_contents.sort()
        new_etc_hosts_contents = preface + new_etc_hosts_contents

        __utils__['caasp_log.info']('hosts: writting new content to %s', orig_etc_hosts)
        _write_lines(orig_etc_hosts, new_etc_hosts_contents)

    except Exception as e:
        raise EtcHostsRuntimeException(
            'Could not write {} file: {}'.format(orig_etc_hosts, e))

    if new_etc_hosts_contents != orig_etc_hosts_contents:
        # calculate the changes
        diff = difflib.unified_diff(orig_etc_hosts_contents,
                                    new_etc_hosts_contents,
                                    lineterm='')

        return list(diff)
    else:
        return []
