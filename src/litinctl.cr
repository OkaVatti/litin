# src/litinctl.cr
#
# litinctl — Litin control tool.
#
# Communicates with litind over /run/litin/litind.sock.
#
# Command summary:
#   start / stop / restart / reload  <service...>
#   status [service...] [--json]
#   enable / disable / mask / unmask  <service...> [--target=NAME]
#   list [--json]
#   list-targets
#   deps <service>
#   graph [service]
#   logs <service> [--follow] [--lines=N] [--since=EXPR]
#   reload-daemon
#   shutdown / reboot / poweroff [--mode=...]
#   version / help

require "./core/ipc"

module Litin
  module CLI
    # ANSI escape codes — active only when stdout is a TTY.
    USE_COLOR = STDOUT.tty?

    private def self.c(s : String, code : String) : String
      USE_COLOR ? "#{code}#{s}\e[0m" : s
    end

    BOLD   = "\e[1m"
    DIM    = "\e[2m"
    RED    = "\e[31m"
    GREEN  = "\e[32m"
    YELLOW = "\e[33m"
    BLUE   = "\e[34m"
    CYAN   = "\e[36m"
    GREY   = "\e[90m"

    # State -> colour mapping.
    STATE_COLOR = {
      "ready"    => GREEN,
      "starting" => YELLOW,
      "stopping" => YELLOW,
      "degraded" => YELLOW,
      "failed"   => RED,
      "inactive" => GREY,
      "disabled" => GREY,
      "masked"   => GREY,
    }

    def self.run(argv : Array(String)) : Int32
      return print_usage_and_exit(0) if argv.empty?

      action = argv[0]
      args = argv[1..].reject { |a| a.starts_with?("--") }
      options = parse_options(argv[1..])

      case action
      when "help", "--help", "-h" then return print_usage_and_exit(0)
      when "version", "--version" then puts "litinctl 0.1.0"; return 0
      end

      # Commands that do not need the IPC socket.
      if action == "shutdown" && options["force"]? == "true"
        mode = options["mode"]? || "halt"
        sig = case mode
              when "reboot"   then Signal::INT
              when "poweroff" then Signal::USR2
              else                 Signal::TERM
              end
        Process.signal(sig, 1)
        return 0
      end

      begin
        client = IPC::Client.new
      rescue ex
        STDERR.puts c("error: cannot connect to litind (#{IPC::SOCKET_PATH})", RED)
        STDERR.puts c("       is litind running? try: litinctl status", GREY)
        return 1
      end

      code = dispatch(client, action, args, options)
      client.close rescue nil
      code
    end

    # ---------------------------------------------------------------------------
    # Dispatch
    # ---------------------------------------------------------------------------

    private def self.dispatch(
      client : IPC::Client,
      action : String,
      args : Array(String),
      options : Hash(String, String),
    ) : Int32
      case action
      when "start", "stop", "restart", "reload",
           "enable", "disable", "mask", "unmask"
        if args.empty?
          STDERR.puts c("error: #{action} requires at least one service name", RED)
          return 1
        end
        generic_call(client, action, args, options)
      when "status"
        status_command(client, args, options)
      when "status-detail"
        # Detailed multi-line status for one or more services.
        opts = options.merge({"detail" => "true"})
        status_command(client, args, opts)
      when "cat"
        # Print the raw service definition file.
        if args.empty?
          STDERR.puts c("error: cat requires a service name", RED)
          return 1
        end
        cat_command(client, args[0])
      when "list"
        list_command(client, options)
      when "list-targets"
        generic_call(client, "list-targets", [] of String, options)
      when "deps"
        if args.empty?
          STDERR.puts c("error: deps requires a service name", RED)
          return 1
        end
        generic_call(client, "deps", args, options)
      when "graph"
        generic_call(client, "graph", args, options)
      when "logs"
        if args.empty?
          STDERR.puts c("error: logs requires a service name", RED)
          return 1
        end
        logs_command(client, args[0], options)
      when "journal"
        journal_command(client, args, options)
      when "reload-daemon"
        generic_call(client, "reload-daemon", [] of String, options)
      when "shutdown"
        opts = options.merge({"mode" => options["mode"]? || "halt"})
        generic_call(client, "shutdown", [] of String, opts)
      when "reboot"
        generic_call(client, "shutdown", [] of String, {"mode" => "reboot"})
      when "poweroff"
        generic_call(client, "shutdown", [] of String, {"mode" => "poweroff"})
      else
        STDERR.puts c("error: unknown command '#{action}'", RED)
        STDERR.puts "Run 'litinctl help' for usage."
        1
      end
    end

    # ---------------------------------------------------------------------------
    # status command — rich formatted output
    # ---------------------------------------------------------------------------

    private def self.status_command(
      client : IPC::Client,
      args : Array(String),
      options : Hash(String, String),
    ) : Int32
      use_json = options["json"]? == "true"
      opts = use_json ? options.merge({"json" => "true"}) : options
      exit_code = 0

      client.request("status", args, opts) do |resp|
        unless resp.ok
          STDERR.puts c("error: #{resp.payload}", RED)
          exit_code = 1
          next
        end

        if use_json
          if data = resp.data
            puts data.to_json
          elsif !resp.payload.empty?
            puts resp.payload
          end
        else
          resp.payload.each_line do |line|
            next if line.empty?
            puts format_status_line(line)
          end
        end
      end

      exit_code
    end

    private def self.format_status_line(line : String) : String
      # Line format from ServiceRecord#status_line:
      #   "name: state  pid=N  uptime=Xs  ..."
      return line unless line.includes?(": ")
      name_part, rest = line.split(": ", 2)
      tokens = rest.split(/\s+/)
      state_token = tokens[0]? || "unknown"
      extra = tokens[1..].join("  ")

      col = STATE_COLOR[state_token]? || GREY
      dot = state_token == "ready" ? c("●", GREEN) : c("●", col)

      "#{dot}  #{c(name_part.ljust(26), BOLD)}  #{c(state_token.ljust(10), col)}  #{c(extra, GREY)}"
    end

    # ---------------------------------------------------------------------------
    # list command
    # ---------------------------------------------------------------------------

    private def self.list_command(
      client : IPC::Client,
      options : Hash(String, String),
    ) : Int32
      use_json = options["json"]? == "true"
      exit_code = 0

      client.request("list", [] of String, options) do |resp|
        unless resp.ok
          STDERR.puts c("error: #{resp.payload}", RED)
          exit_code = 1
          next
        end

        if use_json
          if data = resp.data
            puts data.to_json
          end
        else
          resp.payload.each_line do |line|
            next if line.empty?
            parts = line.split(/\s+/, 2)
            state = parts[0]? || ""
            name = parts[1]? || ""
            col = STATE_COLOR[state]? || GREY
            puts "#{c(state.ljust(10), col)}  #{name}"
          end
        end
      end

      exit_code
    end

    # ---------------------------------------------------------------------------
    # logs command — tail and follow
    # ---------------------------------------------------------------------------

    private def self.logs_command(
      client : IPC::Client,
      service : String,
      options : Hash(String, String),
    ) : Int32
      follow = options["follow"]? == "true" || options["f"]? == "true"
      lines = options["lines"]? || options["n"]? || "50"
      since = options["since"]?

      opts = {"lines" => lines, "follow" => follow.to_s}
      opts["since"] = since if since

      # For follow mode we need to handle Ctrl+C gracefully.
      interrupted = false
      if follow
        Signal::INT.trap { interrupted = true }
        Signal::TERM.trap { interrupted = true }
      end

      exit_code = 0
      service_label = c(service, CYAN)

      client.request("logs", [service], opts) do |resp|
        break if interrupted

        unless resp.ok
          STDERR.puts c("error: #{resp.payload}", RED)
          exit_code = 1
          next
        end

        # Empty keepalive frames during --follow.
        next if resp.payload.empty? && !resp.done

        unless resp.payload.empty?
          # Dim the timestamp prefix, normal text for the message.
          line = resp.payload.chomp
          if line.size > 26 && line[10] == 'T'
            ts = line[0, 26]
            body = line[26..]
            puts "#{c(ts, GREY)}  #{body}"
          else
            puts line
          end
        end
      end

      exit_code
    end

    # ---------------------------------------------------------------------------
    # cat command — print the raw service definition file
    # ---------------------------------------------------------------------------

    private def self.cat_command(client : IPC::Client, service : String) : Int32
      exit_code = 0
      client.request("status", [service], {"json" => "true"}) do |resp|
        unless resp.ok
          STDERR.puts c("error: #{resp.payload}", RED)
          exit_code = 1
          next
        end
        data = resp.data
        next unless data
        source = data["source_path"]?.try(&.as_s?)
        unless source && !source.empty?
          STDERR.puts c("error: no source file path available for #{service}", RED)
          exit_code = 1
          next
        end
        unless File.exists?(source)
          STDERR.puts c("error: service file not found: #{source}", RED)
          exit_code = 1
          next
        end
        puts c("# #{source}", GREY)
        print File.read(source)
      end
      exit_code
    rescue ex
      STDERR.puts c("error: #{ex.message}", RED)
      1
    end

    # ---------------------------------------------------------------------------

    private def self.journal_command(
      client : IPC::Client,
      args : Array(String),
      options : Hash(String, String),
    ) : Int32
      opts = options.dup
      # If a service name was given as a positional arg, pass it as service= option.
      opts["service"] = args[0] if args[0]?

      exit_code = 0
      client.request("journal", [] of String, opts) do |resp|
        unless resp.ok
          STDERR.puts c("error: #{resp.payload}", RED)
          exit_code = 1
          next
        end
        if data = resp.data
          puts data.to_json
        else
          resp.payload.each_line { |l| puts l unless l.empty? }
        end
      end
      exit_code
    end

    # ---------------------------------------------------------------------------

    private def self.generic_call(
      client : IPC::Client,
      action : String,
      args : Array(String),
      options : Hash(String, String),
    ) : Int32
      exit_code = 0

      client.request(action, args, options) do |resp|
        if resp.ok
          puts resp.payload unless resp.payload.empty?
          if data = resp.data
            puts data.to_json
          end
        else
          STDERR.puts c("error: #{resp.payload}", RED)
          exit_code = 1
        end
      end

      exit_code
    end

    # ---------------------------------------------------------------------------
    # Option parsing
    # ---------------------------------------------------------------------------

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

    # ---------------------------------------------------------------------------
    # Usage
    # ---------------------------------------------------------------------------

    private def self.print_usage_and_exit(code : Int32) : Int32
      puts <<-USAGE
      #{c("litinctl", BOLD)} — Litin init system control tool

      #{c("Service management:", BOLD)}
        start   <service...>               Start service(s) and their dependencies
        stop    <service...>               Stop service(s) (cascades to dependents)
        restart <service...>               Stop then start
        reload  <service...>               Reload config (custom hook or SIGHUP)

      #{c("Status and inspection:", BOLD)}
        status  [service...] [--json]      Show status (all or specific)
        list    [--json]                   List all services with state
        list-targets                       List targets and their member counts
        deps    <service>                  Show dependency relationships
        graph   [service]                  Dependency graph in DOT format

      #{c("Logs:", BOLD)}
        logs    <service>                  Show recent log lines
                [--follow | -f]            Stream new lines (Ctrl+C to stop)
                [--lines=N | -n N]         Number of historical lines (default 50)
                [--since=EXPR]             Show lines since: 5m, 2h, 1d, or ISO8601

      #{c("Event journal:", BOLD)}
        journal [service]                  Show structured event history
                [--lines=N]                Number of events (default 100)
                [--since=EXPR]             Filter by time
                [--kind=state_change|...]  Filter by event kind
                [--json]                   Structured JSON output

      #{c("Enablement:", BOLD)}
        enable  <service...> [--target=T]  Enable for automatic start
        disable <service...>               Disable automatic start
        mask    <service...>               Block all start attempts
        unmask  <service...>               Remove mask

      #{c("System:", BOLD)}
        reload-daemon                      Reload service definitions (no restart)
        shutdown  [--mode=halt|reboot|poweroff]
        reboot
        poweroff

      #{c("Options:", BOLD)}
        --json                             Structured JSON output
        --quiet                            Exit code only
        --target=NAME                      Target for enable (default: default)
        --follow, -f                       Follow log output
        --lines=N, -n N                    Log line count
        --since=EXPR                       Log time filter

      #{c("Examples:", BOLD)}
        litinctl start nginx
        litinctl status --json
        litinctl logs nginx --follow
        litinctl logs sshd --lines=100 --since=1h
        litinctl graph nginx | dot -Tsvg > nginx-deps.svg
        litinctl enable nginx --target=default
      USAGE
      code
    end
  end
end

exit Litin::CLI.run(ARGV)
