#
# Cookbook Name:: runit
# Provider:: service
#
# Copyright 2011, Joshua Timberman
# Copyright 2011, Chef Software, Inc.
#
# Licensed under the Apache License, Version 2.0 (the "License");
# you may not use this file except in compliance with the License.
# You may obtain a copy of the License at
#
#     http://www.apache.org/licenses/LICENSE-2.0
#
# Unless required by applicable law or agreed to in writing, software
# distributed under the License is distributed on an "AS IS" BASIS,
# WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
# See the License for the specific language governing permissions and
# limitations under the License.
#

require 'chef/provider/service'
require 'chef/provider/link'
require 'chef/resource/link'
require 'chef/provider/directory'
require 'chef/resource/directory'
require 'chef/provider/template'
require 'chef/resource/template'
require 'chef/provider/file'
require 'chef/resource/file'
require 'chef/mixin/shell_out'
require 'chef/mixin/language'

class Chef
  class Provider
    class Service
      class Runit < Chef::Provider::Service
        # refactor this whole thing into a Chef11 LWRP
        include Chef::Mixin::ShellOut

        def initialize(*args)
          super
          new_resource.supports[:status] = true
        end

        def load_current_resource
          @current_resource = Chef::Resource::RunitService.new(new_resource.name)
          current_resource.service_name(new_resource.service_name)

          Chef::Log.debug("Checking status of service #{new_resource.service_name}")

          # verify Runit was installed properly
          unless ::File.exist?(new_resource.sv_bin) && ::File.executable?(new_resource.sv_bin)
            no_runit_message = "Could not locate main runit sv_bin at \"#{new_resource.sv_bin}\". "
            no_runit_message << "Did you remember to install runit before declaring a \"runit_service\" resource? "
            no_runit_message << "\n\nTry adding the following to the top of your recipe:\n\ninclude_recipe \"runit\""
            fail no_runit_message
          end

          current_resource.running(running?)
          current_resource.enabled(enabled?)
          current_resource.env(get_current_env)
          current_resource
        end

        #
        # Chef::Provider::Service overrides
        #

        def action_create
          configure_service # Do this every run, even if service is already enabled and running
          Chef::Log.info("#{new_resource} configured")
        end

        def action_enable
          configure_service # Do this every run, even if service is already enabled and running
          Chef::Log.info("#{new_resource} configured")
          if current_resource.enabled
            Chef::Log.debug("#{new_resource} already enabled - nothing to do")
          else
            enable_service
            Chef::Log.info("#{new_resource} enabled")
          end
          load_new_resource_state
          new_resource.enabled(true)
          restart_service if new_resource.restart_on_update && run_script.updated_by_last_action?
          restart_log_service if new_resource.restart_on_update && log_run_script.updated_by_last_action?
          restart_log_service if new_resource.restart_on_update && log_config_file.updated_by_last_action?
        end

        def configure_service
          if new_resource.sv_templates
            Chef::Log.debug("Creating sv_dir for #{new_resource.service_name}")
            do_action(sv_dir, :create)
            Chef::Log.debug("Creating run_script for #{new_resource.service_name}")
            do_action(run_script, :create)

            if new_resource.log
              Chef::Log.debug("Setting up svlog for #{new_resource.service_name}")
              do_action(log_dir, :create)
              do_action(log_main_dir, :create)
              do_action(default_log_dir, :create) if new_resource.default_logger
              do_action(log_run_script, :create)
              do_action(log_config_file, :create)
            else
              Chef::Log.debug("log not specified for #{new_resource.service_name}, continuing")
            end

            unless new_resource.env.empty?
              Chef::Log.debug("Setting up environment files for #{new_resource.service_name}")
              do_action(env_dir, :create)
              env_files.each do |file|
                file.action.each { |action| do_action(file, action) }
              end
            else
              Chef::Log.debug("Environment not specified for #{new_resource.service_name}, continuing")
            end

            if new_resource.check
              Chef::Log.debug("Creating check script for #{new_resource.service_name}")
              do_action(check_script, :create)
            else
              Chef::Log.debug("Check script not specified for #{new_resource.service_name}, continuing")
            end

            if new_resource.finish
              Chef::Log.debug("Creating finish script for #{new_resource.service_name}")
              do_action(finish_script, :create)
            else
              Chef::Log.debug("Finish script not specified for #{new_resource.service_name}, continuing")
            end

            unless new_resource.control.empty?
              Chef::Log.debug("Creating control signal scripts for #{new_resource.service_name}")
              do_action(control_dir, :create)
              control_signal_files.each { |file| do_action(file, :create) }
            else
              Chef::Log.debug("Control signals not specified for #{new_resource.service_name}, continuing")
            end
          end

          Chef::Log.debug("Creating lsb_init compatible interface #{new_resource.service_name}")
          do_action(lsb_init, :create)
        end

        def enable_service
          Chef::Log.debug("Creating symlink in service_dir for #{new_resource.service_name}")
          do_action(service_link, :create)

          unless inside_docker?
            Chef::Log.debug("waiting until named pipe #{service_dir_name}/supervise/ok exists.")
            until ::FileTest.pipe?("#{service_dir_name}/supervise/ok")
              sleep 1
              Chef::Log.debug('.')
            end

            if new_resource.log
              Chef::Log.debug("waiting until named pipe #{service_dir_name}/log/supervise/ok exists.")
              until ::FileTest.pipe?("#{service_dir_name}/log/supervise/ok")
                sleep 1
                Chef::Log.debug('.')
              end
            end
          else
            Chef::Log.debug("skipping */supervise/ok check inside docker")
          end
        end

        def disable_service
          shell_out("#{new_resource.sv_bin} #{sv_args}down #{service_dir_name}")
          Chef::Log.debug("#{new_resource} down")
          FileUtils.rm(service_dir_name)
          Chef::Log.debug("#{new_resource} service symlink removed")
        end

        def start_service
          shell_out!("#{new_resource.sv_bin} #{sv_args}start #{service_dir_name}")
        end

        def stop_service
          shell_out!("#{new_resource.sv_bin} #{sv_args}stop #{service_dir_name}")
        end

        def restart_service
          shell_out!("#{new_resource.sv_bin} #{sv_args}restart #{service_dir_name}")
        end

        def restart_log_service
          shell_out!("#{new_resource.sv_bin} #{sv_args}restart #{service_dir_name}/log")
        end

        def reload_service
          shell_out!("#{new_resource.sv_bin} #{sv_args}force-reload #{service_dir_name}")
        end

        def reload_log_service
          shell_out!("#{new_resource.sv_bin} #{sv_args}force-reload #{service_dir_name}/log")
        end

        #
        # Addtional Runit-only actions
        #

        # only take action if the service is running
        [:down, :hup, :int, :term, :kill, :quit].each do |signal|
          define_method "action_#{signal}".to_sym do
            if current_resource.running
              runit_send_signal(signal)
            else
              Chef::Log.debug("#{new_resource} not running - nothing to do")
            end
          end
        end

        # only take action if service is *not* running
        [:up, :once, :cont].each do |signal|
          define_method "action_#{signal}".to_sym do
            if current_resource.running
              Chef::Log.debug("#{new_resource} already running - nothing to do")
            else
              runit_send_signal(signal)
            end
          end
        end

        def action_usr1
          runit_send_signal(1, :usr1)
        end

        def action_usr2
          runit_send_signal(2, :usr2)
        end

        private

        def runit_send_signal(signal, friendly_name = nil)
          friendly_name ||= signal
          converge_by("send #{friendly_name} to #{new_resource}") do
            shell_out!("#{new_resource.sv_bin} #{sv_args}#{signal} #{service_dir_name}")
            Chef::Log.info("#{new_resource} sent #{friendly_name}")
          end
        end

        def running?
          cmd = shell_out("#{new_resource.sv_bin} #{sv_args}status #{service_dir_name}")
          (cmd.stdout =~ /^run:/ && cmd.exitstatus == 0)
        end

        def log_running?
          cmd = shell_out("#{new_resource.sv_bin} #{sv_args}status #{service_dir_name}/log")
          (cmd.stdout =~ /^run:/ && cmd.exitstatus == 0)
        end

        def enabled?
          ::File.exists?(::File.join(service_dir_name, 'run'))
        end

        def log_service_name
          ::File.join(new_resource.service_name, 'log')
        end

        def sv_dir_name
          ::File.join(new_resource.sv_dir, new_resource.service_name)
        end

        def sv_args
          sv_args = ''
          sv_args += "-w '#{new_resource.sv_timeout}' " unless new_resource.sv_timeout.nil?
          sv_args += '-v ' if new_resource.sv_verbose
          sv_args
        end

        def service_dir_name
          ::File.join(new_resource.service_dir, new_resource.service_name)
        end

        def log_dir_name
          ::File.join(new_resource.service_dir, new_resource.service_name, log)
        end

        def template_cookbook
          new_resource.cookbook.nil? ? new_resource.cookbook_name.to_s : new_resource.cookbook
        end

        def default_logger_content
          "#!/bin/sh
