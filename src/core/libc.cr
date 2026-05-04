# src/core/libc.cr
#
# Linux-specific and missing LibC bindings for Litin.
# Common POSIX functions (open, close, dup2, waitpid, kill, …) and
# struct Passwd are already provided by Crystal’s standard LibC.

lib LibC
  # ---------------------------------------------------------------------------
  # reboot(2) – Linux-specific constants and function
  # ---------------------------------------------------------------------------
  LINUX_REBOOT_MAGIC1 = 0xfee1dead_u32
  LINUX_REBOOT_MAGIC2 =  672274793_u32

  LINUX_REBOOT_CMD_RESTART    = 0x01234567
  LINUX_REBOOT_CMD_HALT       = 0xcdef0123
  LINUX_REBOOT_CMD_POWER_OFF  = 0x4321fedc
  LINUX_REBOOT_CMD_SW_SUSPEND = 0xd000fce2

  PR_SET_CHILD_SUBREAPER = 36

  fun prctl(option : Int32, arg2 : UInt64, arg3 : UInt64, arg4 : UInt64, arg5 : UInt64) : Int32

  fun reboot(cmd : Int32) : Int32

  # ---------------------------------------------------------------------------
  # mount(2) – Linux-specific
  # ---------------------------------------------------------------------------
  fun mount(
    source : Char*,
    target : Char*,
    filesystemtype : Char*,
    mountflags : UInt64,
    data : Void*,
  ) : Int32

  # ---------------------------------------------------------------------------
  # sethostname(2) – not in Crystal’s standard LibC
  # ---------------------------------------------------------------------------
  fun sethostname(name : Char*, len : LibC::SizeT) : Int32

  # ---------------------------------------------------------------------------
  # Group database struct (only Group is missing; Passwd exists in stdlib)
  # ---------------------------------------------------------------------------
  struct Group
    gr_name : Char*
    gr_passwd : Char*
    gr_gid : UInt32
    gr_mem : Char**
  end

  fun getpwnam(name : Char*) : Passwd*
  fun getgrnam(name : Char*) : Group*

  # ---------------------------------------------------------------------------
  # errno location (GNU extension) + convenience helper
  # ---------------------------------------------------------------------------
  fun __errno_location : Int32*
end

def self.errno : Int32
  __errno_location.value
end
