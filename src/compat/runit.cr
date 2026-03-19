# src/compat/runit.cr
#
# Runit compatibility layer.
#
# Maps Runit command semantics onto litinctl IPC calls. Supports the
# commands that appear most frequently in existing Runit service trees
# and packaging scripts.
#
# sv(8) command mapping:
#   sv up <svc>       -> start
#   sv down <svc>     -> stop
#   sv restart <svc>  -> restart
#   sv reload <svc>   -> reload
#   sv status <svc>   -> status
#   sv once <svc>     -> start (restart=no is handled at definition level)
#   sv pause <svc>    -> stop
#   sv hup <svc>      -> reload
#   sv term <svc>     -> stop
#   sv kill <svc>     -> stop (force)
#   sv check <svc>    -> is-active check (exit 0 = up)
#
# runsvdir(8):
#   runsvdir <dir>
#   In Runit, runsvdir watches a directory and manages services in it.
#   Under Litin, we interpret this as a request to load services from
#   the given directory and start them all. This covers the common
#   use-case of `runsvdir /etc/service` in a container entrypoint.
#
# chpst(8):
#   chpst [-u user[:group]] [-e envdir] [-/ newroot] -- command [args...]
#   Sets credentials and environment, then execs the command.
#   This is implemented entirely in-process (no IPC needed).

require "../core/ipc"
require "../util/env_dir"

