# src/util/fs.cr
#
# Filesystem utilities for Litin.
#
# Provides atomic file writes, PID file read/write, directory
# creation with a given mode, and stale socket removal.

require "../core/libc"

module Litin
  module Util
    module FS
      # Write `content` to `path` atomically via a temp file + rename.
      # Creates parent directories as needed.
      def self.atomic_write(path : String, content : String, mode : Int32 = 0o644) : Nil
        dir = File.dirname(path)
        Dir.mkdir_p(dir) unless Dir.exists?(dir)

        tmp = "#{path}.tmp.#{Process.pid}"
        File.write(tmp, content)
        File.chmod(tmp, mode)
        File.rename(tmp, path)
      rescue ex
        File.delete(tmp) rescue nil if tmp
        raise ex
      end

      # Write the current PID (or `pid`) to `path`.
      def self.write_pid(path : String, pid : Int64 = Process.pid) : Nil
        atomic_write(path, "#{pid}\n", 0o644)
      end

      # Read the PID stored in `path`. Returns nil if the file does not
      # exist or does not contain a valid integer.
      def self.read_pid(path : String) : Int64?
        return nil unless File.exists?(path)
        File.read(path).strip.to_i64?
      rescue
        nil
      end

      # Create `path` as a directory with the given octal `mode`.
      # Does not raise if the directory already exists.
      def self.ensure_dir(path : String, mode : Int32 = 0o755) : Nil
        Dir.mkdir_p(path)
        File.chmod(path, mode)
      rescue ex : File::AlreadyExistsError
        # Already exists — that is acceptable.
      end

      # Remove a stale UNIX socket file at `path` if it exists.
      # Never raises.
      def self.remove_stale_socket(path : String) : Nil
        File.delete(path) if File.exists?(path)
      rescue
      end
    end
  end
end
