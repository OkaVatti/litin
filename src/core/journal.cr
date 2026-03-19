# src/core/journal.cr
#
# Structured event journal for Litin.
#
# The journal records discrete events (service state transitions,
# healthcheck results, socket activations, timer firings, errors)
# with timestamps and structured fields.  It serves two purposes:
#
#   1. In-memory ring buffer (last N events) for fast `litinctl status`
#      and `litinctl logs --journal` queries without reading log files.
#   2. Optional persistence to /var/log/litin/journal.ndjson (newline-
#      delimited JSON) for post-mortem analysis.
#
# The journal is append-only from the daemon's perspective. Readers
# (litinctl) query via IPC and receive the in-memory window.
#
# Event schema:
#   {
#     "t":       "2025-06-01T12:00:00.000Z",  // RFC3339 millisecond
#     "kind":    "state_change",               // event kind (see Kind enum)
#     "service": "nginx",                      // service name (or "" for system)
#     "from":    "starting",                   // previous state (state_change only)
#     "to":      "ready",                      // new state (state_change only)
#     "msg":     "pid=1234",                   // human-readable detail
#     "pid":     1234,                         // optional: relevant PID
#     "code":    0                             // optional: exit code
#   }

require "json"

module Litin
  module Core
    enum EventKind
      StateChange      # service state machine transition
      HookResult       # pre_start / post_stop etc. outcome
      HealthCheck      # healthcheck passed or failed
      SocketActivation # socket-activated service woken
      TimerFire        # timer unit triggered a service
      DaemonReload     # litind reloaded service definitions
      Error            # internal error
      Info             # general informational message
    end

    struct JournalEvent
      include JSON::Serializable

      getter t : String       # RFC3339 with milliseconds
      getter kind : String    # EventKind#to_s.downcase
      getter service : String # "" for system-wide events
      getter msg : String
      getter from : String? # state_change: previous state
      getter to : String?   # state_change: new state
      getter pid : Int32?
      getter code : Int32? # exit code for process events
      getter ok : Bool?    # for hook/healthcheck results

      def initialize(
        @kind : String,
        @service : String = "",
        @msg : String = "",
        @from : String? = nil,
        @to : String? = nil,
        @pid : Int32? = nil,
        @code : Int32? = nil,
        @ok : Bool? = nil,
      )
        @t = Time.utc.to_rfc3339(fraction_digits: 3)
      end
    end

    class Journal
      DEFAULT_CAPACITY = 4096
      JOURNAL_LOG_PATH = "/var/log/litin/journal.ndjson"

      def initialize(
        capacity : Int32 = DEFAULT_CAPACITY,
        @persist : Bool = false,
        @log_path : String = JOURNAL_LOG_PATH,
      )
        @ring = Deque(JournalEvent).new(capacity)
        @cap = capacity
        @mutex = Mutex.new
        @file = nil.as(File?)
        open_log if @persist
      end

      # -----------------------------------------------------------------------
      # Write side
      # -----------------------------------------------------------------------

      def record(event : JournalEvent) : Nil
        @mutex.synchronize do
          @ring.shift if @ring.size >= @cap
          @ring << event
        end
        persist(event) if @persist
      end

      # Convenience constructors.

      def state_change(service : String, from : String, to : String, msg : String = "", pid : Int32? = nil) : Nil
        record JournalEvent.new(
          kind: EventKind::StateChange.to_s.downcase,
          service: service,
          msg: msg,
          from: from,
          to: to,
          pid: pid
        )
      end

      def hook_result(service : String, hook : String, ok : Bool, msg : String = "") : Nil
        record JournalEvent.new(
          kind: EventKind::HookResult.to_s.downcase,
          service: service,
          msg: "#{hook}: #{msg}",
          ok: ok
        )
      end

      def healthcheck(service : String, ok : Bool, fails : Int32 = 0) : Nil
        record JournalEvent.new(
          kind: EventKind::HealthCheck.to_s.downcase,
          service: service,
          msg: ok ? "passed" : "failed (#{fails} consecutive)",
          ok: ok
        )
      end

      def socket_activation(service : String, listen : String) : Nil
        record JournalEvent.new(
          kind: EventKind::SocketActivation.to_s.downcase,
          service: service,
          msg: "activated via #{listen}"
        )
      end

      def timer_fire(service : String, timer : String) : Nil
        record JournalEvent.new(
          kind: EventKind::TimerFire.to_s.downcase,
          service: service,
          msg: "triggered by #{timer}"
        )
      end

      def daemon_reload(msg : String = "") : Nil
        record JournalEvent.new(kind: EventKind::DaemonReload.to_s.downcase, msg: msg)
      end

      def error(service : String, msg : String) : Nil
        record JournalEvent.new(kind: EventKind::Error.to_s.downcase, service: service, msg: msg)
      end

      def info(msg : String, service : String = "") : Nil
        record JournalEvent.new(kind: EventKind::Info.to_s.downcase, service: service, msg: msg)
      end

      # -----------------------------------------------------------------------
      # Read side
      # -----------------------------------------------------------------------

      # Return up to `limit` most recent events, optionally filtered.
      def query(
        limit : Int32 = 100,
        service : String? = nil,
        kind : String? = nil,
        since : Time? = nil,
      ) : Array(JournalEvent)
        @mutex.synchronize do
          events = @ring.to_a

          events = events.select { |e| e.service == service } if service
          events = events.select { |e| e.kind == kind } if kind
          events = events.select { |e| parse_time(e.t) >= since.not_nil! } if since

          events.last(limit)
        end
      end

      # Yield each event in the ring buffer as JSON, newest last.
      def each_json(& : String ->)
        @mutex.synchronize { @ring.each { |e| yield e.to_json } }
      end

      def size : Int32
        @mutex.synchronize { @ring.size }
      end

      def close : Nil
        @file.try(&.close)
      end

      # -----------------------------------------------------------------------
      # Private
      # -----------------------------------------------------------------------

      private def persist(event : JournalEvent) : Nil
        return unless f = @file
        f.puts(event.to_json)
        f.flush
      rescue ex
        STDERR.puts "[journal] persist failed: #{ex.message}"
        # Don't let log failures affect the daemon.
      end

      private def open_log : Nil
        Dir.mkdir_p(File.dirname(@log_path)) rescue nil
        @file = File.open(@log_path, "a")
      rescue ex
        STDERR.puts "[journal] cannot open #{@log_path}: #{ex.message}"
        @persist = false
      end

      private def parse_time(t : String) : Time
        Time.parse_rfc3339(t)
      rescue
        Time::UNIX_EPOCH
      end
    end

    # Daemon-wide singleton journal (initialised by litind).
    # Declared here so any module can `require "./core/journal"` and write.
    JOURNAL = Journal.new(capacity: 4096, persist: false)
  end
end
