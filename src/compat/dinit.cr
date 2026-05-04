# src/compat/dinit.cr
#
# Dinit compatibility layer.
#
# Maps dinitctl command semantics to litinctl IPC calls.
#
# Supported dinitctl commands:
#   start       <service...>
#   stop        <service...>
#   restart     <service...>
#   wake        <service...>    (same as start in Litin)
#   release     <service...>    (same as stop)
#   unpin       <service...>    (same as stop)
#   status      [service...]
#   is-started  <service>       exit 0 if running
#   is-failed   <service>       exit 0 if failed
#   list                        list all services
#   enable      <service...>
#   disable     <service...>
#   add-dep     required|waits-for|before <from> <to>  (partial support)
#   rm-dep      required|waits-for|before <from> <to>  (informational only)
#   shutdown    [--halt|--reboot|--poweroff]
#   reload      (= reload-daemon)
#   trigger     <service>       manually trigger a oneshot service
#
# Dinit dependency types → Litin equivalents:
#   required    → require (hard)
#   waits-for   → want (soft, ordering)
#   before      → before (ordering)
#   milestone   → after (ordering only, no readiness requirement)

require "../core/ipc"

module Litin
  module Compat
    module Dinit
      def self.dinitctl(argv : Array(String)) : Int32
        return print_usage(0) if argv.empty?

        action = argv[0]
        args = argv[1..].reject { |a| a.starts_with?("--") }
        options = parse_options(argv[1..])

        case action
        when "start", "wake"
          need_args(action, args) || return 1
          ipc_call("start", args)
        when "stop", "release", "unpin"
          need_args(action, args) || return 1
          ipc_call("stop", args)
        when "restart"
          need_args(action, args) || return 1
          ipc_call("restart", args)
        when "status"
          ipc_call("status", args, options)
        when "is-started"
          need_args(action, args) || return 1
          check_state(args[0], "ready")
        when "is-failed"
          need_args(action, args) || return 1
          check_state(args[0], "failed")
        when "list"
          ipc_call("list", [] of String, options)
        when "enable"
          need_args(action, args) || return 1
          ipc_call("enable", args, options)
        when "disable"
          need_args(action, args) || return 1
          ipc_call("disable", args, options)
        when "trigger"
          # Trigger a oneshot service manually — same as start.
          need_args(action, args) || return 1
          ipc_call("start", args)
        when "reload"
          # Dinit `dinitctl reload` reloads service definitions.
          ipc_call("reload-daemon", [] of String, options)
        when "shutdown"
          mode = if options.has_key?("reboot")
                   "reboot"
                 elsif options.has_key?("poweroff")
                   "poweroff"
                 else
                   "halt"
                 end
          ipc_call("shutdown", [] of String, {"mode" => mode})
        when "add-dep"
          # add-dep required|waits-for|before <from-service> <to-service>
          # We acknowledge the command but Litin does not support runtime
          # graph mutation — service definitions must be edited on disk and
          # reload-daemon issued.
          STDERR.puts "dinitctl: add-dep is not supported at runtime."
          STDERR.puts "         Edit the service definition and run: litinctl reload-daemon"
          1
        when "rm-dep"
          STDERR.puts "dinitctl: rm-dep is not supported at runtime."
          STDERR.puts "         Edit the service definition and run: litinctl reload-daemon"
          1
        when "help", "--help", "-h"
          print_usage(0)
        when "version", "--version"
          puts "dinitctl (Litin Dinit compat layer) 0.1.0"
          0
        else
          STDERR.puts "dinitctl: unknown command '#{action}'"
          STDERR.puts "Run 'dinitctl help' for usage."
          1
        end
      end

      # -----------------------------------------------------------------------
      # Helpers (public for testing)
      # -----------------------------------------------------------------------

      def self.need_args(action : String, args : Array(String)) : Bool
        if args.empty?
          STDERR.puts "dinitctl: #{action} requires at least one service name"
          return false
        end
        true
      end

      private def self.check_state(name : String, expected : String) : Int32
        begin
          client = IPC::Client.new
        rescue
          STDERR.puts "dinitctl: cannot connect to litind"
          return 1
        end

        state = "unknown"
        client.request("status", [name], {} of String => String) do |resp|
          if resp.ok && !resp.payload.empty?
            state = resp.payload.split(": ", 2)[1]?.to_s.split.first? || "unknown"
          end
        end
        client.close

        puts state

        case expected
        when "ready"
          (state == "ready" || state == "degraded") ? 0 : 1
        when "failed"
          state == "failed" ? 0 : 1
        else
          state == expected ? 0 : 1
        end
      end

      private def self.ipc_call(
        action : String,
        args : Array(String),
        options : Hash(String, String) = {} of String => String,
      ) : Int32
        begin
          client = IPC::Client.new
        rescue
          STDERR.puts "dinitctl: cannot connect to litind"
          return 1
        end

        exit_code = 0
        client.request(action, args, options) do |resp|
          if resp.ok
            puts resp.payload unless resp.payload.empty?
          else
            STDERR.puts "dinitctl: #{resp.payload}"
            exit_code = 1
          end
        end
        client.close
        exit_code
      end

      def self.parse_options(tokens : Array(String)) : Hash(String, String)
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

      private def self.print_usage(code : Int32) : Int32
        puts <<-USAGE
        dinitctl (Litin Dinit compatibility layer)

        Commands:
          start <service...>           Start services
          stop  <service...>           Stop services
          restart <service...>         Restart services
          wake  <service...>           Alias for start
          release <service...>         Alias for stop
          status [service...]          Show status
          is-started <service>         Exit 0 if running
          is-failed  <service>         Exit 0 if failed
          list                         List all services
          enable  <service...>         Enable services
          disable <service...>         Disable services
          trigger <service>            Trigger a oneshot service
          reload                       Reload service definitions
          shutdown [--reboot|--poweroff|--halt]

        Note: add-dep / rm-dep require editing service files and reload-daemon.
        USAGE
        code
      end
    end
  end
end
