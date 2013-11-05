#!/usr/bin/env ruby

require 'yaml'
require 'net/ssh'

SOCKET_IP_ADDR = 3
VALID_IP_ADDR_RE = Regexp.new('^(?:(?:25[0-5]|2[0-4][0-9]|[01]?[0-9][0-9]?)\.){3}(?:25[0-5]|2[0-4][0-9]|[01]?[0-9][0-9]?)$')

# Check ENV for an alternate config file location.
if ENV.has_key?('CONF_CONFIG_FILE')
  @config_file = ENV['CONF_CONFIG_FILE']
else
  @config_file = ENV['HOME'] + '/.openshift/oo-install-cfg.yml'
end

# If this is the add-a-node scenario, the node to be installed will
# be passed via the command line
@target_version = ARGV[0]
@target_node_hostname = ARGV[1]
@target_node_ssh_host = nil

# This converts an ENV hash into a string of ENV settings
def env_setup
  @env_map.each_pair.map{ |k,v| "#{k}=#{v}" }.join(' ')
end

def env_backup
  @env_backup ||= ENV.to_hash
end

def clear_env
  env_backup
  ENV.delete_if{ |name,value| not name.nil? }
end

def restore_env
  env_backup.each_pair do |name,value|
    ENV[name] = value
  end
end

def components_list host_instance
  values = []
  host_instance['roles'].each do |role|
    @role_map[role].each do |ose_role|
      values << ose_role['component']
    end
  end
  values.join(',')
end

# SOURCE for which:
# http://stackoverflow.com/questions/2108727/which-in-ruby-checking-if-program-exists-in-path-from-ruby
def which(cmd)
  exts = ENV['PATHEXT'] ? ENV['PATHEXT'].split(';') : ['']
  ENV['PATH'].split(File::PATH_SEPARATOR).each do |path|
    exts.each { |ext|
      exe = File.join(path, "#{cmd}#{ext}")
      return exe if File.executable? exe
    }
  end
  return nil
end

# Default and baked-in config values for the openshift.sh deployment
@env_map = { 'CONF_INSTALL_COMPONENTS' => 'all' }

# These values will be passed on the command line
@env_input_map = {
  'subscription_type' => ['CONF_INSTALL_METHOD'],
  'repos_base' => ['CONF_REPOS_BASE'],
  'os_repo' => ['CONF_RHEL_REPO'],
  'jboss_repo_base' => ['CONF_JBOSS_REPO_BASE'],
  'os_optional_repo' => ['CONF_RHEL_OPTIONAL_REPO'],
  'scl_repo' => ['CONF_RHSCL_REPO_BASE'],
  'rh_username' => ['CONF_SM_REG_NAME','CONF_RHN_REG_NAME'],
  'rh_password' => ['CONF_SM_REG_PASS','CONF_RHN_REG_PASS'],
  'sm_reg_pool' => ['CONF_SM_REG_POOL'],
  'sm_reg_pool_rhel' => ['CONF_SM_REG_POOL_RHEL'],
  'rhn_reg_actkey' => ['CONF_RHN_REG_ACTKEY'],
}

# Pull values that may have been passed on the command line into the launcher
@env_input_map.each_pair do |input,target_list|
  env_key = "OO_INSTALL_#{input.upcase}"
  if ENV.has_key?(env_key)
    target_list.each do |target|
      @env_map[target] = ENV[env_key]
    end
  end
end

@utility_install_order = ['named','datastore','activemq','broker','node']

# Maps openshift.sh roles to oo-install deployment components
@role_map =
{ 'broker' => [
    { 'component' => 'broker', 'env_hostname' => 'CONF_BROKER_HOSTNAME', 'env_ip_addr' => 'CONF_BROKER_IP_ADDR' },
    { 'component' => 'named', 'env_hostname' => 'CONF_NAMED_HOSTNAME', 'env_ip_addr' => 'CONF_NAMED_IP_ADDR' },
  ],
  'node' => [{ 'component' => 'node', 'env_hostname' => 'CONF_NODE_HOSTNAME', 'env_ip_addr' => 'CONF_NODE_IP_ADDR' }],
  'mqserver' => [{ 'component' => 'activemq', 'env_hostname' => 'CONF_ACTIVEMQ_HOSTNAME' }],
  'dbserver' => [{ 'component' => 'datastore', 'env_hostname' => 'CONF_DATASTORE_HOSTNAME' }],
}

# Will map hosts to roles
@hosts = {}

# Grab the config file contents
config = YAML.load_file(@config_file)

# Set values from deployment configuration
@seen_roles = {}
if config.has_key?('Deployment') and config['Deployment'].has_key?('Hosts') and config['Deployment'].has_key?('DNS')
  config_hosts = config['Deployment']['Hosts']
  config_dns = config['Deployment']['DNS']

  config_hosts.each do |host_info|
    # Basic config file sanity check
    ['ssh_host','host','user','roles','ip_addr'].each do |attr|
      next if not host_info[attr].nil?
      next if not host_info['roles'].include?('broker') and not host_info['roles'].include?('node') and attr == 'ip_addr'
      puts "One of the hosts in the configuration is missing the '#{attr}' setting. Exiting."
      exit 1
    end

    # Map hosts by ssh alias
    @hosts[host_info['ssh_host']] = host_info

    # Set up the OSE-related ENV variables except node settings
    host_info['roles'].each do |role|
      if not @seen_roles.has_key?(role)
        @seen_roles[role] = 1
      elsif not role == 'node'
        puts "Error: The #{role} role has been assigned to multiple hosts. This is not currently supported. Exiting."
        exit 1
      end
      if role == 'node'
        if @target_node_hostname == host_info['host']
          @target_node_ssh_host = host_info['ssh_host']
        end
        # Skip other node-oriented config for now.
        next
      end
      @role_map[role].each do |ose_cfg|
        @env_map[ose_cfg['env_hostname']] = host_info['host']
        if ose_cfg.has_key?('env_ip_addr')
          @env_map[ose_cfg['env_ip_addr']] = host_info['ip_addr']
        end
      end
    end
  end
  @env_map['CONF_DOMAIN'] = config_dns['app_domain']
