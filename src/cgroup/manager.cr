# src/cgroup/manager.cr
#
# cgroup v2 manager.
#
# Handles per-service cgroup creation, resource limit application,
# process assignment, and cleanup. All operations target the unified
# cgroup v2 hierarchy mounted at /sys/fs/cgroup.
#
# Cgroup layout:
#   /sys/fs/cgroup/litin/              (Litin root)
#   /sys/fs/cgroup/litin/<service>/    (per-service)
#
# All controller delegation (cpu, memory, io, pids) is enabled at the
# root level so that child cgroups can use them.

require "../config/service_definition"

module Litin
  module CGroup
    CGROUP_ROOT  = "/sys/fs/cgroup"
    LITIN_ROOT   = "#{CGROUP_ROOT}/litin"
    SUBTREE_CTRL = "#{LITIN_ROOT}/cgroup.subtree_control"

    class Error < Exception; end

    # ---------------------------------------------------------------------------
    # Setup — called once by litind at startup.
    # ---------------------------------------------------------------------------

    def self.setup : Nil
      return unless File.directory?(CGROUP_ROOT)

      Dir.mkdir_p(LITIN_ROOT) rescue nil

      # Enable the controllers we want to delegate to child cgroups.
      controllers = %w[cpu memory io pids]
      enable_str = controllers.map { |c| "+#{c}" }.join(" ")

      CGroup.write_cgroup_file(SUBTREE_CTRL, enable_str)
    rescue ex
      STDERR.puts "[cgroup] setup warning: #{ex.message} (cgroup support may be limited)"
    end

    # ---------------------------------------------------------------------------
    # Per-service cgroup management
    # ---------------------------------------------------------------------------

    class ServiceCGroup
      getter path : String

      def initialize(@service_name : String)
        @path = File.join(LITIN_ROOT, @service_name)
      end

      # Create the cgroup directory.
      def create : Nil
        Dir.mkdir_p(@path)
      rescue ex
        raise Error.new("cannot create cgroup #{@path}: #{ex.message}")
      end

      # Apply resource limits from a CgroupLimits struct.
      def apply_limits(limits : Config::CgroupLimits) : Nil
        return unless limits.any?
        return unless File.directory?(@path)

        write_if_set("cpu.max", limits.cpu_max)
        write_if_set("memory.max", limits.memory_max)
        write_if_set("memory.low", limits.memory_low)
        write_if_set("pids.max", limits.pids_max)
        write_if_set("io.max", limits.io_max)
        write_if_set("cpuset.cpus", limits.cpuset_cpus)

        if limits.oom_group
          CGroup.write_cgroup_file(File.join(@path, "memory.oom.group"), "1")
        end
      rescue ex
        STDERR.puts "[cgroup:#{@service_name}] apply_limits warning: #{ex.message}"
      end

      # Move a process into this cgroup.
      def assign_pid(pid : Int32) : Nil
        CGroup.write_cgroup_file(File.join(@path, "cgroup.procs"), pid.to_s)
      rescue ex
        STDERR.puts "[cgroup:#{@service_name}] assign_pid #{pid} failed: #{ex.message}"
      end

      # Kill all processes in the cgroup by writing to cgroup.kill (kernel >= 5.14).
      # Falls back to reading cgroup.procs and SIGKILLing each PID.
      def kill_all : Nil
        return unless File.directory?(@path)

        kill_file = File.join(@path, "cgroup.kill")
        if File.exists?(kill_file)
          CGroup.write_cgroup_file(kill_file, "1")
        else
          kill_all_fallback
        end
      rescue ex
        STDERR.puts "[cgroup:#{@service_name}] kill_all failed: #{ex.message}"
      end

      # Remove the cgroup directory. Must have no processes first.
      def destroy : Nil
        return unless File.directory?(@path)
        # Try to kill remaining processes first.
        kill_all
        sleep 100.milliseconds
        Dir.delete(@path)
      rescue ex
        STDERR.puts "[cgroup:#{@service_name}] destroy failed: #{ex.message}"
      end

      # Read current resource usage stats.
      def stats : Hash(String, String)
        result = {} of String => String
        return result unless File.directory?(@path)

        %w[cpu.stat memory.current memory.peak pids.current io.stat].each do |f|
          full = File.join(@path, f)
          next unless File.exists?(full)
          result[f] = File.read(full).strip
        rescue
        end

        result
      end

      # ---------------------------------------------------------------------------
      # Private helpers
      # ---------------------------------------------------------------------------

      private def write_if_set(filename : String, value : String?) : Nil
        return unless value
        CGroup.write_cgroup_file(File.join(@path, filename), value)
      end

      private def kill_all_fallback : Nil
        procs_file = File.join(@path, "cgroup.procs")
        return unless File.exists?(procs_file)

        File.each_line(procs_file) do |line|
          pid = line.strip.to_i?
          next unless pid
          Process.signal(Signal::KILL, pid) rescue nil
        end
      end
    end

    # ---------------------------------------------------------------------------
    # Module-level helpers
    # ---------------------------------------------------------------------------

    def self.write_cgroup_file(path : String, value : String) : Nil
      File.write(path, value)
    rescue ex
      # Non-fatal: some files may not exist on older kernels.
      STDERR.puts "[cgroup] write #{path} = #{value}: #{ex.message}"
    end

    # Returns true if cgroup v2 is available and the Litin root exists.
    def self.available? : Bool
      File.directory?(LITIN_ROOT) &&
        File.exists?(File.join(LITIN_ROOT, "cgroup.controllers"))
    rescue
      false
    end
  end
end
