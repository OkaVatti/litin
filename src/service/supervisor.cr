# src/service/supervisor.cr
#
# Per-service supervisor.
#
# Each active service gets one Supervisor instance running in its own
# Crystal fiber. Responsibilities:
#
#   - Running pre/post hooks via /bin/sh
#   - Forking and exec'ing the service process
#   - Creating and managing the per-service cgroup v2 slice
#   - Assigning the process to its cgroup immediately after fork
#   - Monitoring the process via the shared REAPER_CHANNEL
#   - Applying the restart policy on exit
#   - Running a periodic healthcheck loop when has_healthcheck is set
#   - Updating the ServiceRecord state machine and broadcasting transitions
#   - Cleaning up the cgroup on service exit
#
# Environment layering (lowest to highest precedence):
#   1. Inherited process environment
#   2. /etc/litin/env/  (global env dir)
#   3. <service_dir>/env/  (service-specific env dir, runit-compatible)
#   4. environment= array in the service definition
#   5. Litin-injected vars (NOTIFY_SOCKET, MAINPID, LITIN_CGROUP)

require "./state"
require "../config/service_definition"
require "../cgroup/manager"
require "../log/capture"
require "../util/env_dir"
require "./healthcheck"
require "../core/libc"

module Litin
  module Service
    # Posted by the global reaper when a child exits.
    struct ExitEvent
      getter pid : Int32
      getter exit_code : Int32
      getter success : Bool

      def initialize(@pid : Int32, raw_wstatus : Int32)
        # Decode POSIX wstatus from waitpid(2) manually, because we cannot
        # construct a Process::Status from a raw wstatus integer in Crystal
        # 1.19.1 via a public API.
        exited = (raw_wstatus & 0x7f) == 0
        @success = exited && ((raw_wstatus >> 8) & 0xff) == 0
        @exit_code = exited ? ((raw_wstatus >> 8) & 0xff) : -1
      end

      def status_success? : Bool
        @success
      end
    end

    # All Supervisor fibers share this channel. Each filters by its own PID.
    REAPER_CHANNEL = Channel(ExitEvent).new(128)

    NOTIFY_SOCK_DIR        = "/run/litin/notify"
    HEALTHCHECK_INTERVAL   = 30.seconds
    HEALTHCHECK_FAIL_LIMIT = 3

    class Supervisor
      getter record : ServiceRecord

      # Explicit type annotations for instance variables that are assigned
      # from method calls, so the compiler can infer the type.
      @log_writer : IO
      @fiber : Fiber?

      def initialize(
        @record : ServiceRecord,
        @exit_broadcast : Channel(ExitEvent),
        @state_change : Channel(ServiceRecord),
      )
        @stop_requested = Channel(Nil).new(1)
        @cgroup = CGroup::ServiceCGroup.new(@record.name)
        @log_writer = Log::MANAGER.open_writer(@record.name)
        @hc_failures = 0
      end

      def start_fiber : Nil
        @fiber = spawn { supervise_loop }
      end

      def request_stop : Nil
        @record.admin_stopped = true
        @stop_requested.send(nil) rescue nil
      end

      # ---------------------------------------------------------------------------
      # Main supervision loop
      # ---------------------------------------------------------------------------

      private def supervise_loop : Nil
        loop do
          break if @record.state == State::Masked || @record.state == State::Disabled

          # --- pre_start hook ---
          if @record.definition.has_pre_start
            unless run_hook("pre_start")
              @record.transition_to(State::Failed, "pre_start returned non-zero")
              notify_state_change
              break
            end
          end

          # --- Create cgroup before fork so assignment is immediate ---
          setup_cgroup

          # --- Launch process ---
          pid = exec_service
          if pid.nil?
            teardown_cgroup
            @record.transition_to(State::Failed, "exec failed")
            notify_state_change
            break unless attempt_restart
            next
          end

          @record.pid = pid
          @record.transition_to(State::Starting, "pid=#{pid}")
          notify_state_change

          assign_to_cgroup(pid)

          # --- Wait for readiness ---
          unless wait_for_readiness(pid)
            force_kill(pid)
            teardown_cgroup
            @record.transition_to(State::Failed,
              "readiness timeout (#{@record.definition.timeout_start}s)")
            notify_state_change
            break unless attempt_restart
            next
          end

          @record.transition_to(State::Ready, "pid=#{pid}")
          notify_state_change
          @hc_failures = 0

          # post_start is fire-and-forget.
          spawn { run_hook("post_start") } if @record.definition.has_post_start

          # Healthcheck polling fiber.
          spawn { healthcheck_loop(pid) } if @record.definition.has_healthcheck

          # --- Wait: exit or admin stop ---
          exit_event = wait_for_exit_or_stop(pid)

          if exit_event.nil?
            # Admin stop.
            graceful_stop(pid)
            teardown_cgroup
            @record.transition_to(State::Inactive, "stopped by administrator")
            @record.pid = nil
            notify_state_change
            run_hook("post_stop") if @record.definition.has_post_stop
            break
          end

          # Unexpected exit.
          @record.last_exit_code = exit_event.exit_code
          @record.pid = nil
          teardown_cgroup
          run_hook("post_stop") if @record.definition.has_post_stop

          should_restart = case @record.definition.restart
                           when Config::RestartPolicy::No            then false
                           when Config::RestartPolicy::Always        then true
                           when Config::RestartPolicy::OnFailure     then !exit_event.status_success?
                           when Config::RestartPolicy::UnlessStopped then !@record.admin_stopped
                           else                                           false
                           end

          if should_restart
            @record.restart_count += 1
            @record.transition_to(State::Starting,
              "restart ##{@record.restart_count} after #{@record.definition.restart_sec}s")
            notify_state_change
            sleep @record.definition.restart_sec.seconds
          else
            reason = exit_event.status_success? ? "exited (0)" : "exited (#{exit_event.exit_code})"
            @record.transition_to(State::Failed, reason)
            notify_state_change
            break
          end
        end
      end

      # ---------------------------------------------------------------------------
      # cgroup management
      # ---------------------------------------------------------------------------

      private def setup_cgroup : Nil
        return unless CGroup.available?
        @cgroup.create
        @cgroup.apply_limits(@record.definition.cgroup)
        @record.cgroup_path = @cgroup.path
      rescue ex
        STDERR.puts "[supervisor:#{@record.name}] cgroup setup failed: #{ex.message}"
      end

      private def assign_to_cgroup(pid : Int32) : Nil
        return unless CGroup.available?
        @cgroup.assign_pid(pid)
      rescue ex
        STDERR.puts "[supervisor:#{@record.name}] cgroup assign failed: #{ex.message}"
      end

      private def teardown_cgroup : Nil
        return unless CGroup.available?
        @cgroup.destroy
        @record.cgroup_path = nil
      rescue ex
        STDERR.puts "[supervisor:#{@record.name}] cgroup teardown failed: #{ex.message}"
      end

      # ---------------------------------------------------------------------------
      # Process execution
      # ---------------------------------------------------------------------------

      private def exec_service : Int32?
        sdef = @record.definition
        cmd = resolve_command(sdef) || return nil
        env = build_env(sdef)

        proc = Process.new(
          command: "/bin/sh",
          args: ["-c", cmd],
          env: env,
          chdir: sdef.working_dir || "/",
          input: Process::Redirect::Close,
          output: @log_writer,
          error: @log_writer
        )
        proc.pid.to_i32
      rescue ex
        STDERR.puts "[supervisor:#{@record.name}] spawn failed: #{ex.message}"
        nil
      end

      private def resolve_command(sdef : Config::ServiceDefinition) : String?
        return sdef.command if sdef.command
        if run = sdef.run_script
          return run if File::Info.executable?(run)
          STDERR.puts "[supervisor:#{sdef.name}] run script not executable: #{run}"
          return nil
        end
        STDERR.puts "[supervisor:#{sdef.name}] no command or run script defined"
        nil
      end

      private def build_env(sdef : Config::ServiceDefinition) : Hash(String, String)
        env = ENV.to_h

        # Global env dir.
        Util::EnvDir.read("/etc/litin/env").each { |k, v| env[k] = v }

        # Service-specific env dir.
        svc_env = File.join(File.dirname(sdef.source_path), "env")
        Util::EnvDir.read(svc_env).each { |k, v| env[k] = v }

        # Inline environment= declarations.
        sdef.environment.each do |pair|
          k, _, v = pair.partition('=')
          env[k.strip] = v
        end

        # Litin-injected variables.
        if sdef.type == Config::ServiceType::Notify
          env["NOTIFY_SOCKET"] = File.join(NOTIFY_SOCK_DIR, "#{sdef.name}.sock")
        end
        if pid = @record.pid
          env["MAINPID"] = pid.to_s
        end
        if cp = @record.cgroup_path
          env["LITIN_CGROUP"] = cp
        end

        env
      end

      # ---------------------------------------------------------------------------
      # Readiness protocols
      # ---------------------------------------------------------------------------

      private def wait_for_readiness(pid : Int32) : Bool
        sdef = @record.definition
        timeout = sdef.timeout_start.seconds

        case sdef.type
        when Config::ServiceType::Simple, Config::ServiceType::SocketActivated
          true
        when Config::ServiceType::Oneshot
          wait_pid_exit(pid, timeout)
        when Config::ServiceType::Forking
          wait_file(sdef.pid_file || "/run/#{sdef.name}.pid", timeout)
        when Config::ServiceType::Notify
          wait_notify(File.join(NOTIFY_SOCK_DIR, "#{sdef.name}.sock"), timeout)
        else
          true
        end
      end

      private def wait_pid_exit(pid : Int32, timeout : Time::Span) : Bool
        deadline = Time.utc + timeout
        loop do
          return false if Time.utc > deadline
          select
          when ev = @exit_broadcast.receive
            return ev.status_success? if ev.pid == pid
          when timeout(100.milliseconds)
          end
        end
      end

      private def wait_file(path : String, timeout : Time::Span) : Bool
        deadline = Time.utc + timeout
        until File.exists?(path)
          return false if Time.utc > deadline
          sleep 100.milliseconds
        end
        true
      end

      # Wait for sd_notify READY=1 on a UNIX socket.
      # Crystal 1.19.1 has no UNIXServer#accept_timeout; we use a
      # select loop with a manual deadline instead.
      private def wait_notify(socket_path : String, timeout : Time::Span) : Bool
        Dir.mkdir_p(NOTIFY_SOCK_DIR)
        File.delete(socket_path) rescue nil
        server = UNIXServer.new(socket_path)
        server.read_timeout = timeout

        begin
          conn = server.accept?
          return false unless conn
          conn.read_timeout = timeout
          ready = conn.gets.to_s.includes?("READY=1")
          conn.close
          ready
        rescue IO::TimeoutError
          false
        rescue ex
          STDERR.puts "[supervisor:#{@record.name}] notify error: #{ex.message}"
          false
        ensure
          server.close rescue nil
          File.delete(socket_path) rescue nil
        end
      end

      # ---------------------------------------------------------------------------
      # Wait for exit or stop
      # ---------------------------------------------------------------------------

      private def wait_for_exit_or_stop(pid : Int32) : ExitEvent?
        loop do
          select
          when ev = @exit_broadcast.receive
            return ev if ev.pid == pid
          when @stop_requested.receive
            return nil
          end
        end
      end

      # ---------------------------------------------------------------------------
      # Process termination
      # ---------------------------------------------------------------------------

      private def graceful_stop(pid : Int32) : Nil
        @record.transition_to(State::Stopping, "SIGTERM sent")
        notify_state_change

        Process.signal(Signal::TERM, pid) rescue nil

        deadline = Time.utc + @record.definition.timeout_stop.seconds
        loop do
          break if Time.utc > deadline
          select
          when ev = @exit_broadcast.receive
            return if ev.pid == pid
          when timeout(200.milliseconds)
          end
        end

        STDERR.puts "[supervisor:#{@record.name}] SIGTERM timeout — killing cgroup"
        force_kill(pid)
      end

      private def force_kill(pid : Int32) : Nil
        if CGroup.available? && @record.cgroup_path
          @cgroup.kill_all
        else
          Process.signal(Signal::KILL, pid) rescue nil
        end
      end

      # ---------------------------------------------------------------------------
      # Hook execution
      # ---------------------------------------------------------------------------

      private def run_hook(hook_name : String) : Bool
        path = @record.definition.source_path
        return true if path.empty?

        script = <<-SHELL
          . "#{path}"
          MAINPID=#{@record.pid || ""}
          export MAINPID
          #{hook_name}
        SHELL

        Process.run(
          "/bin/sh",
          args: ["-c", script],
          env: build_env(@record.definition),
          output: @log_writer,
          error: @log_writer
        ).success?
      rescue ex
        STDERR.puts "[supervisor:#{@record.name}] hook #{hook_name}: #{ex.message}"
        false
      end

      # ---------------------------------------------------------------------------
      # Healthcheck polling
      # ---------------------------------------------------------------------------

      private def healthcheck_loop(expected_pid : Int32) : Nil
        loop do
          sleep HEALTHCHECK_INTERVAL
          break unless @record.state.running?
          break if @record.pid != expected_pid

          if run_healthcheck
            @hc_failures = 0
            if @record.state == State::Degraded
              @record.transition_to(State::Ready, "healthcheck recovered")
              notify_state_change
            end
          else
            @hc_failures += 1
            STDERR.puts "[supervisor:#{@record.name}] healthcheck failed " \
                        "(#{@hc_failures}/#{HEALTHCHECK_FAIL_LIMIT})"
            if @hc_failures >= HEALTHCHECK_FAIL_LIMIT && @record.state == State::Ready
              @record.transition_to(State::Degraded,
                "healthcheck failed #{@hc_failures} consecutive times")
              notify_state_change
            end
          end
        end
      end

      private def run_healthcheck : Bool
        HealthProbe.new(@record.definition, @record.pid, build_env(@record.definition)).run
      end

      # ---------------------------------------------------------------------------
      # Restart helper
      # ---------------------------------------------------------------------------

      private def attempt_restart : Bool
        return false if @record.definition.restart == Config::RestartPolicy::No
        sleep @record.definition.restart_sec.seconds
        @record.restart_count += 1
        @record.transition_to(State::Starting, "retry ##{@record.restart_count}")
        notify_state_change
        true
      end

      private def notify_state_change : Nil
        @state_change.send(@record) rescue nil
      end
    end

    # ---------------------------------------------------------------------------
    # Global zombie reaper — single fiber, shared across all supervisors.
    # ---------------------------------------------------------------------------

    def self.start_reaper : Nil
      spawn do
        Signal::CHLD.trap { collect_exits }
        loop do
          sleep 1.second
          collect_exits
        end
      end
    end

    def self.collect_exits : Nil
      loop do
        pid = LibC.waitpid(-1, out raw_status, LibC::WNOHANG)
        break if pid <= 0
        REAPER_CHANNEL.send(ExitEvent.new(pid.to_i32, raw_status)) rescue nil
      end
    end
  end
end
