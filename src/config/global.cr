# src/config/global.cr
#
# Global litind configuration reader.
#
# Reads /etc/litin/litin.conf (or a path given at build/runtime).
# The file format is the same key="value" shell syntax used by service
# definitions — no shell is invoked to read it.
#
# All settings have compile-time defaults so the file is entirely
# optional.  Missing keys fall back to their defaults silently.
#
# Usage:
#   cfg = Litin::Config::GlobalConfig.load
#   cfg.services_dir   # => "/etc/litin/services"
#   cfg.log_max_bytes  # => 10485760

module Litin
  module Config
    class GlobalConfig
      DEFAULT_PATH = "/etc/litin/litin.conf"

      SCALAR_RE = /^[ \t]*([A-Za-z_][A-Za-z0-9_]*)[ \t]*=[ \t]*(?:"([^"\\]*)"|'([^'\\]*)'|([^\s#]+))/

      # ── Directory paths ──────────────────────────────────────────────────────
      property services_dir : String = "/etc/litin/services"
      property targets_dir : String = "/etc/litin/targets"
      property sockets_dir : String = "/etc/litin/sockets"
      property timers_dir : String = "/etc/litin/timers"
      property masks_dir : String = "/etc/litin/masks"
      property env_dir : String = "/etc/litin/env"

      # ── Runtime paths ────────────────────────────────────────────────────────
      property socket_path : String = "/run/litin/litind.sock"
      property notify_dir : String = "/run/litin/notify"
      property run_dir : String = "/run/litin"

      # ── Logging ──────────────────────────────────────────────────────────────
      property log_dir : String = "/var/log/litin"
      property log_max_bytes : Int64 = 10 * 1024 * 1024_i64 # 10 MiB
      property log_keep : Int32 = 3

      # ── Boot ─────────────────────────────────────────────────────────────────
      property default_target : String = "default"

      # ── cgroup ───────────────────────────────────────────────────────────────
      property cgroup_enabled : Bool = true
      property cgroup_root : String = "/sys/fs/cgroup/litin"

      # ── Supervision ──────────────────────────────────────────────────────────
      # Maximum number of restart attempts before a service is marked
      # permanently failed (0 = unlimited).
      property max_restarts : Int32 = 0

      # ── Shutdown ─────────────────────────────────────────────────────────────
      # Seconds to wait for all services to stop before hard-killing.
      property shutdown_timeout : Int32 = 30

      # ────────────────────────────────────────────────────────────────────────

      def self.load(path : String = DEFAULT_PATH) : GlobalConfig
        cfg = GlobalConfig.new
        cfg.read_file(path)
        cfg
      end

      def read_file(path : String) : Nil
        return unless File.exists?(path)

        File.each_line(path) do |raw|
          line = raw.strip
          next if line.empty? || line.starts_with?('#')

          m = line.match(SCALAR_RE)
          next unless m

          key = m[1]
          value = (m[2]? || m[3]? || m[4]? || "").strip

          apply(key, value)
        end
      rescue ex
        STDERR.puts "[global config] cannot read #{path}: #{ex.message}"
      end

      # -----------------------------------------------------------------------
      # Structured accessors for downstream consumers
      # -----------------------------------------------------------------------

      def ipc_socket_path : String
        socket_path
      end

      def cgroup_available? : Bool
        cgroup_enabled && Dir.exists?(cgroup_root)
      end

      # -----------------------------------------------------------------------
      # Private
      # -----------------------------------------------------------------------

      private def apply(key : String, value : String)
        case key
        when "services_dir"     then @services_dir = value
        when "targets_dir"      then @targets_dir = value
        when "sockets_dir"      then @sockets_dir = value
        when "timers_dir"       then @timers_dir = value
        when "masks_dir"        then @masks_dir = value
        when "env_dir"          then @env_dir = value
        when "socket_path"      then @socket_path = value
        when "notify_dir"       then @notify_dir = value
        when "run_dir"          then @run_dir = value
        when "log_dir"          then @log_dir = value
        when "log_max_bytes"    then @log_max_bytes = value.to_i64? || @log_max_bytes
        when "log_keep"         then @log_keep = value.to_i? || @log_keep
        when "default_target"   then @default_target = value
        when "cgroup_enabled"   then @cgroup_enabled = (value == "true" || value == "1")
        when "cgroup_root"      then @cgroup_root = value
        when "max_restarts"     then @max_restarts = value.to_i? || 0
        when "shutdown_timeout" then @shutdown_timeout = value.to_i? || 30
        end
        # Unknown keys silently ignored.
      end
    end

    # Singleton accessor: loaded once at daemon startup.
    CONFIG = GlobalConfig.load
  end
end
