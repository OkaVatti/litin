# src/timer/scheduler.cr
#
# Timer unit loading and scheduling.
#
# Timer files are placed in /etc/litin/timers/ and look like:
#
#   [Timer]
#   Service=my_service
#   OnBootSec=10s
#   OnUnitActiveSec=1h
#
# - OnBootSec: one‑shot delay after daemon start.
# - OnUnitActiveSec: periodic interval; after the first activation (or after
#   OnBootSec), the timer fires repeatedly with this interval.
#   The service is started each time the timer elapses.

require "time"
require "file_utils"

module Timer
  # ---------------------------------------------------------------------------
  # Unit definition
  # ---------------------------------------------------------------------------
  struct TimerUnit
    getter name : String
    getter service_name : String
    getter on_boot_sec : Time::Span?
    getter on_unit_active_sec : Time::Span?

    def initialize(@name : String, @service_name : String,
                   @on_boot_sec : Time::Span? = nil,
                   @on_unit_active_sec : Time::Span? = nil)
    end
  end

  # ---------------------------------------------------------------------------
  # Parser
  # ---------------------------------------------------------------------------
  module TimerParser
    TIMERS_DIR = "/etc/litin/timers"

    # Parse a single .timer file. Returns nil if the file is invalid.
    def self.parse(file_path : String) : TimerUnit?
      name = File.basename(file_path, ".timer")
      service_name = name # default if not specified
      on_boot_sec = nil
      on_unit_active_sec = nil
      in_timer_section = false

      File.each_line(file_path) do |raw_line|
        line = raw_line.strip
        next if line.empty? || line.starts_with?('#')

        if line.starts_with?('[') && line.ends_with?(']')
          if line == "[Timer]"
            in_timer_section = true
          else
            in_timer_section = false
          end
          next
        end

        next unless in_timer_section

        # key = value (simple; no quoting)
        parts = line.split('=', 2)
        next unless parts.size == 2
        key = parts[0].strip
        value = parts[1].strip

        case key
        when "Service"
          service_name = value
        when "OnBootSec"
          on_boot_sec = Util.parse_duration(value)
        when "OnUnitActiveSec"
          on_unit_active_sec = Util.parse_duration(value)
        end
      end

      # At least one timer schedule must be defined.
      return nil if on_boot_sec.nil? && on_unit_active_sec.nil?

      TimerUnit.new(
        name: name,
        service_name: service_name,
        on_boot_sec: on_boot_sec,
        on_unit_active_sec: on_unit_active_sec
      )
    rescue ex
      STDERR.puts "[litind] timer parse error in #{file_path}: #{ex.message}"
      nil
    end

    # Load all .timer files from a directory.
    def self.load_all(dir : String) : Array(TimerUnit)
      units = [] of TimerUnit
      return units unless Dir.exists?(dir)
      Dir.glob(File.join(dir, "*.timer")).each do |path|
        unit = parse(path)
        units << unit if unit
      end
      units
    end
  end

  # ---------------------------------------------------------------------------
  # Scheduler
  # ---------------------------------------------------------------------------
  class Scheduler
    @units : Array(TimerUnit)
    @fibers : Array(Fiber)
    @running : Bool

    def initialize(@callback : Proc(String, Nil))
      @units = [] of TimerUnit
      @fibers = [] of Fiber
      @running = false
    end

    # Load all timer units from the given directory.
    def load_all(dir : String) : Nil
      @units = TimerParser.load_all(dir)
    end

    # Start scheduling fibers for all loaded units.
    def start : Nil
      @running = true
      @fibers = @units.map { |unit| spawn_timer(unit) }
    end

    # Stop all fibers gracefully (used on shutdown).
    def stop : Nil
      @running = false
      @fibers.each do |fib|
        fib.kill rescue nil
      end
      @fibers.clear
    end

    # Internal: create a fiber for one timer unit.
    private def spawn_timer(unit : TimerUnit) : Fiber
      spawn do
        # -- One‑shot boot delay --
        if boot_delay = unit.on_boot_sec
          sleep boot_delay
          @callback.call(unit.service_name) if @running
        end

        # -- Periodic loop --
        if interval = unit.on_unit_active_sec
          while @running
            sleep interval
            @callback.call(unit.service_name) if @running
          end
        end
      end
    end
  end

  # ---------------------------------------------------------------------------
  # Duration parsing helper (shared by timer parser, and can be used elsewhere)
  # ---------------------------------------------------------------------------
  module Util
    # Parse a string like "10s", "5m", "2h", "1d" into Time::Span.
    # Returns nil if the string cannot be parsed.
    def self.parse_duration(raw : String) : Time::Span?
      raw = raw.strip
      if m = raw.match(/^(\d+)(s|m|h|d)$/)
        n = m[1].to_i64
        case m[2]
        when "s" then n.seconds
        when "m" then n.minutes
        when "h" then n.hours
        when "d" then n.days
        else          nil
        end
      else
        nil
      end
    end
  end
end
