# src/service/healthcheck.cr
#
# Healthcheck prober — runs health checks against services by one of
# several mechanisms and reports pass/fail.
#
# Probe types:
#
#   shell     Source the service file and invoke healthcheck().
#             This is the default when `has_healthcheck` is true.
#
#   http      Send an HTTP GET or HEAD to a URL and check the status code.
#             Configured via healthcheck_http_url, healthcheck_http_method,
#             healthcheck_http_status (default 200).
#
#   tcp       Attempt a TCP connection to host:port.
#             Configured via healthcheck_tcp_host, healthcheck_tcp_port.
#
#   pid       Check that the process is still alive via kill(pid, 0).
#             Automatically applied when pid is set and no other probe
#             is configured.
#
# Service definition fields used here:
#   healthcheck_type      "shell" | "http" | "tcp" | "pid"  (default: shell)
#   healthcheck_http_url  "http://127.0.0.1:8080/health"
#   healthcheck_http_method "GET" | "HEAD"  (default: GET)
#   healthcheck_http_status  200  (expected status code)
#   healthcheck_tcp_host  "127.0.0.1"
#   healthcheck_tcp_port  8080
#   healthcheck_interval  30  (seconds between checks)
#   healthcheck_retries   3   (consecutive failures before Degraded)
#   healthcheck_timeout   5   (seconds per probe attempt)
#
# These fields are added to ServiceDefinition as optional properties.
# They default to sensible values when absent.

require "../config/service_definition"
require "../core/libc"

module Litin
  module Service
    class HealthProbe
      DEFAULT_INTERVAL = 30.seconds
      DEFAULT_RETRIES  = 3
      DEFAULT_TIMEOUT  = 5.seconds

      getter sdef : Config::ServiceDefinition
      getter pid : Int32?
      getter env : Hash(String, String)?

      def initialize(
        @sdef : Config::ServiceDefinition,
        @pid : Int32?,
        @env : Hash(String, String)? = nil,
      )
      end

      # Run the appropriate probe and return true (healthy) or false.
      def run : Bool
        case probe_type
        when "http" then probe_http
        when "tcp"  then probe_tcp
        when "pid"  then probe_pid
        else             probe_shell
        end
      rescue ex
        STDERR.puts "[healthcheck:#{@sdef.name}] probe error: #{ex.message}"
        false
      end

      # -----------------------------------------------------------------------
      # Probe implementations
      # -----------------------------------------------------------------------

      private def probe_shell : Bool
        source = @sdef.source_path
        return probe_pid if source.empty?
        return false unless @sdef.has_healthcheck

        pid_val = @pid || ""
        script = <<-SH
          . "#{source}"
          MAINPID=#{pid_val}
          export MAINPID
          healthcheck
        SH

        timeout_s = @sdef.healthcheck_timeout.seconds
        run_with_timeout(script, timeout_s)
      end

      private def probe_http : Bool
        url = @sdef.healthcheck_http_url
        return false unless url && !url.empty?

        method = @sdef.healthcheck_http_method.upcase
        expected = @sdef.healthcheck_http_status
        timeout_s = @sdef.healthcheck_timeout

        # We use curl if available (most Linux systems), otherwise fall back
        # to a native TCP check of just the port.
        if system_has_curl?
          flag = method == "HEAD" ? "-I" : "-s"
          script = "curl #{flag} -o /dev/null -w '%{http_code}' --max-time #{timeout_s} '#{url}' 2>/dev/null"
          io = IO::Memory.new
          status = Process.run("/bin/sh", args: ["-c", script],
            output: io, error: Process::Redirect::Close)
          return false unless status.success?
          code = io.to_s.strip.to_i?
          code == expected
        else
          # No curl: parse the URL and do a raw TCP connection.
          uri = parse_url_host_port(url)
          return false unless uri
          probe_tcp_raw(uri[:host], uri[:port])
        end
      rescue ex
        STDERR.puts "[healthcheck:#{@sdef.name}] http probe error: #{ex.message}"
        false
      end

      private def probe_tcp : Bool
        host = @sdef.healthcheck_tcp_host
        port = @sdef.healthcheck_tcp_port
        return false unless host && port && port > 0
        probe_tcp_raw(host, port)
      end

      private def probe_tcp_raw(host : String, port : Int32) : Bool
        timeout_s = @sdef.healthcheck_timeout
        sock = TCPSocket.new(host, port, connect_timeout: timeout_s.seconds)
        sock.close
        true
      rescue
        false
      end

      private def probe_pid : Bool
        p = @pid
        return false unless p && p > 0
        LibC.kill(p, 0) == 0
      end

      # -----------------------------------------------------------------------
      # Helpers
      # -----------------------------------------------------------------------

      private def probe_type : String
        t = @sdef.healthcheck_type
        return "shell" if t.nil? || t.empty?
        t
      end

      private def run_with_timeout(script : String, timeout : Time::Span) : Bool
        done_ch = Channel(Bool).new(1)
        spawn do
          status = Process.run(
            "/bin/sh",
            args: ["-c", script],
            env: @env,
            output: Process::Redirect::Close,
            error: Process::Redirect::Close
          )
          done_ch.send(status.success?) rescue nil
        end

        select
        when result = done_ch.receive
          result
        when timeout(timeout)
          false
        end
      end

      private def system_has_curl? : Bool
        Process.run("which", args: ["curl"],
          output: Process::Redirect::Close,
          error: Process::Redirect::Close
        ).success?
      rescue
        false
      end

      private def parse_url_host_port(url : String) : {host: String, port: Int32}?
        # Very minimal URL parser for http(s)://host[:port]/path
        rest = url.lchop("https://").lchop("http://")
        host_port, _ = rest.split('/', 2)
        if host_port.includes?(':')
          host, _, port_s = host_port.rpartition(':')
          port = port_s.to_i?
          return {host: host, port: port} if port
        else
          port = url.starts_with?("https") ? 443 : 80
          return {host: host_port, port: port}
        end
        nil
      end
    end
  end
end

# Extend ServiceDefinition with healthcheck configuration fields.
module Litin
  module Config
    class ServiceDefinition
      property healthcheck_type : String = "shell"
      property healthcheck_http_url : String? = nil
      property healthcheck_http_method : String = "GET"
      property healthcheck_http_status : Int32 = 200
      property healthcheck_tcp_host : String? = nil
      property healthcheck_tcp_port : Int32 = 0
      property healthcheck_interval : Int32 = 30
      property healthcheck_retries : Int32 = 3
      property healthcheck_timeout : Int32 = 5
    end
  end
end
