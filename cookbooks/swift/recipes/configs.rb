# Copyright (c) 2015 SwiftStack, Inc.
#
# Licensed under the Apache License, Version 2.0 (the "License");
# you may not use this file except in compliance with the License.
# You may obtain a copy of the License at
#
#    http://www.apache.org/licenses/LICENSE-2.0
#
# Unless required by applicable law or agreed to in writing, software
# distributed under the License is distributed on an "AS IS" BASIS,
# WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or
# implied.
# See the License for the specific language governing permissions and
# limitations under the License.


# rsync

template "/etc/rsyncd.conf" do
  source "etc/rsyncd.conf.erb"
  notifies :restart, 'service[rsync]'
  variables({
    :username => node['username'],
  })
end

execute "enable-rsync" do
  command "sed -i 's/ENABLE=false/ENABLE=true/' /etc/default/rsync"
  not_if "grep ENABLE=true /etc/default/rsync"
  action :run
end

# pre device rsync modules

directory "/etc/rsyncd.d" do
  owner "vagrant"
  group "vagrant"
  action :create
end

["container", "account"].each do |service|
  (1..node['disks']).each do |i|
    dev = "sdb#{i}"
    n = ((i - 1) % node['nodes']) + 1
    template "/etc/rsyncd.d/#{service}_#{dev}.conf" do
      source "/etc/rsyncd.d/rsync_disk.erb"
      owner "vagrant"
      group "vagrant"
      variables({
        :service => service,
        :dev => dev,
        :n => n,
      })
    end
  end
end

(1..[node['disks'], node['ec_disks']].max).each do |i|
  dev = "sdb#{i}"
  n = ((i - 1) % node['nodes']) + 1
  template "/etc/rsyncd.d/object_#{dev}.conf" do
    source "/etc/rsyncd.d/rsync_disk.erb"
    owner "vagrant"
    group "vagrant"
    variables({
      :service => "object",
      :dev => "sdb#{i}",
      :n => n,
    })
  end
end

# services

[
  "rsync",
  "memcached",
  "rsyslog",
].each do |daemon|
  service daemon do
    action :start
  end
end

# haproxy

execute "create key" do
  command "openssl genpkey -algorithm EC -out saio.key " \
    "-pkeyopt ec_paramgen_curve:prime256v1 " \
    "-pkeyopt ec_param_enc:named_curve"
  #command "openssl genpkey -algorithm RSA -out saio.key " \
  #  "-pkeyopt rsa_keygen_bits:2048"
  cwd "/etc/ssl/private/"
  creates "/etc/ssl/private/saio.key"
end

template "/etc/ssl/private/saio.conf" do
  source "/etc/ssl/private/saio.conf.erb"
  variables({
    :ip => node["ip"],
    :hostname => node["hostname"],
  })
end

execute "create cert" do
  command "openssl req -x509 -days 365 -key saio.key " \
    "-out saio.crt -config saio.conf"
  cwd "/etc/ssl/private/"
  creates "/etc/ssl/private/saio.crt"
end

execute "install cert" do
  cert_to_install = "/etc/ssl/private/saio.crt"
  command "mkdir -p /usr/local/share/ca-certificates/extra && " \
    "cp #{cert_to_install} /usr/local/share/ca-certificates/extra/saio_ca.crt && " \
    "update-ca-certificates && " \
    "cat #{cert_to_install} >> $(python -m certifi)"
  creates "/usr/local/share/ca-certificates/extra/saio_ca.crt"
end

execute "create pem" do
  command "cat saio.crt saio.key > saio.pem"
  cwd "/etc/ssl/private/"
  creates "/etc/ssl/private/saio.pem"
end

cookbook_file "/etc/haproxy/haproxy.cfg" do
  source "etc/haproxy/haproxy.cfg"
  notifies :restart, 'service[haproxy]'
  owner node['username']
  group node['username']
end

service "haproxy" do
  if node['ssl'] then
    action :start
  else
    action :stop
  end
end

# swift

directory "/etc/swift" do
  owner node['username']
  group node["username"]
  action :create
end

template "/etc/rc.local" do
  # Make /var/run/swift/ survive reboots
  source "etc/rc.local.erb"
  mode 0755
  variables({
    :username => node['username'],
  })
end

[
  'bench.conf',
  'keymaster.conf',
].each do |filename|
  cookbook_file "/etc/swift/#{filename}" do
    source "etc/swift/#{filename}"
    owner node["username"]
    group node["username"]
  end
end

[
  'base.conf-template',
  'dispersion.conf',
  'container-sync-realms.conf',
  'test.conf',
  'swift.conf',
].each do |filename|
  template "/etc/swift/#{filename}" do
    source "/etc/swift/#{filename}.erb"
    owner node["username"]
    group node["username"]
    variables({}.merge(node))
  end
end

# proxies

directory "/etc/swift/proxy-server" do
  owner node["username"]
  group node["username"]
end

template "/etc/swift/proxy-server/default.conf-template" do
  source "etc/swift/proxy-server/default.conf-template.erb"
  owner node["username"]
  group node["username"]
  variables({
    :disable_encryption => ! node['encryption'],
  })
end

