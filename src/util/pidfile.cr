# src/util/pidfile.cr
#
# Dedicated PID file manager.
#
# Provides a clean interface for the common PID-file lifecycle:
#   write  — atomically write the current PID to a file
#   read   — parse and return the PID stored in a file
#   alive? — check whether the stored PID names a live process
#   stale? — the file exists but the process is dead
#   clean  — remove a stale PID file safely
#   lock   — combine write + alive? to implement a simple exclusive lock

require "./fs"
require "../core/libc"

module Litin
  module Util
    class PidFile
      getter path : String

      def initialize(@path : String)
      end

      # Write `pid` (default: current process PID) to the file atomically.
      def write(pid : Int32 = Process.pid) : Nil
        FS.atomic_write(@path, "#{pid}\n", 0o644)
      end

      # Return the PID stored in the file, or nil.
      def read : Int32?
        return nil unless File.exists?(@path)
        File.read(@path).strip.to_i?
      rescue
        nil
      end

      # Return true if the file exists and the stored PID names a live process.
      def alive? : Bool
        pid = read
        return false unless pid && pid > 0
        LibC.kill(pid, 0) == 0
      rescue
        false
      end

      # Return true if the file exists but the process is dead.
      def stale? : Bool
        return false unless File.exists?(@path)
        !alive?
      end

      # Remove the PID file if it exists. Never raises.
      def clean : Nil
        File.delete(@path) if File.exists?(@path)
      rescue
      end

      def clean_stale : Nil
        clean if stale?
      end

      # Try to acquire an exclusive lock using the PID file.
      def try_lock : Bool
        return false if alive?
        write
        sleep 5.milliseconds
        read == Process.pid
      end

      def unlock : Nil
        clean if read == Process.pid
      end

      # ---------------------------------------------------------------------------
      # Class-level convenience helpers
      # ---------------------------------------------------------------------------

      def self.write(path : String, pid : Int32 = Process.pid) : Nil
        new(path).write(pid)
      end

      def self.read(path : String) : Int32?
        new(path).read
      end

      def self.alive?(path : String) : Bool
        new(path).alive?
      end

      def self.clean(path : String) : Nil
        new(path).clean
      end
    end
  end
end