exec svlogd -tt /var/log/#{new_resource.service_name}"
        end

        #
        # Helper Resources
        #
        def do_action(resource, action)
          resource.run_action(action)
          new_resource.updated_by_last_action(true) if resource.updated_by_last_action?
        end

        def sv_dir
          directory sv_dir_name do
            owner new_resource.owner
            group new_resource.group
            mode '00755'
            recursive true
            action :create
          end
        end

        def run_script
          template "#{sv_dir_name}/#{run}" do
            owner new_resource.owner
            group new_resource.group
            source "sv-#{new_resource.run_template_name}-run.erb"
            mode '00755'
            variables(:options => new_resource.options) if new_resource.options.respond_to?(:has_key?)
            action :create
          end
        end

        def log_dir
          directory "#{sv_dir_name}/log" do
            owner new_resource.owner
            group new_resource.group
            recursive true
            action :create
          end
        end

        def log_main_dir
          directory "#{sv_dir_name}/#{log}/#{main}" do
            owner new_resource.owner
            group new_resource.group
            mode '0755'
            recursive true
            action :create
          end
        end

        def default_log_dir
          directory "/var/log/#{new_resource.service_name}" do
            owner new_resource.owner
            group new_resource.group
            mode '00755'
            recursive true
            action :create
          end
        end

        def log_run_script
          if new_resource.default_logger
            file "#{sv_dir_name}/log/run" do
              content default_logger_content
              owner new_resource.owner
              group new_resource.group
              mode '00755'
              action :create
            end
          else
            template "#{sv_dir_name}/log/run" do
              owner new_resource.owner
              group new_resource.group
              mode '00755'
              source "sv-#{new_resource.log_template_name}-log-run.erb"
              variables(:options => new_resource.options) if new_resource.options.respond_to?(:has_key?)
              action :create
            end
          end
        end

        def log_config_file
          template "#{sv_dir_name}/log/config" do
            owner new_resource.owner
            group new_resource.group
            mode '00644'
            cookbook 'runit'
            source 'log-config.erb'
            variables(
              :size => new_resource.log_size,
              :num => new_resource.log_num,
              :min => new_resource.log_min,
              :timeout => new_resource.log_timeout,
              :processor => new_resource.log_processor,
              :socket => new_resource.log_socket,
              :prefix => new_resource.log_prefix,
              :append => new_resource.log_config_append
              )
            action :create
          end
        end

        def env_dir
          directory "#{sv_dir_name}/env" do
            owner new_resource.owner
            group new_resource.group
            mode '00755'
            action :create
          end
        end

        def env_files
          @env_files ||=
            begin
              create_files = new_resource.env.map do |var, value|
              f = Chef::Resource::File.new(::File.join(sv_dir_name, 'env', var), run_context)
              f.owner(new_resource.owner)
              f.group(new_resource.group)
              f.content(value)
              f.action(:create)
              f
            end
              extra_env = current_resource.env.reject { |k,_| new_resource.env.key?(k) }
              delete_files = extra_env.map do |k,_|
              f = Chef::Resource::File.new(::File.join(sv_dir_name, 'env', k), run_context)
              f.action(:delete)
              f
            end
              create_files + delete_files
            end
        end

        def get_current_env
          env_dir = ::File.join(sv_dir_name, 'env')
          return {} unless ::File.directory? env_dir
          files = ::Dir.glob(::File.join(env_dir,'*'))
          env = files.reduce({}) do |c,o|
            contents = ::IO.read(o).rstrip
            c.merge!(::File.basename(o) => contents)
          end
          env
        end

        def check_script
          template "#{sv_dir_name}/check" do
            owner cnew_resource.owner
            group new_resource.group
            mode '00755'
            cookbook template_cookbook
            source "sv-#{new_resource.check_script_template_name}-check.erb"
            variables(:options => new_resource.options) if new_resource.options.respond_to?(:has_key?)
            action :create
          end
        end

        def finish_script
          template "#{sv_dir_name}/finish" do
            owner new_resource.owner
            group new_resource.group
            mode '00755'
            source "sv-#{new_resource.finish_script_template_name}-finish.erb"
            cookbook template_cookbook
            variables(:options => new_resource.options) if new_resource.options.respond_to?(:has_key?)
            action :create
          end
        end

        def control_dir
          directory "#{sv_dir_name}/control" do
            owner new_resource.owner
            group new_resource.group
            mode '00755'
            action :create
          end
        end

        def control_signal_files
          @control_signal_files ||=
            begin
              new_resource.control.map do |signal|
              t = Chef::Resource::Template.new(
                ::File.join(sv_dir_name, 'control', signal),
                run_context
                )
              t.owner(new_resource.owner)
              t.group(new_resource.group)
              t.mode(00755)
              t.source("sv-#{new_resource.control_template_names[signal]}-#{signal}.erb")
              t.cookbook(template_cookbook)
              t.variables(:options => new_resource.options) if new_resource.options.respond_to?(:has_key?)
              t
            end
            end
        end

        def lsb_init
          if node['platform'] == 'debian'
            link "#{new_resource.lsb_init_dir}/#{new_resource.service_name}" do
              action :delete
            end

            template "#{new_resource.lsb_init_dir}/#{new_resource.service_name}" do
              owner 'root'
              group 'root'
              mode '00755'
              cookbook 'runit'
              source 'init.d.erb'
              variables(:name => new_resource.service_name)
              action :create
            end
          else
            link "#{new_resource.lsb_init_dir}/#{new_resource.service_name}" do
              to new_resource.sv_bin
              action :create
            end
          end
        end

        def service_link
          link "#{service_dir_name}" do
            to sv_dir_name
            action :create
          end
        end

        def inside_docker?
          results = `cat /proc/1/cgroup`.strip.split("\n")
          results.any?{|val| /docker/ =~ val}
        end
      end
    end
  end
end
