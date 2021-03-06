{#- Make sure we start with an updated mine #}
{%- set _ = salt.caasp_orch.sync_all() %}

{#- Get a list of nodes seem to be down or unresponsive #}
{#- This sends a "are you still there?" message to all #}
{#- the nodes and wait for a response, so it takes some time. #}
{#- Hopefully this list will not be too long... #}
{%- set nodes_down = salt.saltutil.runner('manage.down') %}
{%- if nodes_down|length >= 1 %}
# {{ nodes_down|join(',') }} seem to be down: skipping
  {%- do salt.caasp_log.debug('CaaS: nodes "%s" seem to be down: ignored', nodes_down|join(',')) %}
  {%- set is_responsive_node_tgt = 'not L@' + nodes_down|join(',') %}
{%- else %}
# all nodes seem to be up
  {%- do salt.caasp_log.debug('CaaS: all nodes seem to be up') %}
  {#- we cannot leave this empty (it would produce many " and <empty>" targets) #}
  {%- set is_responsive_node_tgt = '*' %}
{%- endif %}

{#- some other targets: #}

{#- the regular nodes (ie, not the CA or the admin node) #}
{%- set is_regular_node_tgt = 'P@roles:(etcd|kube-(master|minion))' + ' and ' + is_responsive_node_tgt %}
{#- machines that need to be updated #}
{%- set is_updateable_tgt = 'G@tx_update_reboot_needed:true' %}

{#- all the other nodes classes #}
{#- (all of them are required to be responsive nodes) #}
{%- set is_etcd_tgt              = is_responsive_node_tgt + ' and G@roles:etcd' %}
{%- set is_master_tgt            = is_responsive_node_tgt + ' and G@roles:kube-master' %}
{%- set is_worker_tgt            = is_responsive_node_tgt + ' and G@roles:kube-minion' %}
{%- set is_updateable_master_tgt = is_updateable_tgt + ' and ' + is_master_tgt %}
{%- set is_updateable_worker_tgt = is_updateable_tgt + ' and ' + is_worker_tgt %}
{%- set is_updateable_node_tgt   = '( ' + is_updateable_master_tgt + ' ) or ( ' + is_updateable_worker_tgt + ' )' %}

{%- set all_masters = salt.caasp_nodes.get_with_expr(is_master_tgt) %}
{%- set super_master = all_masters|first %}

{%- set is_migration = salt['pillar.get']('migration', false) %}
{%- if is_migration %}
  {%- set progress_grain = "migration_in_progress" %}
{%- else %}
  {%- set progress_grain = "update_in_progress" %}
{%- endif %}

{% if is_migration %}
{%- set migrated_nodes_tgt = is_responsive_node_tgt + ' and G@migration_in_progress:true' %}
{% endif %}

{#- Fetch all the nodes which have explicitely disabled the timer. #}
{#- These won't be reenabled at the end of thi orchestration #}
{%- set enabled_timer_nodes_list = salt.caasp_nodes.get_with_expected_ret_value('saltutil.cmd', True, tgt='*', fun='service.enabled', arg=['transactional-update.timer']) %}
{%- do salt.caasp_log.debug('Nodes the timer of which should be reenabled at the end: %s', enabled_timer_nodes_list|join(',')) %}

# Ensure all nodes with updates are marked as upgrading. This will reduce the time window in which
# the update-etc-hosts orchestration can run in between machine restarts.
set-progress-grain:
  salt.function:
    - tgt: '( {{ is_regular_node_tgt }} and {{ is_updateable_tgt }} ) or {{ super_master }}'
    - tgt_type: compound
    - name: grains.setval
    - arg:
      - {{ progress_grain }}
      - true

# Disable the update timer for all nodes.
disable-transactional-update-timer:
  salt.function:
    - tgt: '{{ is_responsive_node_tgt }}'
    - tgt_type: compound
    - batch: 3
    - name: service.disable
    - arg:
      - transactional-update.timer
    - require:
      - set-progress-grain

remove-uncordon-grain:
  salt.function:
    - tgt: '{{ is_responsive_node_tgt }}'
    - tgt_type: compound
    - name: grains.remove
    - arg:
      - kubelet:should_uncordon
    - require:
      - disable-transactional-update-timer

# this will load the _pillars/velum.py on the master
sync-pillar:
  salt.runner:
    - name: saltutil.sync_pillar
    - require:
      - remove-uncordon-grain

update-data:
  salt.function:
    - tgt: '{{ is_responsive_node_tgt }}'
    - tgt_type: compound
    - names:
      - saltutil.refresh_pillar
      - saltutil.refresh_grains
    - require:
      - sync-pillar

# This needs to be a separate step from `update-data`, so `saltutil.refresh_pillar` has been
# called before this, discovering new mine functions defined in the pillar, before publishing
# them on the mine.
update-mine:
  salt.function:
    - tgt: '{{ is_responsive_node_tgt }}'
    - tgt_type: compound
    - name: mine.update
    - require:
      - update-data

update-modules:
  salt.function:
    - name: saltutil.sync_all
    - tgt: '{{ is_responsive_node_tgt }}'
    - tgt_type: compound
    - kwarg:
        refresh: True
    - require:
      - update-mine

# Generate sa key (we should refactor this as part of the ca highstate along with its counterpart
# in orch/kubernetes.sls)
generate-sa-key:
  salt.state:
    - tgt: 'roles:ca'
    - tgt_type: grain
    - sls:
      - kubernetes-common.generate-serviceaccount-key
    - require:
      - update-modules

admin-apply-haproxy:
  salt.state:
    - tgt: 'roles:admin'
    - tgt_type: grain
    - batch: 1
    - sls:
      - etc-hosts
      - haproxy
    - require:
      - generate-sa-key

admin-setup:
  salt.state:
    - tgt: 'roles:admin'
    - tgt_type: grain
    - highstate: True
    - require:
      - admin-apply-haproxy

early-services-setup:
  salt.state:
    - tgt: '{{ super_master }}'
    - sls:
      - addons
      - addons.psp
      - cni
    - require:
      - admin-setup

# Get list of masters needing reboot
{%- set masters = salt.caasp_nodes.get_with_expr(is_updateable_master_tgt) %}
{%- for master_id in masters %}

# Kubelet needs other services, e.g. the cri, up + running. This provide a way
# to ensure kubelet is stopped before any other services.
{{ master_id }}-early-clean-shutdown:
  salt.state:
    - tgt: '{{ master_id }}'
    - sls:
      - kubelet.stop
    - require:
      - early-services-setup

{{ master_id }}-clean-shutdown:
  salt.state:
    - tgt: '{{ master_id }}'
    - sls:
      - kube-apiserver.stop
      - kube-controller-manager.stop
      - kube-scheduler.stop
      - cri.stop
      - etcd.stop
    - require:
        - {{ master_id }}-early-clean-shutdown

# Perform any necessary migrations before services are shutdown
{{ master_id }}-pre-reboot:
  salt.state:
    - tgt: '{{ master_id }}'
    - sls:
      - etc-hosts.update-pre-reboot
      # If we are running a cri-o based cluster this is a workaround for bsc#1116933
      # cri-o would consume all CPU and spin up a huge number of pause containers, breaking
      # the node.
      # Using caasp_cri.cri_name will not work here, as it would run on the salt-master which
      # will always return 'docker'.
      {% if salt['pillar.get']('cri:chosen') == "crio" %}
      - migrations.cri.pre-update
      {% endif %}
    - require:
      - {{ master_id }}-clean-shutdown

# Reboot the node
{{ master_id }}-reboot:
  salt.function:
    - tgt: '{{ master_id }}'
    - name: cmd.run
    - arg:
      - sleep 15; systemctl reboot
    - kwarg:
        bg: True
    - require:
      - {{ master_id }}-pre-reboot

# Wait for it to start again
{{ master_id }}-wait-for-start:
  salt.wait_for_event:
    - name: salt/minion/*/start
    - timeout: 1200
    - id_list:
      - {{ master_id }}
    - require:
      - {{ master_id }}-reboot

# Perform any necessary migrations before salt starts doing
# "real work" again
{{ master_id }}-post-reboot:
  salt.state:
    - tgt: '{{ master_id }}'
    - sls:
      - etc-hosts.update-post-reboot
      - cni.update-post-reboot
    - require:
      - {{ master_id }}-wait-for-start

# Early apply haproxy configuration
{{ master_id }}-apply-haproxy:
  salt.state:
    - tgt: '{{ master_id }}'
    - sls:
      - haproxy
    - require:
      - {{ master_id }}-post-reboot

# Start services
{{ master_id }}-start-services:
  salt.state:
    - tgt: '{{ master_id }}'
    - highstate: True
    - require:
      - {{ master_id }}-apply-haproxy

{% endfor %}

all-masters-post-start-services:
  salt.state:
    - tgt: '{{ is_updateable_master_tgt }}'
    - tgt_type: compound
    - expect_minions: false
    - batch: 3
    - sls:
      - kubelet.update-post-start-services
    - require:
      - early-services-setup
{%- for master_id in masters %}
      - {{ master_id }}-start-services
{%- endfor %}

# We remove the grain when we have the last reference to using that grain.
# Otherwise an incomplete subset of minions might be targeted.
{%- for master_id in masters %}
{{ master_id }}-reboot-needed-grain:
  salt.function:
    - tgt: '{{ master_id }}'
    - name: grains.delval
    - arg:
      - tx_update_reboot_needed
    - kwarg:
        destructive: True
    - require:
      - all-masters-post-start-services
{%- endfor %}

{%- set workers = salt.caasp_nodes.get_with_expr(is_updateable_worker_tgt) %}
{%- for worker_id in workers %}

# Call the node clean shutdown script
# Kubelet needs other services, e.g. the cri, up + running. This provide a way
# to ensure kubelet is stopped before any other services.
{{ worker_id }}-early-clean-shutdown:
  salt.state:
    - tgt: '{{ worker_id }}'
    - sls:
      - kubelet.stop
    - require:
      # wait until all the masters have been updated
{%- for master_id in masters %}
      - {{ master_id }}-reboot-needed-grain
{%- endfor %}

{{ worker_id }}-clean-shutdown:
  salt.state:
    - tgt: '{{ worker_id }}'
    - sls:
      - kube-proxy.stop
      - cri.stop
      - etcd.stop
    - require:
      - {{ worker_id }}-early-clean-shutdown

# Perform any necessary migrations before rebooting
{{ worker_id }}-pre-reboot:
  salt.state:
    - tgt: '{{ worker_id }}'
    - sls:
      # If we are running a cri-o based cluster this is a workaround for bsc#1116933
      # cri-o would consume all CPU and spin up a huge number of pause containers, breaking
      # the node.
      # Using caasp_cri.cri_name will not work here, as it would run on the salt-master which
      # will always return 'docker'.
      {% if salt['pillar.get']('cri:chosen') == "crio" %}
      - migrations.cri.pre-update
      {% endif %}
      - etc-hosts.update-pre-reboot
    - require:
      - {{ worker_id }}-clean-shutdown

# Reboot the node
{{ worker_id }}-reboot:
  salt.function:
    - tgt: '{{ worker_id }}'
    - name: cmd.run
    - arg:
      - sleep 15; systemctl reboot
    - kwarg:
        bg: True
    - require:
      - {{ worker_id }}-pre-reboot

# Wait for it to start again
{{ worker_id }}-wait-for-start:
  salt.wait_for_event:
    - name: salt/minion/*/start
    - timeout: 1200
    - id_list:
      - {{ worker_id }}
    - require:
      - {{ worker_id }}-reboot

# Perform any necessary migrations before salt starts doing
# "real work" again
{{ worker_id }}-post-reboot:
  salt.state:
    - tgt: '{{ worker_id }}'
    - sls:
      - etc-hosts.update-post-reboot
      - cni.update-post-reboot
    - require:
      - {{ worker_id }}-wait-for-start

# Early apply haproxy configuration
{{ worker_id }}-apply-haproxy:
  salt.state:
    - tgt: '{{ worker_id }}'
    - sls:
      - haproxy
    - require:
      - {{ worker_id }}-post-reboot

# Start services
{{ worker_id }}-start-services:
  salt.state:
    - tgt: '{{ worker_id }}'
    - highstate: True
    - require:
      - salt: {{ worker_id }}-apply-haproxy

# Perform any migrations after services are started
{{ worker_id }}-update-post-start-services:
  salt.state:
    - tgt: '{{ worker_id }}'
    - sls:
      - kubelet.update-post-start-services
    - require:
      - {{ worker_id }}-start-services

{{ worker_id }}-update-reboot-needed-grain:
  salt.function:
    - tgt: '{{ worker_id }}'
    - name: grains.delval
    - arg:
      - tx_update_reboot_needed
    - kwarg:
        destructive: True
    - require:
      - {{ worker_id }}-update-post-start-services

{%- if not is_migration %}
# Ensure the node is marked as finished upgrading
{{ worker_id }}-remove-progress-grain:
  salt.function:
    - tgt: '{{ worker_id }}'
    - name: grains.delval
    - arg:
      - {{ progress_grain }}
    - kwarg:
        destructive: True
    - require:
      - {{ worker_id }}-update-reboot-needed-grain
{% endif %}

{% endfor %}

# At this point in time, all workers have been removed the `update_in_progress` grain, so the
# update-etc-hosts orchestration can potentially run on them. We need to keep the masters locked
# (at least the one that we will use to run other tasks in [super_master]). In any case, for the
# sake of simplicity we keep all of them locked until the very end of the orchestration, when we'll
# release all of them (removing the `update_in_progress` grain).

kubelet-setup:
  salt.state:
    - tgt: '{{ is_regular_node_tgt }}'
    - tgt_type: compound
    - sls:
      - kubelet.configure-taints
      - kubelet.configure-labels
    - require:
      - all-masters-post-start-services
# wait until all the machines in the cluster have been upgraded
{%- for master_id in masters %}
      # We use the last state within the masters loop, which is different
      # on masters and minions.
      - {{ master_id }}-reboot-needed-grain
{%- endfor %}
{%- if not is_migration %}
{%- for worker_id in workers %}
      - {{ worker_id }}-remove-progress-grain
{%- endfor %}
{% endif %}

# (re-)apply all the manifests
# this will perform a rolling-update for existing daemonsets
services-setup:
  salt.state:
    - tgt: '{{ super_master }}'
    - sls:
      - addons.dns
      - addons.tiller
      - addons.dex
    - require:
      - kubelet-setup

# Wait for deployments to have the expected number of pods running.
super-master-wait-for-services:
  salt.state:
    - tgt: '{{ super_master }}'
    - sls:
      - addons.dns.deployment-wait
      - addons.tiller.deployment-wait
      - addons.dex.deployment-wait
    - require:
      - services-setup

# Velum will connect to dex through the local haproxy instance in the admin node (because the
# /etc/hosts include the external apiserver pointing to 127.0.0.1). Make sure that before calling
# the orchestration done, we can access dex from the admin node as Velum would do.
admin-wait-for-services:
  salt.state:
    - tgt: 'roles:admin'
    - tgt_type: grain
    - batch: 1
    - sls:
      - addons.dex.wait
    - require:
      - super-master-wait-for-services

# Remove the now defuct caasp_fqdn grain (Remove for 4.0).
remove-caasp-fqdn-grain:
  salt.function:
    - tgt: '{{ is_responsive_node_tgt }}'
    - tgt_type: compound
    - name: grains.delval
    - arg:
      - caasp_fqdn
    - kwarg:
        destructive: True
    - require:
      - admin-wait-for-services

{%- if is_migration %}
reenable-transactional-update-timer:
  salt.function:
    - tgt: '( {{ migrated_nodes_tgt }} ) or P@roles:admin'
    - tgt_type: compound
    - batch: 3
    - name: service.enable
    - arg:
        - transactional-update.timer
    - require:
      - remove-caasp-fqdn-grain

{%- for grain in ['tx_update_migration_notes', 'tx_update_migration_newversion', 'tx_update_migration_available'] %}
unset-{{ grain }}-grain:
  salt.function:
    - tgt: '{{ migrated_nodes_tgt }}'
    - tgt_type: compound
    - name: grains.delval
    - arg:
        - {{ grain }}
    - kwarg:
        destructive: True
    - require:
      - reenable-transactional-update-timer
{%- endfor %}
{%- elif enabled_timer_nodes_list|length > 0 %}
reenable-transactional-update-timer:
  salt.function:
    - tgt: '{{ enabled_timer_nodes_list|join(",") }}'
    - tgt_type: list
    - batch: 3
    - name: service.enable
    - arg:
        - transactional-update.timer
    - require:
      - remove-caasp-fqdn-grain
{%- endif %}

remove-update-grain:
  salt.function:
    - tgt: '{{ is_responsive_node_tgt }} and G@{{ progress_grain }}:true'
    - tgt_type: compound
    - name: grains.delval
    - arg:
      - {{ progress_grain }}
    - kwarg:
        destructive: True
    - require:
      - remove-caasp-fqdn-grain
