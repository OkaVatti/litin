# src/compat/systemd.cr
#
# systemd compatibility layer — systemctl subset.
#
# Maps the most common systemctl invocations to litinctl IPC calls.
# This is intentionally a subset: we cover the commands that appear
# most frequently in system scripts, packaging hooks, and admin muscle
# memory. We do not attempt to emulate journalctl, loginctl, or
# systemd-specific unit types.
#
# Supported systemctl commands:
#   start       <unit...>
#   stop        <unit...>
#   restart     <unit...>
#   reload      <unit...>
#   status      [unit...]
#   enable      <unit...> [--now]
#   disable     <unit...> [--now]
#   mask        <unit...>
#   unmask      <unit...>
#   is-active   <unit>
#   is-enabled  <unit>
#   is-failed   <unit>
#   list-units  [--state=...]
#   daemon-reload
#   poweroff
#   reboot
#   halt
#   show        <unit>   (basic property output)
#
# Unit name normalisation:
#   systemd units often have a .service suffix. We strip it so that
#   "systemctl start sshd.service" works identically to
#   "litinctl start sshd".

require "../core/ipc"

module Litin
  module Compat
    module Systemd
      RESET  = "\e[0m"
      BOLD   = "\e[1m"
      GREEN  = "\e[32m"
      RED    = "\e[31m"
      YELLOW = "\e[33m"
      GREY   = "\e[90m"

      def self.systemctl(argv : Array(String)) : Int32
        if argv.empty?
          print_usage
          return 0
        end

        action = argv[0]
        raw_args = argv[1..].reject { |a| a.starts_with?("-") }
        options = parse_options(argv[1..])

        # Normalise unit names: strip .service/.socket/.timer suffix.
        args = raw_args.map { |a| strip_unit_suffix(a) }

        case action
        when "start"
          ipc_call("start", args, options)
        when "stop"
          ipc_call("stop", args, options)
        when "restart"
          ipc_call("restart", args, options)
        when "reload"
          ipc_call("reload", args, options)
        when "status"
          show_status(args, options)
        when "enable"
          rc = ipc_call("enable", args, options)
          if rc == 0 && options.has_key?("now")
            ipc_call("start", args, options)
          else
            rc
          end
        when "disable"
          rc = ipc_call("disable", args, options)
          if rc == 0 && options.has_key?("now")
            ipc_call("stop", args, options)
          else
            rc
          end
        when "mask"
          ipc_call("mask", args, options)
        when "unmask"
          ipc_call("unmask", args, options)
        when "is-active"
          check_state(args.first?, "ready")
        when "is-enabled"
          check_enabled(args.first?)
        when "is-failed"
          check_state(args.first?, "failed")
        when "list-units", "list-unit-files"
          ipc_call("list", [] of String, options)
        when "daemon-reload"
          ipc_call("reload-daemon", [] of String, options)
        when "poweroff"
          ipc_call("shutdown", [] of String, {"mode" => "poweroff"})
        when "reboot"
          ipc_call("shutdown", [] of String, {"mode" => "reboot"})
        when "halt"
          ipc_call("shutdown", [] of String, {"mode" => "halt"})
        when "show"
          opts_with_json = options.merge({"json" => "true"})
          ipc_call("status", args, opts_with_json)
        when "cat"
          # Show the service file contents.
          args.each do |name|
            path = find_service_file(name)
            if path
              puts "# #{path}"
              print File.read(path)
            else
              STDERR.puts "systemctl: #{name}: service file not found"
            end
          end
          0
        when "help", "--help", "-h"
          print_usage
          0
        when "version", "--version"
          puts "systemctl (Litin systemd compat layer) 0.1.0"
          puts "Compatible with systemd command syntax."
          0
        else
          STDERR.puts "systemctl: unknown command '#{action}'"
          STDERR.puts "Run 'systemctl help' for usage."
          1
        end
      end

      # ---------------------------------------------------------------------------
      # Status display — mimics systemctl status output format
      # ---------------------------------------------------------------------------

      private def self.show_status(args : Array(String), options : Hash(String, String)) : Int32
        exit_code = 0

        begin
          client = IPC::Client.new
        rescue
          STDERR.puts "systemctl: cannot connect to litind"
          return 1
        end

        client.request("status", args, options) do |resp|
          unless resp.ok
            STDERR.puts "systemctl: #{resp.payload}"
            exit_code = 1
            next
          end

          resp.payload.each_line do |line|
            next if line.empty?
            puts format_status_line(line)
          end
        end

        client.close
        exit_code
      end

      private def self.format_status_line(line : String) : String
        return line unless line.includes?(": ")
        name, rest = line.split(": ", 2)
        state_token = rest.split.first? || "unknown"
        dot = case state_token
              when "ready"    then "\e[32m●\e[0m"
              when "starting" then "\e[33m●\e[0m"
              when "stopping" then "\e[33m●\e[0m"
              when "failed"   then "\e[31m●\e[0m"
              when "degraded" then "\e[33m●\e[0m"
              when "masked"   then "\e[90m●\e[0m"
              else                 "\e[90m●\e[0m"
              end
        "#{dot} #{name.ljust(24)} #{state_token.ljust(10)} #{rest.partition(" ")[2]}"
      end

      # ---------------------------------------------------------------------------
      # is-active / is-failed checks
      # ---------------------------------------------------------------------------

      private def self.check_state(name : String?, expected_state : String) : Int32
        unless name
          STDERR.puts "systemctl: service name required"
          return 1
        end

        begin
          client = IPC::Client.new
        rescue
          return 1
        end

        found_state = "unknown"
        client.request("status", [name], {} of String => String) do |resp|
          if resp.ok && !resp.payload.empty?
            state_part = resp.payload.split(": ", 2)[1]?.to_s.split.first?
            found_state = state_part || "unknown"
          end
        end
        client.close

        puts found_state

        if expected_state == "ready"
          found_state == "ready" || found_state == "degraded" ? 0 : 1
        else
          found_state == expected_state ? 0 : 1
        end
      end

      private def self.check_enabled(name : String?) : Int32
        unless name
          STDERR.puts "systemctl: service name required"
          return 1
        end

        # Check for enable symlink in any target wants directory.
        enabled = Dir.glob("/etc/litin/targets/*.wants/#{name}").any? do |link|
          File.symlink?(link) && !File.exists?("/etc/litin/masks/#{name}")
        end

        puts enabled ? "enabled" : "disabled"
        enabled ? 0 : 1
      end

      # ---------------------------------------------------------------------------
      # Helpers
      # ---------------------------------------------------------------------------

      private def self.ipc_call(
        action : String,
        args : Array(String),
        options : Hash(String, String),
      ) : Int32
        begin
          client = IPC::Client.new
        rescue
          STDERR.puts "systemctl: cannot connect to litind"
          return 1
        end

        exit_code = 0
        client.request(action, args, options) do |resp|
          if resp.ok
            puts resp.payload unless resp.payload.empty?
          else
            STDERR.puts "systemctl: #{resp.payload}"
            exit_code = 1
          end
        end
        client.close
        exit_code
      end

      # Strip common systemd unit suffixes. Use String#chomp which removes
      # a specific suffix (unlike String#rstrip which strips characters).
      private def self.strip_unit_suffix(name : String) : String
        %w[.service .socket .timer .target .mount .path].each do |suffix|
          return name.chomp(suffix) if name.ends_with?(suffix)
        end
        name
      end

      private def self.find_service_file(name : String) : String?
        candidates = [
          "/etc/litin/services/#{name}/service.sh",
          "/etc/litin/services/#{name}",
          "/etc/litin/services/#{name}.sh",
        ]
        candidates.find { |p| File.exists?(p) }
      end

      private def self.parse_options(tokens : Array(String)) : Hash(String, String)
        opts = {} of String => String
        tokens.each do |t|
          next unless t.starts_with?("-")
          inner = t.lstrip("-")
          if inner.includes?('=')
            k, _, v = inner.partition('=')
            opts[k] = v
          else
            opts[inner] = "true"
          end
        end
        opts
      end

      private def self.print_usage : Nil
        puts <<-USAGE
        systemctl (Litin systemd compatibility layer)

        Commands:
          start <unit...>         Start units
          stop <unit...>          Stop units
          restart <unit...>       Restart units
          reload <unit...>        Reload units
          status [unit...]        Show status
          enable <unit...>        Enable units [--now to also start]
          disable <unit...>       Disable units [--now to also stop]
          mask <unit...>          Mask units
          unmask <unit...>        Unmask units
          is-active <unit>        Exit 0 if active
          is-enabled <unit>       Exit 0 if enabled
          is-failed <unit>        Exit 0 if failed
          list-units              List all units
          daemon-reload           Reload service definitions
          show <unit>             Show unit properties (JSON)
          cat <unit>              Show unit file contents
          reboot                  Reboot the system
          poweroff                Power off the system
          halt                    Halt the system

        Note: Unit suffixes (.service, .socket, .timer) are automatically stripped.
        USAGE
      end
    end
  end
end