module Litin
  module Compat
    module Runit
      # ---------------------------------------------------------------------------
      # sv
      # ---------------------------------------------------------------------------

      def self.sv(argv : Array(String)) : Int32
        if argv.empty?
          STDERR.puts "Usage: sv <action> <service...>"
          return 1
        end

        raw_action = argv[0]
        services = argv[1..]

        if services.empty?
          STDERR.puts "sv: action '#{raw_action}' requires at least one service"
          return 1
        end

        litinctl_action = case raw_action
                          when "up", "start" then "start"
                          when "down", "stop",
                               "term", "pause" then "stop"
                          when "restart" then "restart"
                          when "reload", "hup",
                               "force-reload" then "reload"
                          when "status" then "status"
                          when "once"   then "start"
                          when "check"  then "is-active"
                          when "kill"   then "stop" # litind will SIGKILL on timeout
                          else
                            STDERR.puts "sv: unknown action '#{raw_action}'"
                            return 1
                          end

        if litinctl_action == "is-active"
          return check_active(services)
        end

        ipc_call(litinctl_action, services)
      end

      # ---------------------------------------------------------------------------
      # runsvdir
      # ---------------------------------------------------------------------------

      # runsvdir <dir> — load all services from the given directory, start them.
      # In container environments this is often called as the entrypoint.
      def self.runsvdir(argv : Array(String)) : Int32
        dir = argv.reject { |a| a.starts_with?("-") }.first?

        unless dir
          STDERR.puts "Usage: runsvdir <dir>"
          return 1
        end

        unless Dir.exists?(dir)
          STDERR.puts "runsvdir: directory not found: #{dir}"
          return 1
        end

        STDOUT.puts "runsvdir: loading services from #{dir}"

        # Collect service names from the directory.
        services = [] of String
        Dir.each_child(dir) do |entry|
          path = File.join(dir, entry)
          # Accept Runit-style directories with a 'run' script,
          # or Litin-style directories with a 'service.sh'.
          if File.directory?(path)
            has_run = File.exists?(File.join(path, "run"))
            has_svc_sh = File.exists?(File.join(path, "service.sh"))
            services << entry if has_run || has_svc_sh
          end
        end

        if services.empty?
          STDERR.puts "runsvdir: no services found in #{dir}"
          return 0
        end

        STDOUT.puts "runsvdir: starting #{services.size} service(s): #{services.join(", ")}"
        ipc_call("start", services)
      end

      # ---------------------------------------------------------------------------
      # chpst
      # ---------------------------------------------------------------------------

      # chpst [-u user[:group]] [-e envdir] [-/ newroot] [-b argv0] -- cmd [args]
      # Sets up credentials and environment, then execs. Does not need IPC.
      def self.chpst(argv : Array(String)) : Int32
        user = nil.as(String?)
        group = nil.as(String?)
        env_dir = nil.as(String?)
        new_root = nil.as(String?)
        argv0 = nil.as(String?)
        cmd_start = argv.size # index where -- or command begins

        i = 0
        while i < argv.size
          case argv[i]
          when "-u"
            i += 1
            if i < argv.size
              ug = argv[i].split(':', 2)
              user = ug[0]
              group = ug[1]? || user
            end
          when "-e"
            i += 1
            env_dir = argv[i] if i < argv.size
          when "-/"
            i += 1
            new_root = argv[i] if i < argv.size
          when "-b"
            i += 1
            argv0 = argv[i] if i < argv.size
          when "--"
            cmd_start = i + 1
            break
          else
            # First non-flag argument is the command.
            cmd_start = i
            break
          end
          i += 1
        end

        cmd_argv = argv[cmd_start..]
        if cmd_argv.empty?
          STDERR.puts "chpst: no command specified"
          return 1
        end

        # Build environment.
        env = ENV.to_h
        if dir = env_dir
          Util::EnvDir.read(dir).each { |k, v| env[k] = v }
        end

        # Apply new root (chroot).
        if root = new_root
          ret = LibC.chroot(root)
          if ret != 0
            STDERR.puts "chpst: chroot(#{root}) failed: #{Errno.new(LibC.errno).message}"
            return 1
          end
          LibC.chdir("/")
        end

        # Drop privileges.
        if u = user
          if g = group
            gid = lookup_gid(g)
            if gid
              LibC.setgid(gid)
            else
              STDERR.puts "chpst: unknown group: #{g}"
              return 1
            end
          end
          uid = lookup_uid(u)
          if uid
            LibC.setuid(uid)
          else
            STDERR.puts "chpst: unknown user: #{u}"
            return 1
          end
        end

        # Exec the command.
        command = cmd_argv[0]
        args = cmd_argv[1..]
        exec_argv0 = argv0 || command

        # We use Process.exec-style replacement. Crystal does not expose
        # execve directly, so we use Process.new with exec semantics via
        # a shell substitution. For a clean exec() we need to call LibC.
        exec_command(exec_argv0, command, args, env)
      end

      # ---------------------------------------------------------------------------
      # Private helpers
      # ---------------------------------------------------------------------------

      private def self.check_active(services : Array(String)) : Int32
        services.each do |name|
          begin
            client = IPC::Client.new
          rescue
            STDERR.puts "sv: cannot connect to litind"
            return 1
          end

          state = "unknown"
          client.request("status", [name], {} of String => String) do |resp|
            if resp.ok && !resp.payload.empty?
              state = resp.payload.split(": ", 2)[1]?.to_s.split.first? || "unknown"
            end
          end
          client.close

          unless state == "ready" || state == "degraded"
            STDERR.puts "#{name}: #{state}"
            return 1
          end
          puts "#{name}: up"
        end
        0
      end

      private def self.ipc_call(action : String, services : Array(String)) : Int32
        begin
          client = IPC::Client.new
        rescue
          STDERR.puts "sv: cannot connect to litind"
          return 1
        end

        exit_code = 0
        client.request(action, services, {} of String => String) do |resp|
          if resp.ok
            puts resp.payload unless resp.payload.empty?
          else
            STDERR.puts "sv: #{resp.payload}"
            exit_code = 1
          end
        end
        client.close
        exit_code
      end

      private def self.lookup_uid(user : String) : LibC::UidT?
        pw = LibC.getpwnam(user)
        return nil if pw.null?
        pw.value.pw_uid
      end

      private def self.lookup_gid(group : String) : LibC::GidT?
        gr = LibC.getgrnam(group)
        return nil if gr.null?
        gr.value.gr_gid
      end

      private def self.exec_command(
        argv0 : String,
        command : String,
        args : Array(String),
        env : Hash(String, String),
      ) : Int32
        # Build the full argv array for execve.
        full_args = [argv0] + args

        # Set environment variables in the current process before exec.
        env.each { |k, v| ENV[k] = v }

        # exec(2) — replace current process image.
        Process.exec(command, args, env: env)
        0 # unreachable

      rescue ex
        STDERR.puts "chpst: exec failed: #{ex.message}"
        111
      end
    end
  end
end

lib LibC
  fun chroot(path : Char*) : Int32
  fun chdir(path : Char*) : Int32

  struct Passwd
    pw_name : Char*
    pw_passwd : Char*
    pw_uid : UidT
    pw_gid : GidT
    pw_gecos : Char*
    pw_dir : Char*
    pw_shell : Char*
  end

  struct Group
    gr_name : Char*
    gr_passwd : Char*
    gr_gid : GidT
    gr_mem : Char**
  end

  fun getpwnam(name : Char*) : Passwd*
  fun getgrnam(name : Char*) : Group*
  fun setuid(uid : UidT) : Int32
  fun setgid(gid : GidT) : Int32
end
