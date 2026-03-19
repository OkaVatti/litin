# src/util/fs.cr
#
# Filesystem utilities for Litin.
#
# Covers:
#   - Atomic file writes (write to .tmp, rename over target)
#   - PID file reading with validation
#   - Safe directory creation
#   - Runtime directory tree setup
#   - Stale socket cleanup

module Litin
  module Util
    module FS
      # -----------------------------------------------------------------------
      # Atomic file write
      # -----------------------------------------------------------------------

      # Write `content` to `path` atomically: write to a sibling .tmp file
      # then rename(2) it over `path`.  Rename is atomic on POSIX within
      # a single filesystem.
      def self.atomic_write(path : String, content : String, mode : Int32 = 0o644) : Nil
        dir = File.dirname(path)
        tmp = "#{path}.tmp.#{Process.pid}"

        Dir.mkdir_p(dir)
        File.write(tmp, content)
        File.chmod(tmp, mode)
        File.rename(tmp, path)
      rescue ex
        File.delete(tmp) rescue nil
        raise ex
      end

      # -----------------------------------------------------------------------
      # PID file helpers
      # -----------------------------------------------------------------------

      # Write the current process PID to `path`.
      def self.write_pid(path : String) : Nil
        atomic_write(path, "#{Process.pid}\n", 0o644)
      end

      # Read and return a PID from `path`, or nil if the file is missing,
      # unreadable, or contains a non-numeric value.
      def self.read_pid(path : String) : Int32?
        return nil unless File.exists?(path)
        content = File.read(path).strip
        content.to_i?
      rescue
        nil
      end

      # Read a PID from `path` and verify the process is still alive.
      # Returns the PID if alive, nil otherwise.
      def self.read_live_pid(path : String) : Int32?
        pid = read_pid(path)
        return nil unless pid
        # kill(pid, 0) returns 0 if the process exists, ESRCH otherwise.
        ret = LibC.kill(pid, 0)
        ret == 0 ? pid : nil
      rescue
        nil
      end

      # -----------------------------------------------------------------------
      # Directory setup
      # -----------------------------------------------------------------------

      # Create a directory and set mode, silently ignoring already-exists.
      def self.ensure_dir(path : String, mode : Int32 = 0o755) : Nil
        Dir.mkdir_p(path)
        File.chmod(path, mode)
      rescue ex : File::AlreadyExistsError
        # Fine.
      rescue ex
        STDERR.puts "[fs] ensure_dir #{path}: #{ex.message}"
      end

      # Create all runtime directories expected by litind.
      def self.setup_runtime_dirs : Nil
        {
          "/run/litin"        => 0o755,
          "/run/litin/notify" => 0o755,
          "/var/log/litin"    => 0o755,
        }.each do |path, mode|
          ensure_dir(path, mode)
        end
      end

      # -----------------------------------------------------------------------
      # Stale socket cleanup
      # -----------------------------------------------------------------------

      # Remove a UNIX socket file if it exists (from a previous crashed run).
      def self.remove_stale_socket(path : String) : Nil
        return unless File.exists?(path)
        File.delete(path)
        STDOUT.puts "[fs] removed stale socket: #{path}"
      rescue ex
        STDERR.puts "[fs] cannot remove stale socket #{path}: #{ex.message}"
      end

      # -----------------------------------------------------------------------
      # File watching (simple poll-based)
      # -----------------------------------------------------------------------

      # Call `block` whenever any file in `paths` has changed mtime.
      # Runs in a fiber; returns the fiber handle.
      def self.watch_files(paths : Array(String), interval : Time::Span = 5.seconds, &block : Array(String) ->) : Fiber
        mtimes = {} of String => Time
        paths.each do |p|
          mtimes[p] = File.info(p).modification_time rescue Time::UNIX_EPOCH
        end

        spawn do
          loop do
            sleep interval
            changed = paths.select do |p|
              current = File.info(p).modification_time rescue Time::UNIX_EPOCH
              old = mtimes[p]
              if current != old
                mtimes[p] = current
                true
              else
                false
              end
            end
            block.call(changed) unless changed.empty?
          end
        end
      end
    end
  end
end

lib LibC
  fun kill(pid : PidT, sig : Int32) : Int32
end
