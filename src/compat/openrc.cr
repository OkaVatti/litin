# src/compat/openrc.cr
#
# OpenRC compatibility layer.
#
# Maps OpenRC command semantics to litinctl IPC calls so that scripts
# and administrators familiar with OpenRC can use the same muscle memory.
#
# Supported commands:
#   rc-service <name> <action>          -> litinctl <action> <name>
#   rc-update add <name> [runlevel]     -> litinctl enable <name> [--target=<runlevel>]
#   rc-update del <name> [runlevel]     -> litinctl disable <name>
#   rc-update show [runlevel]           -> litinctl list
#   rc-status [runlevel]                -> litinctl status
#
# Runlevel mapping:
#   default   -> default (target)
#   boot      -> boot (target)
#   sysinit   -> boot (target)
#   nonetwork -> basic (target)
#   shutdown  -> shutdown (target)
#   single    -> rescue (target)
#   <any>     -> passed through as-is

require "../core/ipc"

module Litin
  module Compat
    module OpenRC
      RUNLEVEL_MAP = {
        "default"   => "default",
        "boot"      => "boot",
        "sysinit"   => "boot",
        "nonetwork" => "basic",
        "shutdown"  => "shutdown",
        "single"    => "rescue",
      }

      # rc-service <name> <action> [args...]
      def self.rc_service(argv : Array(String)) : Int32
        if argv.size < 2
          STDERR.puts "Usage: rc-service <name> <action>"
          STDERR.puts "       rc-service --list"
          return 1
        end

        if argv[0] == "--list"
          return forward_to_litinctl(["list"])
        end

        name = argv[0]
        action = argv[1]
        extra = argv[2..]

        # Map OpenRC action names to litinctl actions.
        mapped_action = case action
                        when "start"    then "start"
                        when "stop"     then "stop"
                        when "restart"  then "restart"
                        when "reload"   then "reload"
                        when "status"   then "status"
                        when "zap"      then "status" # OpenRC: reset failed state
                        when "describe" then "status"
                        when "pause"    then "stop"
                        else
                          STDERR.puts "rc-service: unknown action '#{action}'"
                          return 1
                        end

        litinctl_args = [mapped_action, name] + extra
        forward_to_litinctl(litinctl_args)
      end

      # rc-update add|del|show [service] [runlevel]
      def self.rc_update(argv : Array(String)) : Int32
        sub = argv[0]?
        case sub
        when "add"
          name = argv[1]?
          runlevel = argv[2]? || "default"
          unless name
            STDERR.puts "Usage: rc-update add <service> [runlevel]"
            return 1
          end
          target = RUNLEVEL_MAP[runlevel]? || runlevel
          forward_to_litinctl(["enable", name, "--target=#{target}"])
        when "del", "delete"
          name = argv[1]?
          unless name
            STDERR.puts "Usage: rc-update del <service> [runlevel]"
            return 1
          end
          forward_to_litinctl(["disable", name])
        when "show", nil
          forward_to_litinctl(["list-targets"])
        else
          STDERR.puts "rc-update: unknown subcommand '#{sub}'"
          STDERR.puts "Usage: rc-update {add|del|show} [service] [runlevel]"
          1
        end
      end

      # rc-status [--all] [--list] [runlevel]
      def self.rc_status(argv : Array(String)) : Int32
        if argv.includes?("--list")
          return forward_to_litinctl(["list-targets"])
        end

        runlevel = argv.reject { |a| a.starts_with?("-") }.first?

        if runlevel
          target = RUNLEVEL_MAP[runlevel]? || runlevel
          forward_to_litinctl(["status", "--target=#{target}"])
        else
          forward_to_litinctl(["status"])
        end
      end

      # Forward an argv array to litinctl by talking to the litind socket directly.
      def self.forward_to_litinctl(args : Array(String)) : Int32
        action = args[0]? || "list"
        names = args[1..].reject { |a| a.starts_with?("--") }
        options = parse_options(args[1..])

        begin
          client = IPC::Client.new
        rescue
          STDERR.puts "rc-compat: cannot connect to litind. Is it running?"
          return 1
        end

        exit_code = 0
        client.request(action, names, options) do |resp|
          if resp.ok
            puts resp.payload unless resp.payload.empty?
          else
            STDERR.puts "error: #{resp.payload}"
            exit_code = 1
          end
        end
        client.close
        exit_code
      end

      private def self.parse_options(tokens : Array(String)) : Hash(String, String)
        opts = {} of String => String
        tokens.each do |t|
          next unless t.starts_with?("--")
          inner = t.lchop("--")
          if inner.includes?('=')
            k, _, v = inner.partition('=')
            opts[k] = v
          else
            opts[inner] = "true"
          end
        end
        opts
      end
    end
  end
end