end

if @hosts.empty?
  puts "The config file at #{@config_file} does not contain OpenShift deployment information. Exiting."
  exit 1
end

if not @target_node_hostname.nil? and @target_node_ssh_host.nil?
  puts "The list of nodes in the config file at #{@config_file} does not contain an entry for #{@target_node_hostname}. Exiting."
  exit 1
end

# Make sure the per-host config is legit
@hosts.each_pair do |ssh_host,info|
  roles = info['roles']
  duplicate = roles.detect{ |e| roles.count(e) > 1 }
  if not duplicate.nil?
    puts "Multiple instances of role type '#{@role_map[duplicate]['role']}' are specified for installation on the same target host (#{ssh_host}).\nThis is not a valid configuration. Exiting."
    exit 1
  end
  if not @target_node_hostname.nil? and @target_node_ssh_host == ssh_host and (roles.length > 1 or not roles[0] == 'node')
    puts "The specified node to be added also contains other OpenShift components.\nNodes can only be added as standalone components on their own systems. Exiting."
    exit 1
  end
end

# Set the installation order
host_order = []
@utility_install_order.each do |order_role|
  if not order_role == 'node' and not @target_node_ssh_host.nil?
    next
  end
  @hosts.each_pair do |ssh_host,host_info|
    host_info['roles'].each do |host_role|
      @role_map[host_role].each do |ose_info|
        if ose_info['component'] == order_role
          if not @target_node_ssh_host.nil? and not @target_node_ssh_host == ssh_host
            next
          end
          if not host_order.include?(ssh_host)
            host_order << ssh_host
          end
        end
      end
    end
  end
end

# Summarize the plan
if @target_node_ssh_host.nil?
  puts "Preparing to install OpenShift Enterprise on the following hosts:\n"
else
  puts "Preparing to add this node to an OpenShift Enterprise system:\n"
end
host_order.each do |ssh_host|
  puts "  * #{ssh_host}: #{@hosts[ssh_host]['roles'].join(', ')}\n"
end

# Run the jobs
@reboots = []
@child_pids = []
host_order.each do |ssh_host|
  user = @hosts[ssh_host]['user']
  @env_map['CONF_INSTALL_COMPONENTS'] = components_list(@hosts[ssh_host])

  # Only include the node config setting for hosts that will have a node installation
  if @hosts[ssh_host]['roles'].include?('node')
    @env_map[@role_map['node'][0]['env_hostname']] = @hosts[ssh_host]['host']
    @env_map[@role_map['node'][0]['env_ip_addr']] = @hosts[ssh_host]['ip_addr']
  else
    @env_map.delete(@role_map['node'][0]['env_hostname'])
    @env_map.delete(@role_map['node'][0]['env_ip_addr'])
  end

  if not ssh_host == 'localhost'
    puts "Copying deployment script to target #{ssh_host}.\n"
    system "scp #{File.dirname(__FILE__)}/openshift.sh #{user}@#{ssh_host}:~/"
  end
  puts "Running deployment\n"

  reboot_info = [ssh_host, 'reboot', 'exit']
  if not user == 'root'
    [1,2].each do |idx|
      reboot_info[idx] = "sudo #{reboot_info[idx]}"
    end
  end
  if not ssh_host == 'localhost'
    [1,2].each do |idx|
      reboot_info[idx] = "ssh #{user}@#{ssh_host} '#{reboot_info[idx]}'"
    end
  end
  @reboots << reboot_info

  @child_pids << Process.fork do
    sudo = user == 'root' ? '' : 'sudo '
    if not ssh_host == 'localhost'
      system "ssh #{user}@#{ssh_host} '#{sudo}chmod u+x ~/openshift.sh \&\& #{sudo}#{env_setup} ~/openshift.sh'"
    else
      # Local installation. Clean out the ENV.
      clear_env

      # Ruby 1.8-ism; we have to jam the env settings into our own ENV
      @env_map.each_pair do |env,val|
        ENV[env] = val
      end
      system "bash -l -c '#{sudo}#{File.dirname(__FILE__)}/openshift.sh'"

      # Now restore the original env
      restore_env
    end
    # Leave the fork
    exit
  end
  puts "Installation completed for host #{@hosts[ssh_host]['host']}\n"
end

procs = Process.waitall

puts "Rebooting systems to complete installation."
@reboots.each do |info|
  ssh_host = info[0]
  reboot = info[1]
  responsive = info[2]
  # We don't start the next reboot until the previous syetm is available.
  if not system(reboot) and not $?.exitstatus == 255
    puts "Attempted to run '#{reboot}' against #{ssh_host} but was unsuccessful. You must manually reboot the hosts in this OpenShift deployment to complete the installation process."
    exit
  else
    retries = 5
    loop do
      # Try the system every 15 seconds until it is reachable or we hit our limit
      sleep 15
      print "\nAttempting to contact #{ssh_host}... "
      if not system(responsive)
        puts "not responding yet; trying again in 15 seconds.\n\n"
        retries = retries - 1
      else
        puts "succeeded.\n\n"
        break
      end
      if retries < 0
        puts "\nWarning: Could not reconect to #{ssh_host} after several retries. Moving on to next host, but there may be issues with your deployment.\n\n"
        break
      end
    end
  end
end

exit
