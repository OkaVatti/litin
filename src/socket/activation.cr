# src/socket/activation.cr
#
# Socket activation for Litin.
#
# Implements the sd_listen_fds(3) protocol so that services written
# for systemd socket activation work unmodified under Litin.
#
# Protocol summary:
#   - litind creates and binds sockets defined in socket unit files.
#   - When a connection arrives, litind starts the associated service
#     (if not already running) and passes the socket FD(s) to it via
#     inheritance plus the environment variables:
#       LISTEN_PID=<pid>          PID of the service process
#       LISTEN_FDS=<n>            number of FDs passed, starting at FD 3
#       LISTEN_FDNAMES=<n1:n2:..> colon-separated socket names
#   - The service calls sd_listen_fds() (or reads the env vars directly)
#     to know how many FDs to expect and at which file descriptor number.
#
# Socket unit file format (parsed here):
#   listen="0.0.0.0:22"          TCP address:port
#   listen="unix:/run/foo.sock"   UNIX domain socket
#   service="sshd"                which service to activate
#   accept="no"                   if "yes", fork one instance per connection
#   backlog="128"
#   socket_user="root"
#   socket_group="root"
#   socket_mode="0660"

require "../core/ipc"
require "../core/libc"

module Litin
  module Socket
    # Parsed socket unit definition.
    class SocketUnit
      property name : String = ""
      property listen : String = ""  # "host:port" or "unix:/path"
      property service : String = "" # associated service name
      property accept : Bool = false # one instance per connection?
      property backlog : Int32 = 128
      property socket_user : String = "root"
      property socket_group : String = "root"
      property socket_mode : Int32 = 0o660
      property source_path : String = ""

      def unix? : Bool
        listen.starts_with?("unix:")
      end

      def unix_path : String
        listen.lchop("unix:")
      end

      def tcp_address : String
        listen.rpartition(':')[0]
      end

      def tcp_port : Int32
        listen.rpartition(':')[2].to_i? || 0
      end
    end

    # ---------------------------------------------------------------------------
    # Socket unit parser
    # ---------------------------------------------------------------------------

    class SocketParser
      SOCKETS_DIR = "/etc/litin/sockets"

      SCALAR_RE = /^[ \t]*([A-Za-z_][A-Za-z0-9_]*)[ \t]*=[ \t]*(?:"([^"\\]*)"|'([^'\\]*)'|([^\s#]+))/

      def self.load_all(dir : String = SOCKETS_DIR) : Array(SocketUnit)
        result = [] of SocketUnit
        return result unless Dir.exists?(dir)

        Dir.each_child(dir) do |entry|
          next unless entry.ends_with?(".socket")
          path = File.join(dir, entry)
          begin
            unit = parse_file(path)
            # Use String#chomp to strip a specific suffix (not #rstrip which strips chars).
            unit.name = entry.chomp(".socket") if unit.name.empty?
            result << unit
          rescue ex
            STDERR.puts "[socket parser] skipping #{path}: #{ex.message}"
          end
        end

        result
      end

      def self.parse_file(path : String) : SocketUnit
        unit = SocketUnit.new
        unit.source_path = path

        File.each_line(path) do |raw_line|
          line = raw_line.strip
          next if line.empty? || line.starts_with?('#')

          if m = line.match(SCALAR_RE)
            key = m[1]
            value = (m[2]? || m[3]? || m[4]? || "").strip

            case key
            when "listen"       then unit.listen = value
            when "service"      then unit.service = value
            when "accept"       then unit.accept = (value == "yes" || value == "true")
            when "backlog"      then unit.backlog = value.to_i? || 128
            when "socket_user"  then unit.socket_user = value
            when "socket_group" then unit.socket_group = value
            when "socket_mode"  then unit.socket_mode = value.to_i(8) rescue 0o660
            when "name"         then unit.name = value
            end
          end
        end

        raise "socket unit #{path}: missing 'listen' field" if unit.listen.empty?
        raise "socket unit #{path}: missing 'service' field" if unit.service.empty?

        unit
      end
    end

    # ---------------------------------------------------------------------------
    # Active socket binding
    # ---------------------------------------------------------------------------

    # Represents a bound, listening socket owned by litind.
    class BoundSocket
      getter unit : SocketUnit
      getter fd : Int32
      # raw can be a UNIX or TCP server – both have an `fd` method.
      getter raw : UNIXServer | TCPServer

      def initialize(@unit, @raw : UNIXServer | TCPServer)
        @fd = @raw.fd
      end

      def close
        @raw.close rescue nil
      end
    end

    # ---------------------------------------------------------------------------
    # Socket Manager — owned by litind
    # ---------------------------------------------------------------------------

    # Callback type: called when a socket receives a connection.
    alias ActivationCallback = Proc(String, BoundSocket, Nil)

    class Manager
      def initialize(@on_activate : ActivationCallback)
        @sockets = [] of BoundSocket
      end

      def bind_all(units : Array(SocketUnit)) : Nil
        units.each do |unit|
          begin
            bs = bind_unit(unit)
            @sockets << bs
            STDOUT.puts "[socket] bound #{unit.name}: #{unit.listen}"
          rescue ex
            STDERR.puts "[socket] failed to bind #{unit.name} (#{unit.listen}): #{ex.message}"
          end
        end
      end

      def start_listening : Nil
        @sockets.each do |bs|
          spawn { accept_loop(bs) }
        end
      end

      def sockets_for(service_name : String) : Array(BoundSocket)
        @sockets.select { |bs| bs.unit.service == service_name }
      end

      def close_for(service_name : String) : Nil
        @sockets.select! do |bs|
          if bs.unit.service == service_name
            bs.close
            false
          else
            true
          end
        end
      end

      def all_units : Array(SocketUnit)
        @sockets.map(&.unit)
      end

      private def bind_unit(unit : SocketUnit) : BoundSocket
        unit.unix? ? bind_unix(unit) : bind_tcp(unit)
      end

      private def bind_unix(unit : SocketUnit) : BoundSocket
        path = unit.unix_path
        File.delete(path) rescue nil
        Dir.mkdir_p(File.dirname(path))
        server = UNIXServer.new(path)
        File.chmod(path, unit.socket_mode)
        BoundSocket.new(unit, server)
      end

      private def bind_tcp(unit : SocketUnit) : BoundSocket
        addr = unit.tcp_address
        port = unit.tcp_port
        raise "invalid port in socket unit #{unit.name}" if port == 0
        server = TCPServer.new(addr, port, backlog: unit.backlog)
        server.reuse_address = true
        BoundSocket.new(unit, server)
      end

      private def accept_loop(bs : BoundSocket) : Nil
        loop do
          raw_io = bs.raw

          case raw_io
          when UNIXServer
            conn = raw_io.accept?
            if conn
              conn.close rescue nil
              @on_activate.call(bs.unit.service, bs)
            end
          when TCPServer
            conn = raw_io.accept?
            if conn
              conn.close rescue nil
              @on_activate.call(bs.unit.service, bs)
            end
          end
        rescue ex : IO::Error
          break
        rescue ex
          STDERR.puts "[socket:#{bs.unit.name}] accept error: #{ex.message}"
          sleep 1.second
        end
      end
    end

    # ---------------------------------------------------------------------------
    # FD passing — build the environment variables for sd_listen_fds protocol
    # ---------------------------------------------------------------------------

    def self.build_listen_env(pid : Int32, sockets : Array(BoundSocket)) : Hash(String, String)
      env = {} of String => String
      env["LISTEN_PID"] = pid.to_s
      env["LISTEN_FDS"] = sockets.size.to_s
      env["LISTEN_FDNAMES"] = sockets.map(&.unit.name).join(":")
      env
    end

    # Clear FD_CLOEXEC on a file descriptor so it survives exec.
    def self.clear_cloexec(fd : Int32) : Nil
      flags = LibC.fcntl(fd, LibC::F_GETFD, 0)
      return if flags < 0
      LibC.fcntl(fd, LibC::F_SETFD, flags & ~LibC::FD_CLOEXEC)
    end
  end
end