[
  "proxy-server",
  "proxy-noauth",
].each do |proxy|
  proxy_conf_dir = "etc/swift/proxy-server/#{proxy}.conf.d"
  directory proxy_conf_dir do
    owner node["username"]
    group node["username"]
    action :create
  end
  link "/#{proxy_conf_dir}/00_base.conf" do
    to "/etc/swift/base.conf-template"
    owner node["username"]
    group node["username"]
  end
  link "/#{proxy_conf_dir}/10_default.conf" do
    to "/etc/swift/proxy-server/default.conf-template"
    owner node["username"]
    group node["username"]
  end
  if proxy == "proxy-noauth" then
    cookbook_file "#{proxy_conf_dir}/20_settings.conf" do
      source "#{proxy_conf_dir}/20_settings.conf"
      owner node["username"]
      group node["username"]
    end
  else
    if node['kmip'] then
      keymaster_pipeline = 'kmip_keymaster'
    else
      keymaster_pipeline = 'keymaster'
    end
    template "/#{proxy_conf_dir}/20_settings.conf" do
      source "#{proxy_conf_dir}/20_settings.conf.erb"
      owner node["username"]
      group node["username"]
      variables({
        :ssl => node['ssl'],
        :zipkin => if node["zipkin"] then "zipkin" else "" end,
        :keymaster_pipeline => keymaster_pipeline,
      })
    end
  end
end

service_vars = {
  :account => {
    :zipkin => if node["zipkin"] then "zipkin" else "" end,
  },
  :container => {
    :auto_shard => node['container_auto_shard'],
    :zipkin => if node["zipkin"] then "zipkin" else "" end,
  },
  :object => {
    :sync_method => node['object_sync_method'],
    :servers_per_port => node['servers_per_port'],
    :zipkin => if node["zipkin"] then "zipkin" else "" end,
  },
}

[:object, :container, :account].each_with_index do |service, p|
  service_dir = "etc/swift/#{service}-server"
  directory "/#{service_dir}" do
    owner node["username"]
    group node["username"]
    action :create
  end
  template "/#{service_dir}/default.conf-template" do
    source "#{service_dir}/default.conf-template.erb"
    owner node["username"]
    group node["username"]
    variables(service_vars[service])
  end
  (1..node['nodes']).each do |i|
    bind_ip = "127.0.0.1"
    bind_port = "60#{i}#{p}"
    if service == :object && node['servers_per_port'] > 0 then
      # Only use unique IPs if servers_per_port is enabled.  This lets this
      # newer vagrant-swift-all-in-one work with older swift that doesn't have
      # the required whataremyips() plumbing to make unique IPs work.
      bind_ip = "127.0.0.#{i}"

      # This config setting shouldn't really matter in the server-per-port
      # scenario, but it should probably at least be equal to one of the actual
      # ports in the ring.
      bind_port = "60#{i}6"
    end
    conf_dir = "#{service_dir}/#{i}.conf.d"
    directory "/#{conf_dir}" do
      owner node["username"]
      group node["username"]
    end
    link "/#{conf_dir}/00_base.conf" do
      to "/etc/swift/base.conf-template"
      owner node["username"]
      group node["username"]
    end
    link "/#{conf_dir}/10_default.conf" do
      to "/#{service_dir}/default.conf-template"
      owner node["username"]
      group node["username"]
    end
    template "/#{conf_dir}/20_settings.conf" do
      source "#{service_dir}/settings.conf.erb"
      owner node["username"]
      group node["username"]
      variables({
         :srv_path => "/srv/node#{i}",
         :bind_ip => bind_ip,
         :bind_port => bind_port,
         :recon_cache_path => "/var/cache/swift/node#{i}",
      })
    end
  end
end

# object-expirer
directory "/etc/swift/object-expirer.conf.d" do
  owner node["username"]
  group node["username"]
  action :create
end
link "/etc/swift/object-expirer.conf.d/00_base.conf" do
  to "/etc/swift/base.conf-template"
  owner node["username"]
  group node["username"]
end
cookbook_file "/etc/swift/object-expirer.conf.d/20_settings.conf" do
  source "etc/swift/object-expirer.conf.d/20_settings.conf"
  owner node["username"]
  group node["username"]
end

# container-reconciler
directory "/etc/swift/container-reconciler.conf.d" do
  owner node["username"]
  group node["username"]
  action :create
end
link "/etc/swift/container-reconciler.conf.d/00_base.conf" do
  to "/etc/swift/base.conf-template"
  owner node["username"]
  group node["username"]
end
cookbook_file "/etc/swift/container-reconciler.conf.d/20_settings.conf" do
  source "etc/swift/container-reconciler.conf.d/20_settings.conf"
  owner node["username"]
  group node["username"]
end

# internal-client.conf
if node['kmip'] then
  keymaster_pipeline = 'kmip_keymaster'
else
  keymaster_pipeline = 'keymaster'
end
template "/etc/swift/internal-client.conf" do
  source "etc/swift/internal-client.conf.erb"
  owner node["username"]
  owner node["username"]
  variables({
    :disable_encryption => ! node['encryption'],
    :keymaster_pipeline => keymaster_pipeline,
  })
end
