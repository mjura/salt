include:
  - repositories
  - flannel

######################
# additional ca.crt(s)
#######################

# collect all the certificates
# Notes:
# - from https://docs.docker.com/registry/insecure/#using-self-signed-certificates
#   we do not need to restart docker after adding/removing certificates
# - after a certificate is removed from the pillar by the user, the certifcate
#   will remain there. Maybe we should consider to wipe the certificates
#   directory if we are the only ones managing them...

{% set registries = salt['pillar.get']('registries', []) %}
{% set cert_tuples = salt.caasp_docker.get_registries_certs(registries).items() %}

# TODO: remove once we don't need the "suse_registry_mirror" exception
{% set suse_registry_mirror_cert = salt['pillar.get']('suse_registry_mirror:cert', '') %}
{% if suse_registry_mirror_cert|length > 0 %}
  {% set suse_registry_mirror_url = salt['pillar.get']('suse_registry_mirror:url', '') %}
  {% set suse_registry_mirror_host_port = salt.caasp_docker.get_hostname_and_port_str(suse_registry_mirror_url) %}
  {% set cert_tuples = cert_tuples + [(suse_registry_mirror_host_port, suse_registry_mirror_cert)] %}
{% endif %}

{% for cert_tuple in cert_tuples %}
  {% set name, cert = cert_tuple %}

/etc/docker/certs.d/{{ name }}/ca.crt:
  file.managed:
    - makedirs: True
    - contents: |
        {{ cert | indent(8) }}
    - require_in:
      - docker

{% endfor %}

######################
# proxy for the daemon
#######################

{% set no_proxy = ['.infra.caasp.local', '.cluster.local'] %}
{% if salt['pillar.get']('proxy:no_proxy') %}
  {% do no_proxy.append(pillar['proxy']['no_proxy']) %}
{% endif %}

/etc/systemd/system/docker.service.d/proxy.conf:
  file.managed:
    - makedirs: True
    - contents: |
        [Service]
        Environment="HTTP_PROXY={{ salt['pillar.get']('proxy:http', '') }}"
        Environment="HTTPS_PROXY={{ salt['pillar.get']('proxy:https', '') }}"
        Environment="NO_PROXY={{ no_proxy|join(',') }}"
  module.run:
    - name: service.systemctl_reload
    - onchanges:
      - file: /etc/systemd/system/docker.service.d/proxy.conf

#######################
# docker daemon
#######################

/etc/docker/daemon.json:
  file.managed:
    - source: salt://docker/daemon.json.jinja
    - template: jinja
    - makedirs: True

docker:
  pkg.installed:
    - name: {{ salt['pillar.get']('docker:pkg', 'docker') }}
    - install_recommends: False
    - require:
      - file: /etc/zypp/repos.d/containers.repo
  file.replace:
    # remove any DOCKER_OPTS in the sysconfig file, as we will be
    # using the "daemon.json". In fact, we don't want any DOCKER_OPS
    # in this file, so it could be used, for example, in a systemd
    #  drop-in unit and we wouldn't get into troubles because of precedences...
    - name: /etc/sysconfig/docker
    - pattern: '^DOCKER_OPTS.*$'
    - repl: 'DOCKER_OPTS=""'
    - flags: ['IGNORECASE', 'MULTILINE']
    - append_if_not_found: True
    - require:
      - pkg: docker
  cmd.run:
    - name: systemctl restart docker.service
    - onlyif: systemctl status docker.service
    - onchanges:
      - /etc/systemd/system/docker.service.d/proxy.conf
      - /etc/docker/daemon.json
    - require:
      - file: /etc/sysconfig/docker
      - file: /etc/docker/daemon.json
  service.running:
    - enable: True
    - watch:
      - service: flannel
      - pkg: docker
      - file: /etc/sysconfig/docker
      - /etc/systemd/system/docker.service.d/proxy.conf
