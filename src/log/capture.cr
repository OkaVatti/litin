# src/log/capture.cr
#
# Per-service log capture and retrieval.
#
# Each service's stdout/stderr is written to /var/log/litin/<name>.log.
# The log files are plain text, one timestamped line per entry.
#
# The LogManager provides:
#   - open_writer(name)  — returns an IO suitable for Process output/error
#   - tail(name, n)      — returns the last n lines of a service log
#   - follow(name, &)    — yields new lines as they are appended
#   - rotate(name)       — rotate the log file if it exceeds max_size
#
# Log rotation: when a log file exceeds LOG_MAX_BYTES, it is renamed to
# <name>.log.1 (previous .1 becomes .2, up to LOG_KEEP generations).
# This is intentionally simple — production deployments should use
# a dedicated log collector (syslog, vector, loki, etc.).

module Litin
  module Log
    LOG_DIR       = "/var/log/litin"
    LOG_MAX_BYTES = 10 * 1024 * 1024 # 10 MiB per service log
    LOG_KEEP      = 3                # rotated generations to keep

    class LogManager
      def initialize(@log_dir : String = LOG_DIR)
        Dir.mkdir_p(@log_dir) rescue nil
      end

      # ---------------------------------------------------------------------------
      # Write side
      # ---------------------------------------------------------------------------

      # Returns a writable IO for a service. Each write prepends a timestamp.
      # Used as the output: and error: arguments to Process.new.
      def open_writer(service_name : String) : IO
        path = log_path(service_name)
        rotate_if_needed(path)
        TimestampedWriter.new(path)
      rescue ex
        STDERR.puts "[log] cannot open #{service_name} log: #{ex.message}"
        IO::Memory.new
      end

      # ---------------------------------------------------------------------------
      # Read side
      # ---------------------------------------------------------------------------

      # Returns the last n lines of the service log (or all lines if n=0).
      def tail(service_name : String, lines : Int32 = 50) : Array(String)
        path = log_path(service_name)
        return [] of String unless File.exists?(path)

        all = File.read_lines(path)
        return all if lines == 0 || all.size <= lines
        all[-lines..]
      rescue ex
        STDERR.puts "[log] tail error for #{service_name}: #{ex.message}"
        [] of String
      end

      # Yields new lines appended to the log file, blocking until the channel
      # is closed. Intended to be called in its own fiber.
      def follow(service_name : String, channel : Channel(String)) : Nil
        path = log_path(service_name)

        # Wait for the file to appear (service may not have started yet).
        deadline = Time.utc + 10.seconds
        until File.exists?(path)
          return if Time.utc > deadline
          sleep 200.milliseconds
        end

        File.open(path) do |f|
          f.seek(0, IO::Seek::End) # start from current end
          loop do
            line = f.gets
            if line
              channel.send(line) rescue return
            else
              sleep 200.milliseconds
            end
          end
        end
      rescue ex
        STDERR.puts "[log] follow error for #{service_name}: #{ex.message}"
      end

      # ---------------------------------------------------------------------------
      # Rotation
      # ---------------------------------------------------------------------------

      def rotate_if_needed(path : String) : Nil
        return unless File.exists?(path)
        return if File.size(path) < LOG_MAX_BYTES
        rotate(path)
      end

      def rotate(path : String) : Nil
        # Shift existing generations down: .2 -> .3, .1 -> .2
        LOG_KEEP.downto(1) do |i|
          src = "#{path}.#{i}"
          dst = "#{path}.#{i + 1}"
          File.rename(src, dst) if File.exists?(src)
        end
        # Rename current log to .1
        File.rename(path, "#{path}.1") if File.exists?(path)
      rescue ex
        STDERR.puts "[log] rotation error for #{path}: #{ex.message}"
      end

      # ---------------------------------------------------------------------------
      # Private
      # ---------------------------------------------------------------------------

      private def log_path(name : String) : String
        File.join(@log_dir, "#{name}.log")
      end
    end

    # ---------------------------------------------------------------------------
    # Timestamped writer — wraps a file and prepends ISO8601 timestamps
    # ---------------------------------------------------------------------------

    class TimestampedWriter < IO
      def initialize(path : String)
        @file = File.open(path, "a")
      end

      def read(slice : Bytes) : Int32
        raise IO::Error.new("TimestampedWriter is write-only")
      end

      def write(slice : Bytes) : Nil
        return if slice.empty?

        # Split on newlines so each logical line gets its own timestamp.
        String.new(slice).each_line(chomp: false) do |line|
          next if line.chomp.empty? && line == "\n"
          ts = Time.utc.to_rfc3339(fraction_digits: 3)
          @file << ts << "  " << line
          @file << "\n" unless line.ends_with?("\n")
        end
        @file.flush
      end

      def close
        @file.close rescue nil
      end
    end

    # ---------------------------------------------------------------------------
    # Global log manager singleton (used by supervisors)
    # ---------------------------------------------------------------------------

    MANAGER = LogManager.new
  end
end
