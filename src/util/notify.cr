# src/util/notify.cr
#
# sd_notify client library.
#
# Provides a Crystal API for sending readiness and status notifications
# to litind (or any systemd-compatible supervisor) via the
# NOTIFY_SOCKET environment variable.
#
# This is the "sending" side of the notify protocol.  The "receiving"
# side lives in the Supervisor (wait_notify).
#
# Protocol:
#   The service finds its NOTIFY_SOCKET env var, connects to the UNIX
#   datagram socket at that path, and sends one or more KEY=value pairs
#   separated by newlines, followed by a final newline.
#
# Commonly used messages:
#   READY=1                  service is fully initialised
#   STOPPING=1               service is beginning graceful shutdown
#   RELOADING=1              service is reloading configuration
#   STATUS=<text>            human-readable status string
#   ERRNO=<n>                service encountered error n and is about to exit
#   WATCHDOG=1               watchdog keepalive ping
#   WATCHDOG_USEC=<n>        update watchdog interval (microseconds)
#   MAINPID=<pid>            tell supervisor about the real main PID (forking)
#
# Usage from a Crystal service:
#
#   require "litin/util/notify"
#   Litin::Util::Notify.ready
#   Litin::Util::Notify.status("Listening on :8080")
#
# The module is a no-op when NOTIFY_SOCKET is not set, so it is safe
# to include unconditionally in services that may run under supervisors
# that do not support the protocol.

module Litin
  module Util
    module Notify
      # Send READY=1 to the supervisor.
      def self.ready : Bool
        send("READY=1")
      end

      # Send STOPPING=1 before beginning graceful shutdown.
      def self.stopping : Bool
        send("STOPPING=1")
      end

      # Send RELOADING=1 before reloading configuration.
      def self.reloading : Bool
        send("RELOADING=1")
      end

      # Send a human-readable status string.
      def self.status(text : String) : Bool
        send("STATUS=#{text}")
      end

      # Send a watchdog keepalive.  Call this periodically from a long-
      # running service to prevent the supervisor from considering it stuck.
      def self.watchdog : Bool
        send("WATCHDOG=1")
      end

      # Update the watchdog interval.  `usec` is microseconds.
      def self.watchdog_usec(usec : Int64) : Bool
        send("WATCHDOG_USEC=#{usec}")
      end

      # Notify the supervisor of the real main PID (for forking-type services).
      def self.main_pid(pid : Int32 = Process.pid) : Bool
        send("MAINPID=#{pid}")
      end

      # Send an errno value before exiting with an error.
      def self.errno(n : Int32) : Bool
        send("ERRNO=#{n}")
      end

      # Send multiple messages in a single datagram.
      def self.send_multi(messages : Array(String)) : Bool
        return false if messages.empty?
        send(messages.join("\n"))
      end

      # ---------------------------------------------------------------------------
      # Low-level send
      # ---------------------------------------------------------------------------

      # Send `payload` to the NOTIFY_SOCKET.
      # Returns true on success, false if NOTIFY_SOCKET is unset or
      # if the send fails.  Never raises.
      def self.send(payload : String) : Bool
        socket_path = ENV["NOTIFY_SOCKET"]?
        return false unless socket_path && !socket_path.empty?

        # Remove the optional "@" prefix (abstract namespace — Linux-specific).
        # Litin uses filesystem sockets, so we strip it and use the path.
        socket_path = socket_path.lchop('@') if socket_path.starts_with?('@')

        UNIXSocket.open(socket_path) do |sock|
          # sd_notify uses SOCK_DGRAM but UNIXSocket is SOCK_STREAM in Crystal.
          # For compatibility with both litind (STREAM) and systemd (DGRAM),
          # we write and flush.  litind's wait_notify reads lines, which works
          # with both transport types.
          sock.print(payload)
          sock.print("\n") unless payload.ends_with?("\n")
          sock.flush
        end
        true
      rescue
        false
      end

      # ---------------------------------------------------------------------------
      # Watchdog helper: start a background keepalive fiber
      # ---------------------------------------------------------------------------

      # Start a fiber that sends WATCHDOG=1 every `interval`.
      # Returns the fiber.  Stop it by calling `fiber.close` (not available
      # directly in Crystal) or by ensuring NOTIFY_SOCKET is unset.
      def self.start_watchdog(interval : Time::Span = 15.seconds) : Fiber
        spawn do
          loop do
            sleep interval
            break unless watchdog
          end
        end
      end

      # ---------------------------------------------------------------------------
      # WATCHDOG_USEC reader (for services that want to honor the supervisor's
      # configured interval rather than hard-coding their own).
      # ---------------------------------------------------------------------------

      # Return the watchdog interval in seconds, as configured by the supervisor,
      # or nil if not set.
      def self.watchdog_interval : Float64?
        usec = ENV["WATCHDOG_USEC"]?
        return nil unless usec
        usec_val = usec.to_i64?
        return nil unless usec_val && usec_val > 0
        usec_val / 1_000_000.0
      end
    end
  end
end
