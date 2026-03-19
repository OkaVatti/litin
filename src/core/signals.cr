# src/core/signals.cr
#
# Signal handling primitives for Litin.
#
# PID 1 has special signal semantics: unhandled signals that would
# normally terminate any other process are silently ignored when
# received by PID 1. We must explicitly register handlers for every
# signal we care about.
#
# Crystal's Signal module wraps sigaction(2) behind a fiber-based
# dispatch loop. That is fine for litind and litinctl. For litin-init
# (PID 1) we use the same mechanism but with extra care around
# SIGCHLD, which must never be ignored.

module Litin
  module Signals
    # Install all signal handlers appropriate for PID 1.
    # Must be called exactly once, before entering the main event loop.
    def self.setup_pid1(shutdown_channel : Channel(ShutdownReason))
      # SIGCHLD — a child exited or stopped. We do NOT reap here;
      # reaping is done in the dedicated waitpid loop. This handler
      # merely wakes the event loop if it is sleeping.
      Signal::CHLD.trap { }

      # SIGTERM — conventional graceful shutdown request.
      Signal::TERM.trap do
        shutdown_channel.send(ShutdownReason::Halt) rescue nil
      end

      # SIGINT — Ctrl+Alt+Del on Linux (kernel sends SIGINT to PID 1).
      Signal::INT.trap do
        shutdown_channel.send(ShutdownReason::Reboot) rescue nil
      end

      # SIGUSR1 — reboot (some distributions use this convention).
      Signal::USR1.trap do
        shutdown_channel.send(ShutdownReason::Reboot) rescue nil
      end

      # SIGUSR2 — poweroff.
      Signal::USR2.trap do
        shutdown_channel.send(ShutdownReason::PowerOff) rescue nil
      end

      # SIGHUP — reload configuration (forwarded to litind).
      # PID 1 itself does not reload; it passes the signal along.
      Signal::HUP.trap { }

      # Explicitly ignore SIGPIPE so broken IPC pipes do not kill us.
      Signal::PIPE.ignore
    end

    # Install signal handlers for litind (the supervisor daemon).
    def self.setup_litind(
      reload_channel : Channel(Nil),
      shutdown_channel : Channel(ShutdownReason),
    )
      Signal::CHLD.trap { }
      Signal::PIPE.ignore

      Signal::HUP.trap do
        reload_channel.send(nil) rescue nil
      end

      Signal::TERM.trap do
        shutdown_channel.send(ShutdownReason::Halt) rescue nil
      end

      Signal::INT.trap do
        shutdown_channel.send(ShutdownReason::Halt) rescue nil
      end
    end

    # Reason codes for the shutdown channel.
    enum ShutdownReason
      Halt
      Reboot
      PowerOff
    end
  end
end
