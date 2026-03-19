# src/litind.cr
#
# litind — the Litin supervisor daemon.
#
# This is the "smart" half of Litin. Runs as a child of litin-init
# (or directly as PID 1 for testing). Owns:
#
#   - Loading service, socket, timer, and target definitions
#   - Building and maintaining the dependency graph
#   - Starting services in parallel dependency waves
#   - Delegating per-service lifecycle to Supervisor fibers
#   - Managing per-service cgroup v2 slices
#   - Socket activation via the Socket::Manager
#   - Timer scheduling via the Timer::Scheduler
#   - Listening on a UNIX socket for litinctl/compat tool commands
#   - Streaming log output to connected IPC clients (logs --follow)
#   - Exposing structured status (JSON and human-readable)
#   - Handling daemon reload (SIGHUP) without restarting services
#   - Ordered shutdown (stop waves in reverse dependency order)

require "./core/signals"
require "./core/ipc"
require "./config/parser"
require "./config/service_definition"
require "./config/target"
require "./service/state"
require "./service/supervisor"
require "./graph/dependency"
require "./cgroup/manager"
require "./socket/activation"
require "./timer/scheduler"
require "./log/capture"

module Litin
  class Daemon
    SOCKET_PATH  = IPC::SOCKET_PATH
    SERVICES_DIR = Config::Loader::SERVICES_DIR
    SOCKETS_DIR  = Socket::SocketParser::SOCKETS_DIR
    TIMERS_DIR   = Timer::TimerParser::TIMERS_DIR
    TARGETS_DIR  = Config::TargetLoader::TARGETS_DIR

    def initialize
      @records = {} of String => Service::ServiceRecord
      @supervisors = {} of String => Service::Supervisor
      @graph = Graph::DependencyGraph.new
      @targets = [] of Config::TargetDefinition

      @state_ch = Channel(Service::ServiceRecord).new(128)
      @reload_ch = Channel(Nil).new(1)
      @shutdown_ch = Channel(Signals::ShutdownReason).new(1)

      # Log-follow subscribers: service_name => array of response channels.
      @log_followers = {} of String => Array(Channel(String))
      @log_mutex = Mutex.new

      @socket_manager = Socket::Manager.new(
        ->(service_name : String, bs : Socket::BoundSocket) {
          handle_socket_activation(service_name, bs)
        }
      )

      @timer_scheduler = Timer::Scheduler.new(
        ->(service_name : String) {
          start_service(service_name)
        }
      )
    end

    # ---------------------------------------------------------------------------
    # Entry point
    # ---------------------------------------------------------------------------

    def run : Nil
      STDOUT.puts "[litind] starting (pid=#{Process.pid})"

      Signals.setup_litind(@reload_ch, @shutdown_ch)
      Service.start_reaper
      CGroup.setup

      load_all_definitions

      boot_default_target

      start_socket_manager
      start_timer_scheduler
      start_ipc_server

      main_loop
    end

    # ---------------------------------------------------------------------------
    # Definition loading
    # ---------------------------------------------------------------------------

    def load_all_definitions : Nil
      load_services
      load_targets
    end

    def load_services : Nil
      sdefs = Config::Loader.load_all(SERVICES_DIR)
      STDOUT.puts "[litind] loaded #{sdefs.size} service definition(s)"

      @graph = Graph::DependencyGraph.new
      @graph.add_all(sdefs)

      sdefs.each do |sdef|
        next if @records.has_key?(sdef.name)
        @records[sdef.name] = Service::ServiceRecord.new(sdef.name, sdef)
      end
    end

    def load_targets : Nil
      @targets = Config::TargetLoader.load_all(TARGETS_DIR)
      STDOUT.puts "[litind] loaded #{@targets.size} target(s)"
    end

    # ---------------------------------------------------------------------------
    # Boot sequence
    # ---------------------------------------------------------------------------

    def boot_default_target : Nil
      begin
        waves = @graph.start_order
      rescue ex : Graph::CycleError
        STDERR.puts "[litind] FATAL dependency cycle: #{ex.message}"
        return
      end

      enabled_waves = waves.map do |wave|
        wave.select do |name|
          rec = @records[name]?
          rec && !rec.definition.masked && rec.definition.enabled
        end
      end.reject(&.empty?)

      STDOUT.puts "[litind] boot: #{enabled_waves.size} wave(s)"

      enabled_waves.each_with_index do |wave, i|
        STDOUT.puts "[litind] wave #{i + 1}: #{wave.join(", ")}"
        wave.each { |name| start_service(name) }
        wait_for_wave(wave, timeout: 120.seconds)
      end

      STDOUT.puts "[litind] boot complete"
    end

    private def wait_for_wave(names : Array(String), timeout : Time::Span) : Nil
      pending = names.to_set
      deadline = Time.utc + timeout

      while !pending.empty? && Time.utc < deadline
        select
        when rec = @state_ch.receive
          handle_state_change(rec)
          if pending.includes?(rec.name)
            pending.delete(rec.name) if rec.state == Service::State::Ready || rec.state.terminal?
          end
        when timeout(500.milliseconds)
        end
      end

      unless pending.empty?
        STDERR.puts "[litind] wave timeout — pending: #{pending.to_a.join(", ")}"
      end
    end

    # ---------------------------------------------------------------------------
    # Service lifecycle
    # ---------------------------------------------------------------------------

    def start_service(name : String) : Bool
      rec = @records[name]?
      return false unless rec
      return false if rec.definition.masked
      return true if rec.state.running?

      @graph.conflicts_for(name).each do |conflict|
        crec = @records[conflict]?
        if crec && crec.state.running?
          STDERR.puts "[litind] #{name}: conflicts with running #{conflict}"
          return false
        end
      end

      sup = @supervisors[name]? || begin
        s = Service::Supervisor.new(rec, Service::REAPER_CHANNEL, @state_ch)
        @supervisors[name] = s
        s
      end

      sup.start_fiber
      true
    end

    def stop_service(name : String, cascade : Bool = true) : Bool
      rec = @records[name]?
      return false unless rec
      return true if rec.state.terminal?

      if cascade
        @graph.dependents_of(name).each { |dep| stop_service(dep, cascade: false) }
      end

      sup = @supervisors[name]?
      return false unless sup

      sup.request_stop
      true
    end

    def restart_service(name : String) : Bool
      stop_service(name)
      sleep 500.milliseconds
      start_service(name)
    end

    def reload_service(name : String) : Bool
      rec = @records[name]?
      return false unless rec
      return false unless rec.state.running?

      if rec.definition.has_reload
        # Source the service file and call reload().
        pid = rec.pid
        source = rec.definition.source_path
        script = <<-SHELL
          . "#{source}"
          MAINPID=#{pid || ""}
          export MAINPID
          reload
        SHELL
        Process.run("/bin/sh", args: ["-c", script],
          output: Log::MANAGER.open_writer(name),
          error: Log::MANAGER.open_writer(name))
          .success?
      else
        # Default: SIGHUP.
        if pid = rec.pid
          Process.signal(Signal::HUP, pid) rescue false
          true
        else
          false
        end
      end
    end

    def enable_service(name : String, target : String = "default") : Bool
      rec = @records[name]?
      return false unless rec
      rec.definition.enabled = true
      wants_dir = "/etc/litin/targets/#{target}.wants"
      Dir.mkdir_p(wants_dir) rescue nil
      link = File.join(wants_dir, name)
      File.symlink(rec.definition.source_path, link) rescue nil unless File.exists?(link)
      true
    end

    def disable_service(name : String) : Bool
      rec = @records[name]?
      return false unless rec
      rec.definition.enabled = false
      Dir.glob("/etc/litin/targets/*.wants/#{name}") { |l| File.delete(l) rescue nil }
      true
    end

    def mask_service(name : String) : Bool
      rec = @records[name]?
      return false unless rec
      stop_service(name) if rec.state.running?
      rec.definition.masked = true
      Dir.mkdir_p("/etc/litin/masks") rescue nil
      File.symlink("/dev/null", "/etc/litin/masks/#{name}") rescue nil
      true
    end

    def unmask_service(name : String) : Bool
      rec = @records[name]?
      return false unless rec
      rec.definition.masked = false
      File.delete("/etc/litin/masks/#{name}") rescue nil
      true
    end

    # ---------------------------------------------------------------------------
    # Socket activation callback
    # ---------------------------------------------------------------------------

    private def handle_socket_activation(service_name : String, bs : Socket::BoundSocket) : Nil
      STDOUT.puts "[litind] socket activation: #{service_name} (#{bs.unit.listen})"
      start_service(service_name)
    end

    # ---------------------------------------------------------------------------
    # Socket and timer startup
    # ---------------------------------------------------------------------------

    private def start_socket_manager : Nil
      units = Socket::SocketParser.load_all(SOCKETS_DIR)
      return if units.empty?

      @socket_manager.bind_all(units)
      @socket_manager.start_listening
      STDOUT.puts "[litind] socket activation: #{units.size} socket(s) bound"
    end

    private def start_timer_scheduler : Nil
      @timer_scheduler.load_all(TIMERS_DIR)
      @timer_scheduler.start
    end

    # ---------------------------------------------------------------------------
    # IPC server
    # ---------------------------------------------------------------------------

    def start_ipc_server : Nil
      Dir.mkdir_p(File.dirname(SOCKET_PATH))
      File.delete(SOCKET_PATH) rescue nil

      server = UNIXServer.new(SOCKET_PATH)
      File.chmod(SOCKET_PATH, 0o600)

      spawn do
        loop do
          client = server.accept?
          break unless client
          spawn { handle_connection(IPC::Connection.new(client)) }
        end
      end

      STDOUT.puts "[litind] IPC: #{SOCKET_PATH}"
    end

    private def handle_connection(conn : IPC::Connection) : Nil
      req = conn.read_request
      unless req
        conn.close
        return
      end
      handle_request(req, conn)
    rescue ex
      conn.send_response(IPC::Response.err("internal error: #{ex.message}")) rescue nil
    ensure
      conn.close
    end

    private def handle_request(req : IPC::Request, conn : IPC::Connection) : Nil
      case req.action
      when "start"
        results = req.args.map do |name|
          @graph.required_by(name).each { |d| start_service(d) }
          ok = start_service(name)
          "#{name}: #{ok ? "started" : "failed or already running"}"
        end
        conn.send_response(IPC::Response.ok(results.join("\n")))
      when "stop"
        results = req.args.map do |name|
          ok = stop_service(name)
          "#{name}: #{ok ? "stopping" : "not running"}"
        end
        conn.send_response(IPC::Response.ok(results.join("\n")))
      when "restart"
        results = req.args.map do |name|
          ok = restart_service(name)
          "#{name}: #{ok ? "restarting" : "failed"}"
        end
        conn.send_response(IPC::Response.ok(results.join("\n")))
      when "reload"
        results = req.args.map do |name|
          ok = reload_service(name)
          "#{name}: #{ok ? "reloaded" : "reload not supported or not running"}"
        end
        conn.send_response(IPC::Response.ok(results.join("\n")))
      when "status"
        use_json = req.options["json"]? == "true"
        if req.args.empty?
          if use_json
            arr = @records.values.map { |r| JSON::Any.new(r.to_json_hash) }
            conn.send_response(IPC::Response.ok(data: JSON::Any.new(arr)))
          else
            lines = @records.values.sort_by(&.name).map(&.status_line)
            conn.send_response(IPC::Response.ok(lines.join("\n")))
          end
        else
          req.args.each do |name|
            rec = @records[name]?
            if rec
              if use_json
                conn.send_response(IPC::Response.ok(data: JSON::Any.new(rec.to_json_hash)))
              else
                conn.send_response(IPC::Response.ok(rec.status_line))
              end
            else
              conn.send_response(IPC::Response.err("unknown service: #{name}"))
            end
          end
        end
      when "enable"
        target = req.options["target"]? || "default"
        results = req.args.map do |name|
          ok = enable_service(name, target)
          "#{name}: #{ok ? "enabled in #{target}" : "not found"}"
        end
        conn.send_response(IPC::Response.ok(results.join("\n")))
      when "disable"
        results = req.args.map { |n| "#{n}: #{disable_service(n) ? "disabled" : "not found"}" }
        conn.send_response(IPC::Response.ok(results.join("\n")))
      when "mask"
        results = req.args.map { |n| "#{n}: #{mask_service(n) ? "masked" : "not found"}" }
        conn.send_response(IPC::Response.ok(results.join("\n")))
      when "unmask"
        results = req.args.map { |n| "#{n}: #{unmask_service(n) ? "unmasked" : "not found"}" }
        conn.send_response(IPC::Response.ok(results.join("\n")))
      when "deps"
        name = req.args.first?
        unless name
          conn.send_response(IPC::Response.err("deps: service name required"))
          return
        end
        requires = @graph.required_by(name)
        required_by = @graph.dependents_of(name)
        conflicts = @graph.conflicts_for(name).to_a
        payload = "requires:     #{requires.join(", ")}\n" \
                  "required_by:  #{required_by.join(", ")}\n" \
                  "conflicts:    #{conflicts.join(", ")}"
        conn.send_response(IPC::Response.ok(payload))
      when "graph"
        name = req.args.first?
        conn.send_response(IPC::Response.ok(@graph.to_dot(highlight: name)))
      when "list"
        lines = @records.values.sort_by(&.name).map do |rec|
          "#{rec.state.to_s.ljust(10)}  #{rec.name}"
        end
        conn.send_response(IPC::Response.ok(lines.join("\n")))
      when "list-targets"
        handle_list_targets(conn)
      when "logs"
        handle_logs_request(req, conn)
        # Note: handle_logs_request manages the connection lifetime for --follow.
        # We return early to prevent the ensure conn.close in the caller.
        return
      when "reload-daemon"
        spawn { load_all_definitions }
        conn.send_response(IPC::Response.ok("reloading definitions"))
      when "shutdown"
        reason = case req.options["mode"]?
                 when "reboot"   then Signals::ShutdownReason::Reboot
                 when "poweroff" then Signals::ShutdownReason::PowerOff
                 else                 Signals::ShutdownReason::Halt
                 end
        conn.send_response(IPC::Response.ok("initiating #{reason}"))
        @shutdown_ch.send(reason) rescue nil
      else
        conn.send_response(IPC::Response.err("unknown action: #{req.action}"))
      end

      conn.close
    end

    # ---------------------------------------------------------------------------
    # list-targets
    # ---------------------------------------------------------------------------

    private def handle_list_targets(conn : IPC::Connection) : Nil
      lines = @targets.map do |t|
        member_count = t.wants.size
        "#{t.name.ljust(20)}  #{t.description.ljust(40)}  #{member_count} service(s)"
      end
      conn.send_response(IPC::Response.ok(lines.join("\n")))
    end

    # ---------------------------------------------------------------------------
    # Streaming log handler
    # ---------------------------------------------------------------------------

    private def handle_logs_request(req : IPC::Request, conn : IPC::Connection) : Nil
      name = req.args.first?
      unless name
        conn.send_response(IPC::Response.err("logs: service name required"))
        conn.close
        return
      end

      unless @records.has_key?(name)
        conn.send_response(IPC::Response.err("unknown service: #{name}"))
        conn.close
        return
      end

      follow = req.options["follow"]? == "true"
      num_lines = req.options["lines"]?.try(&.to_i?) || 50
      since_str = req.options["since"]?

      # Send historical lines first.
      historical = Log::MANAGER.tail(name, num_lines)

      # Apply --since filter if present.
      if since_str
        since_time = parse_since(since_str)
        if since_time
          historical = historical.select do |line|
            # Log lines start with an RFC3339 timestamp.
            ts_end = line.index("  ")
            if ts_end
              ts = Time.parse_rfc3339(line[0...ts_end]) rescue nil
              ts ? ts >= since_time : true
            else
              true
            end
          end
        end
      end

      historical.each do |line|
        conn.send_response(IPC::Response.new(ok: true, done: false, payload: line))
      end

      unless follow
        conn.send_response(IPC::Response.ok("", done: true))
        conn.close
        return
      end

      # --follow: subscribe to new log lines.
      line_ch = Channel(String).new(256)

      @log_mutex.synchronize do
        @log_followers[name] ||= [] of Channel(String)
        @log_followers[name] << line_ch
      end

      # Stream lines until the client disconnects or sends an empty line.
      spawn do
        Log::MANAGER.follow(name, line_ch)
      end

      spawn do
        loop do
          select
          when line = line_ch.receive
            begin
              conn.send_response(IPC::Response.new(ok: true, done: false, payload: line))
            rescue
              break
            end
          when timeout(30.seconds)
            # Keepalive: send an empty non-done frame.
            begin
              conn.send_response(IPC::Response.new(ok: true, done: false, payload: ""))
            rescue
              break
            end
          end
        end

        @log_mutex.synchronize do
          @log_followers[name]?.try(&.delete(line_ch))
        end
        line_ch.close rescue nil
        conn.close rescue nil
      end
    end

    private def parse_since(s : String) : Time?
      # Accept: "5m", "1h", "2d", or an ISO8601 timestamp.
      s = s.strip
      if m = s.match(/^(\d+)(m|min|h|hr|d|day)$/)
        n = m[1].to_i
        unit = m[2]
        delta = case unit
                when "m", "min" then n.minutes
                when "h", "hr"  then n.hours
                when "d", "day" then n.days
                else                 n.minutes
                end
        return Time.utc - delta
      end
      Time.parse_rfc3339(s) rescue nil
    end

    # ---------------------------------------------------------------------------
    # Main event loop
    # ---------------------------------------------------------------------------

    def main_loop : Nil
      loop do
        select
        when rec = @state_ch.receive
          handle_state_change(rec)
        when @reload_ch.receive
          STDOUT.puts "[litind] SIGHUP — reloading definitions"
          load_all_definitions
        when reason = @shutdown_ch.receive
          STDOUT.puts "[litind] shutdown (#{reason})"
          perform_shutdown(reason)
          break
        when timeout(5.seconds)
          # Periodic tick: nothing to do right now.
          # Future: emit metrics, check for definition file changes, etc.
        end
      end
    end

    private def handle_state_change(rec : Service::ServiceRecord) : Nil
      t = rec.transitions.last?
      if t
        STDOUT.puts "[litind] #{rec.name}: #{t.from} -> #{t.to}" \
                    "#{t.reason.empty? ? "" : " (#{t.reason})"}"
      end

      # Auto-restart failed required services.
      if rec.state == Service::State::Failed
        sdef = rec.definition
        if sdef.restart != Config::RestartPolicy::No && !rec.admin_stopped
          # The supervisor handles the restart loop itself; this is just a log.
          STDOUT.puts "[litind] #{rec.name}: restart policy active (#{sdef.restart})"
        end
      end
    end

    # ---------------------------------------------------------------------------
    # Shutdown
    # ---------------------------------------------------------------------------

    def perform_shutdown(reason : Signals::ShutdownReason) : Nil
      STDOUT.puts "[litind] stopping all services"

      begin
        waves = @graph.stop_order
      rescue
        waves = [@records.keys]
      end

      waves.each do |wave|
        running = wave.select { |n| @records[n]?.try(&.state.running?) }
        next if running.empty?
        running.each { |name| stop_service(name, cascade: false) }
        # Give each wave up to 15 seconds to drain.
        deadline = Time.utc + 15.seconds
        until running.all? { |n| @records[n]?.try(&.state.terminal?) } || Time.utc > deadline
          sleep 500.milliseconds
        end
      end

      STDOUT.puts "[litind] all services stopped"
    end
  end
end

Litin::Daemon.new.run
