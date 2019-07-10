# frozen_string_literal: true

require 'csv'

module Bolt
  class Plugin
    class Vagrant
      def initialize
        @logger     = Logging.logger[self]
        @status     = nil
        @ssh_config = {}

        # TODO: Work out how to find this. The problem I have is that when
        # running within rbenv it goes to the vagrant gem before it uses the
        # inbuilt vagrant binary and the gem is unsupported. I need some way of
        # working out where the proper binary is
        @vagrant_binary = '/usr/local/bin/vagrant'
      end

      def name
        'vagrant'
      end

      def hooks
        ['inventory_targets']
      end

      def warn_missing_property(name, property)
        @logger.warn("Could not find property #{property} of vagrant resource #{name}")
      end

      def inventory_targets(_opts)
        targets = []

        # Get the running nodes using vagrant status
        running_nodes = status.keep_if { |_name, details| details['state'] == 'running' }

        # Get ssh details for all nodes
        running_nodes.each do |name, _details|
          config = ssh_config(name)

          targets << {
            'uri'    => "ssh://#{config['HostName']}:#{config['Port']}",
            'name'   => config['Host'],
            'config' => {
              'ssh' => {
                'user'           => config['User'],
                'run-as'         => 'root',
                'private-key'    => config['IdentityFile'],
                'host-key-check' => false,
              }
            }
          }
        end

        targets
      end

      def status
        return @status if @status

        @logger.debug('Running \'vagrant status\' to get the machine list')
        @status = parse_machine_readable(`#{@vagrant_binary} status --machine-readable`)
      end

      def ssh_config(host)
        return @ssh_config[host] if @ssh_config[host]

        @logger.debug("Running 'vagrant ssh-config #{host}' to get the ssh details")
        host_ssh_config_raw = parse_machine_readable(`#{@vagrant_binary} ssh-config #{host} --machine-readable`)[host]['ssh-config']

        # Reverse the inspect style output that vagrant uses
        host_ssh_config_string = host_ssh_config_raw.gsub('\n', "\n")

        @ssh_config[host] = parse_ssh_config(host_ssh_config_string)
      end

      # Walk the "template" config mapping provided in the plugin config and
      # replace all values with the corresponding value from the resource
      # parameters.
      def resolve_config(name, resource, config_template)
        Bolt::Util.walk_vals(config_template) do |value|
          if value.is_a?(String)
            lookup(name, resource, value)
          else
            value
          end
        end
      end

      private

      def deep_merge(first, second)
        merger = proc { |_key, v1, v2| Hash === v1 && Hash === v2 ? v1.merge(v2, &merger) : v2 }
        first.merge(second, &merger)
      end

      # This parses the CSV output from vagrant --machine-readable options
      def parse_machine_readable(output)
        parsed = {}

        CSV.new(output).each do |columns|
          # Remove anything that doesn't have a valid first column
          next unless columns[0].to_i > 10000

          # Remove the timestamp
          columns.shift

          # Convert to a hash
          parsed = deep_merge(parsed, columns.reverse.inject { |a, n| { n => a } })
        end

        # Detele things that aren't related to a node
        parsed.delete(nil)

        parsed
      end

      def parse_ssh_config(output)
        ssh_config_regex = /^\s*(?<setting>[A-Z]\w+)\s+(?<value>.*)$/

        Hash[output.scan(ssh_config_regex)]
      end
    end
  end
end
