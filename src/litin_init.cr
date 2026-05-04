# src/litin_init.cr
#
# litin-init — PID 1 bootstrap.
#
# Responsibilities (in order):
#   1. Set up the system console (/dev/console -> stdin/stdout/stderr).
#   2. Parse the kernel command line for overrides.
#   3. Mount essential pseudo-filesystems.
#   4. Set hostname from /etc/hostname.
#   5. Establish a minimal PATH environment.
#   6. Read /etc/litin/init.conf for litind path and rescue shell.
#   7. Install signal handlers.
#   8. Launch litind; restart on crash up to MAX_RESTARTS times.
#   9. Infinite zombie-reaping loop with shutdown handling.

require "./core/signals"
require "./core/libc"

module LitinInit
  # ---------------------------------------------------------------------------
  # Constants
  # ---------------------------------------------------------------------------

  CONF_FILE            = "/etc/litin/init.conf"
  DEFAULT_LITIND_PATH  = "/usr/local/sbin/litind"
  DEFAULT_RESCUE_SHELL = "/bin/sh"
  MAX_RESTARTS         = 5
  RESTART_DELAY        = 2.seconds
  LITIND_STOP_TIMEOUT  = 30.seconds

  @@litind_path  = DEFAULT_LITIND_PATH
  @@rescue_shell = DEFAULT_RESCUE_SHELL
  @@single_user  = false

  # ---------------------------------------------------------------------------
  # Main
  # ---------------------------------------------------------------------------

  def self.main
    setup_console
    parse_kernel_cmdline
    read_init_conf
    mount_essential_filesystems
    set_hostname
    setup_environment
    create_runtime_dirs

    unless Process.pid == 1
      STDERR.puts "[litin-init] WARNING: not PID 1 (pid=#{Process.pid}) — running in test mode"
    end

    if @@single_user
      STDOUT.puts "[litin-init] single-user mode requested"
      run_rescue_shell_loop
      return
    end

    shutdown_ch = Channel(Litin::Signals::ShutdownReason).new(1)
    Litin::Signals.setup_pid1(shutdown_ch)

    litind_pid = start_litind
    restarts = 0

    loop do
      reap_zombies

      if litind_pid > 0
        raw = uninitialized Int32
        result = LibC.waitpid(litind_pid, pointerof(raw), LibC::WNOHANG)
        if result == litind_pid
          # Decode exit code from raw wstatus.
          exited = (raw & 0x7f) == 0
          code = exited ? ((raw >> 8) & 0xff) : -1
          STDERR.puts "[litin-init] litind exited (code=#{code})"

          restarts += 1
          if restarts >= MAX_RESTARTS
            STDERR.puts "[litin-init] litind crashed #{restarts} times — rescue shell"
            run_rescue_shell_once
            restarts = 0
          else
            sleep RESTART_DELAY
          end

          STDOUT.puts "[litin-init] restarting litind (attempt #{restarts + 1})"
          litind_pid = start_litind
          next
        end
      end

      select
      when reason = shutdown_ch.receive
        STDOUT.puts "[litin-init] shutdown: #{reason}"
        perform_shutdown(litind_pid, reason)
        LibC.reboot(LibC::LINUX_REBOOT_CMD_HALT)
        break
      when timeout(200.milliseconds)
      end
    end
  end

  # ---------------------------------------------------------------------------
  # Console setup
  # ---------------------------------------------------------------------------

  def self.setup_console
    [0, 1, 2].each do |fd|
      LibC.close(fd)
      ret = LibC.open("/dev/console", LibC::O_RDWR, 0_u32)
      LibC.dup2(ret, fd) if ret != fd && ret >= 0
    end
  rescue
  end

  # ---------------------------------------------------------------------------
  # Kernel command line
  # ---------------------------------------------------------------------------

  CMDLINE_PATH = "/proc/cmdline"

  def self.parse_kernel_cmdline
    return unless File.exists?(CMDLINE_PATH)
    line = File.read(CMDLINE_PATH).strip
    line.split(' ').each do |tok|
      case tok
      when /^litin\.litind=(.+)$/
        @@litind_path = $1
      when /^litin\.init_shell=(.+)$/
        @@rescue_shell = $1
      when "litin.single", "single", "s", "1"
        @@single_user = true
      end
    end
  rescue
  end

  # ---------------------------------------------------------------------------
  # init.conf
  # ---------------------------------------------------------------------------

  SCALAR_RE = /^[ \t]*([A-Za-z_][A-Za-z0-9_]*)[ \t]*=[ \t]*(?:"([^"\\]*)"|'([^'\\]*)'|([^\s#]+))/

  def self.read_init_conf
    return unless File.exists?(CONF_FILE)
    File.each_line(CONF_FILE) do |raw|
      line = raw.strip
      next if line.empty? || line.starts_with?('#')
      next unless m = line.match(SCALAR_RE)
      key = m[1]
      value = (m[2]? || m[3]? || m[4]? || "").strip
      case key
      when "litind_path"  then @@litind_path = value
      when "rescue_shell" then @@rescue_shell = value
      end
    end
  rescue ex
    STDERR.puts "[litin-init] cannot read #{CONF_FILE}: #{ex.message}"
  end

  # ---------------------------------------------------------------------------
  # Filesystem mounting
  # ---------------------------------------------------------------------------

  MOUNTS = [
    {fstype: "proc", source: "proc", target: "/proc", flags: 0_u64},
    {fstype: "sysfs", source: "sysfs", target: "/sys", flags: 0_u64},
    {fstype: "devtmpfs", source: "devtmpfs", target: "/dev", flags: 0_u64},
    {fstype: "devpts", source: "devpts", target: "/dev/pts", flags: 0_u64},
    {fstype: "tmpfs", source: "tmpfs", target: "/dev/shm", flags: 0_u64},
    {fstype: "tmpfs", source: "tmpfs", target: "/run", flags: 0_u64},
    {fstype: "cgroup2", source: "cgroup2", target: "/sys/fs/cgroup", flags: 0_u64},
  ]

  def self.mount_essential_filesystems
    MOUNTS.each do |m|
      next if already_mounted?(m[:target])
      Dir.mkdir_p(m[:target]) rescue nil
      ret = LibC.mount(m[:source], m[:target], m[:fstype], m[:flags], nil)
      if ret != 0
        STDERR.puts "[litin-init] mount #{m[:target]}: failed (ignored)"
      end
    end
  end

  def self.already_mounted?(path : String) : Bool
    return false unless File.exists?("/proc/mounts")
    File.each_line("/proc/mounts") do |line|
      return true if line.split[1]? == path
    end
    false
  rescue
    false
  end

  # ---------------------------------------------------------------------------
  # Hostname
  # ---------------------------------------------------------------------------

  def self.set_hostname
    return unless File.exists?("/etc/hostname")
    hostname = File.read("/etc/hostname").strip
    return if hostname.empty?
    ret = LibC.sethostname(hostname, hostname.bytesize.to_u64)
    STDERR.puts "[litin-init] sethostname failed" if ret != 0
  end

  # ---------------------------------------------------------------------------
  # Environment
  # ---------------------------------------------------------------------------

  def self.setup_environment
    ENV["PATH"] ||= "/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin"
    ENV["TERM"] ||= "linux"
    ENV["SHELL"] ||= @@rescue_shell
  end

  def self.create_runtime_dirs
    ["/run/litin", "/run/litin/notify", "/var/log/litin"].each do |d|
      Dir.mkdir_p(d) rescue nil
    end
  end

  # ---------------------------------------------------------------------------
  # litind lifecycle
  # ---------------------------------------------------------------------------

  def self.start_litind : Int32
    unless File.exists?(@@litind_path)
      STDERR.puts "[litin-init] FATAL: litind not found at #{@@litind_path}"
      return -1
    end
    process = Process.new(
      command: @@litind_path,
      input: Process::Redirect::Close,
      output: Process::Redirect::Inherit,
      error: Process::Redirect::Inherit
    )
    STDOUT.puts "[litin-init] litind started (pid=#{process.pid})"
    process.pid.to_i32
  rescue ex
    STDERR.puts "[litin-init] failed to start litind: #{ex.message}"
    -1
  end

  # ---------------------------------------------------------------------------
  # Rescue shell
  # ---------------------------------------------------------------------------

  def self.run_rescue_shell_once : Nil
    STDOUT.puts "[litin-init] spawning rescue shell (#{@@rescue_shell})"
    proc = Process.new(
      command: @@rescue_shell,
      input: Process::Redirect::Inherit,
      output: Process::Redirect::Inherit,
      error: Process::Redirect::Inherit
    )
    proc.wait
    STDOUT.puts "[litin-init] rescue shell exited"
  rescue ex
    STDERR.puts "[litin-init] cannot spawn rescue shell: #{ex.message}"
    sleep 5.seconds
  end

  def self.run_rescue_shell_loop : Nil
    loop do
      run_rescue_shell_once
      STDOUT.puts "[litin-init] rescue shell exited — press Enter to retry"
      sleep 2.seconds
    end
  end

  # ---------------------------------------------------------------------------
  # Zombie reaping
  # ---------------------------------------------------------------------------

  def self.reap_zombies : Nil
    loop do
      raw = uninitialized Int32
      pid = LibC.waitpid(-1, pointerof(raw), LibC::WNOHANG)
      break if pid <= 0
    end
  end

  # ---------------------------------------------------------------------------
  # Shutdown
  # ---------------------------------------------------------------------------

  def self.perform_shutdown(litind_pid : Int32, reason : Litin::Signals::ShutdownReason) : Nil
    STDOUT.puts "[litin-init] shutdown sequence (#{reason})"

    if litind_pid > 0
      Process.signal(Signal::TERM, litind_pid) rescue nil

      deadline = Time.utc + LITIND_STOP_TIMEOUT
      loop do
        reap_zombies
        raw = uninitialized Int32
        result = LibC.waitpid(litind_pid, pointerof(raw), LibC::WNOHANG)
        break if result == litind_pid
        break if Time.utc > deadline
        sleep 200.milliseconds
      end
    end

    10.times { reap_zombies; sleep 100.milliseconds }

    case reason
    when Litin::Signals::ShutdownReason::Reboot
      STDOUT.puts "[litin-init] rebooting"
      LibC.reboot(LibC::LINUX_REBOOT_CMD_RESTART)
    when Litin::Signals::ShutdownReason::PowerOff
      STDOUT.puts "[litin-init] powering off"
      LibC.reboot(LibC::LINUX_REBOOT_CMD_POWER_OFF)
    else
      STDOUT.puts "[litin-init] halting"
      LibC.reboot(LibC::LINUX_REBOOT_CMD_HALT)
    end
  end
end

LitinInit.main