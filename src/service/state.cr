# src/service/state.cr
#
# Service state machine.
#
# State transition table:
#
#   inactive  -> starting    admin starts it, or dep chain starts it
#   starting  -> ready       readiness protocol satisfied
#   starting  -> failed      process exits before ready, or timeout
#   ready     -> stopping    admin stops it, or conflicting service starts
#   ready     -> degraded    healthcheck fails HEALTHCHECK_FAIL_LIMIT times
#   ready     -> starting    process dies, restart policy triggers restart
#   degraded  -> ready       healthcheck passes again
#   degraded  -> stopping    admin stops it
#   stopping  -> inactive    process exited cleanly after SIGTERM
#   stopping  -> inactive    SIGKILL forced after timeout
#   failed    -> starting    admin manually retries
#   inactive  -> disabled    admin disables it
#   disabled  -> inactive    admin enables it
#   *         -> masked      admin masks it (overrides all)
#   masked    -> inactive    admin unmasks it

require "json"

module Litin
  module Service
    enum State
      Inactive # not running, no error
      Starting # launched, waiting for readiness confirmation
      Ready    # running and healthy
      Stopping # shutting down gracefully
      Failed   # exited with error; restart policy says no more restarts
      Degraded # running but healthcheck failing
      Disabled # not enabled to start automatically
      Masked   # completely blocked from starting

      def to_s : String
        super.downcase
      end

      def running? : Bool
        self == Ready || self == Degraded || self == Starting
      end

      def terminal? : Bool
        self == Failed || self == Inactive || self == Disabled || self == Masked
      end

      # Returns true when a service in this state will not restart
      # by itself — only an operator action can move it forward.
      def quiescent? : Bool
        terminal?
      end
    end

    # One timestamped entry in a service's state-change history.
    struct Transition
      getter from : State
      getter to : State
      getter at : Time
      getter reason : String

      def initialize(@from, @to, @at = Time.utc, @reason = "")
      end

      def to_s(io : IO)
        io << at.to_rfc3339(fraction_digits: 3)
        io << "  " << from.to_s.ljust(10)
        io << " -> " << to.to_s.ljust(10)
        io << "  " << reason unless reason.empty?
      end
    end

    # Runtime record for one service — mutable, supervisor-owned.
    class ServiceRecord
      MAX_TRANSITION_HISTORY = 64

      getter name : String
      getter definition : Config::ServiceDefinition

      property state : State = State::Inactive
      property pid : Int32? = nil
      property cgroup_path : String? = nil

      property started_at : Time? = nil
      property stopped_at : Time? = nil
      property last_exit_code : Int32? = nil
      property restart_count : Int32 = 0
      property failure_reason : String = ""

      property transitions : Array(Transition)

      # Whether the last stop was admin-requested (vs unexpected exit).
      # Used by the UnlessStopped restart policy.
      property admin_stopped : Bool = false

      def initialize(@name, @definition)
        @transitions = [] of Transition
      end

      # -----------------------------------------------------------------------
      # State machine
      # -----------------------------------------------------------------------

      def transition_to(new_state : State, reason : String = "") : Nil
        old = @state
        entry = Transition.new(from: old, to: new_state, reason: reason)
        @transitions << entry

        # Keep history bounded.
        @transitions.shift if @transitions.size > MAX_TRANSITION_HISTORY

        @state = new_state

        case new_state
        when State::Ready
          @started_at = Time.utc
          @failure_reason = ""
        when State::Failed
          @stopped_at = Time.utc
          @failure_reason = reason
        when State::Inactive
          @stopped_at = Time.utc
        end
      end

      # -----------------------------------------------------------------------
      # Derived properties
      # -----------------------------------------------------------------------

      def uptime : Time::Span?
        s = @started_at
        return nil unless s
        return nil unless @state.running?
        Time.utc - s
      end

      def enabled? : Bool
        definition.enabled
      end

      def masked? : Bool
        definition.masked
      end

      # -----------------------------------------------------------------------
      # Human-readable output
      # -----------------------------------------------------------------------

      # Single-line status suitable for `litinctl status` and `litinctl list`.
      # Format: "name: state  pid=N  uptime=Xs  restarts=N  last_exit=N"
      def status_line : String
        parts = ["#{name}: #{state}"]

        if p = pid
          parts << "pid=#{p}"
        end

        if u = uptime
          parts << "uptime=#{format_duration(u)}"
        end

        if rc = last_exit_code
          parts << "last_exit=#{rc}"
        end

        if restart_count > 0
          parts << "restarts=#{restart_count}"
        end

        parts.join("  ")
      end

      # Multi-line rich status (used by `litinctl status <service>` verbose mode).
      def status_detail : String
        io = String::Builder.new
        io << "● #{name} — #{definition.description.empty? ? "(no description)" : definition.description}\n"
        io << "    State:       #{state}\n"
        io << "    Type:        #{definition.type}\n"
        io << "    Target:      #{definition.target}\n"
        io << "    Enabled:     #{enabled?}\n"
        io << "    Masked:      #{masked?}\n"

        if p = pid
          io << "    PID:         #{p}\n"
        end

        if u = uptime
          io << "    Uptime:      #{format_duration(u)}\n"
        end

        if s = started_at
          io << "    Started:     #{s.to_rfc3339(fraction_digits: 0)}\n"
        end

        if s = stopped_at
          io << "    Stopped:     #{s.to_rfc3339(fraction_digits: 0)}\n"
        end

        if rc = last_exit_code
          io << "    Last exit:   #{rc}\n"
        end

        if restart_count > 0
          io << "    Restarts:    #{restart_count}\n"
        end

        if !failure_reason.empty?
          io << "    Failure:     #{failure_reason}\n"
        end

        if cp = cgroup_path
          io << "    cgroup:      #{cp}\n"
        end

        if !definition.cgroup.cpu_max.nil? || definition.cgroup.memory_max
          io << "    Resources:   "
          parts = [] of String
          if definition.cgroup.cpu_max
            parts << "cpu=#{definition.cgroup.cpu_max}"
          end
          if definition.cgroup.memory_max
            parts << "mem=#{definition.cgroup.memory_max}"
          end
          if definition.cgroup.pids_max
            parts << "pids=#{definition.cgroup.pids_max}"
          end
          io << parts.join(" ") << "\n"
        end

        if t = transitions.last?
          io << "    Last event:  #{t.to_s}\n"
        end

        io.to_s
      end

      # -----------------------------------------------------------------------
      # JSON serialisation
      # -----------------------------------------------------------------------

      def to_json_hash : Hash(String, JSON::Any)
        h = {} of String => JSON::Any

        # Identity
        h["name"] = JSON::Any.new(name)
        h["description"] = JSON::Any.new(definition.description)

        # State
        h["state"] = JSON::Any.new(state.to_s)
        h["enabled"] = JSON::Any.new(enabled?)
        h["masked"] = JSON::Any.new(masked?)

        # Process
        h["pid"] = pid ? JSON::Any.new(pid.not_nil!.to_i64) : JSON::Any.new(nil)
        h["cgroup_path"] = cgroup_path ? JSON::Any.new(cgroup_path.not_nil!) : JSON::Any.new(nil)

        # Counters
        h["restart_count"] = JSON::Any.new(restart_count.to_i64)
        h["failure_reason"] = JSON::Any.new(failure_reason)

        # Timing
        h["started_at"] = started_at ? JSON::Any.new(started_at.not_nil!.to_rfc3339) : JSON::Any.new(nil)
        h["stopped_at"] = stopped_at ? JSON::Any.new(stopped_at.not_nil!.to_rfc3339) : JSON::Any.new(nil)
        h["uptime_seconds"] = uptime ? JSON::Any.new(uptime.not_nil!.total_seconds.to_i64) : JSON::Any.new(nil)
        h["last_exit_code"] = last_exit_code ? JSON::Any.new(last_exit_code.not_nil!.to_i64) : JSON::Any.new(nil)

        # Definition metadata
        h["type"] = JSON::Any.new(definition.type.to_s.downcase)
        h["restart"] = JSON::Any.new(definition.restart.to_s.downcase.gsub('_', '-'))
        h["target"] = JSON::Any.new(definition.target)
        h["command"] = definition.command ? JSON::Any.new(definition.command.not_nil!) : JSON::Any.new(nil)
        h["source_path"] = JSON::Any.new(definition.source_path)

        # Dependencies
        h["requires"] = JSON::Any.new(definition.requires.map { |r| JSON::Any.new(r) })

        # cgroup
        if definition.cgroup.any?
          cg = {} of String => JSON::Any
          if definition.cgroup.memory_max
            cg["memory_max"] = JSON::Any.new(definition.cgroup.memory_max.not_nil!)
          end
          if definition.cgroup.cpu_max
            cg["cpu_max"] = JSON::Any.new(definition.cgroup.cpu_max.not_nil!)
          end
          if definition.cgroup.pids_max
            cg["pids_max"] = JSON::Any.new(definition.cgroup.pids_max.not_nil!)
          end
          h["cgroup"] = JSON::Any.new(cg)
        end

        h
      end

      # -----------------------------------------------------------------------
      # Private helpers
      # -----------------------------------------------------------------------

      private def format_duration(span : Time::Span) : String
        total = span.total_seconds.to_i
        h = total // 3600
        m = (total % 3600) // 60
        s = total % 60
        if h > 0
          "#{h}h#{m}m#{s}s"
        elsif m > 0
          "#{m}m#{s}s"
        else
          "#{s}s"
        end
      end
    end
  end
end
