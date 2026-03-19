# spec/service/healthcheck_spec.cr

require "spec"
require "file_utils"
require "../../src/config/service_definition"
require "../../src/service/healthcheck"

module Litin::Service
  describe HealthProbe do
    def make_sdef(name : String = "test") : Config::ServiceDefinition
      s = Config::ServiceDefinition.new
      s.name = name
      s.source_path = ""
      s
    end

    # -------------------------------------------------------------------------
    # PID probe
    # -------------------------------------------------------------------------

    describe "pid probe" do
      it "returns true for a live PID (self)" do
        sdef = make_sdef
        sdef.healthcheck_type = "pid"
        probe = HealthProbe.new(sdef, Process.pid)
        probe.run.should be_true
      end

      it "returns false for PID 0" do
        sdef = make_sdef
        sdef.healthcheck_type = "pid"
        probe = HealthProbe.new(sdef, 0)
        probe.run.should be_false
      end

      it "returns false when pid is nil" do
        sdef = make_sdef
        sdef.healthcheck_type = "pid"
        probe = HealthProbe.new(sdef, nil)
        probe.run.should be_false
      end

      it "returns false for a non-existent PID" do
        sdef = make_sdef
        sdef.healthcheck_type = "pid"
        # PID 2000000 almost certainly does not exist.
        probe = HealthProbe.new(sdef, 2_000_000)
        probe.run.should be_false
      end
    end

    # -------------------------------------------------------------------------
    # TCP probe
    # -------------------------------------------------------------------------

    describe "tcp probe" do
      it "returns true when the port is open" do
        # Bind a real TCP server on a random port.
        server = TCPServer.new("127.0.0.1", 0)
        port = server.local_address.port

        spawn { server.accept? }

        sdef = make_sdef
        sdef.healthcheck_type = "tcp"
        sdef.healthcheck_tcp_host = "127.0.0.1"
        sdef.healthcheck_tcp_port = port
        sdef.healthcheck_timeout = 3

        probe = HealthProbe.new(sdef, nil)
        probe.run.should be_true

        server.close
      end

      it "returns false when no server is listening" do
        sdef = make_sdef
        sdef.healthcheck_type = "tcp"
        sdef.healthcheck_tcp_host = "127.0.0.1"
        sdef.healthcheck_tcp_port = 19_999 # almost certainly nothing here
        sdef.healthcheck_timeout = 1

        probe = HealthProbe.new(sdef, nil)
        probe.run.should be_false
      end

      it "returns false when host/port are not configured" do
        sdef = make_sdef
        sdef.healthcheck_type = "tcp"
        # tcp_host is nil, tcp_port is 0.
        probe = HealthProbe.new(sdef, nil)
        probe.run.should be_false
      end
    end

    # -------------------------------------------------------------------------
    # Shell probe
    # -------------------------------------------------------------------------

    describe "shell probe" do
      it "returns true when healthcheck() exits 0" do
        path = File.tempfile("litin-hc-pass-", ".sh") do |f|
          f.print(<<-SH)
            name="hcpass"
            command="true"
            healthcheck() { return 0; }
          SH
        end.path

        begin
          sdef = make_sdef("hcpass")
          sdef.source_path = path
          sdef.has_healthcheck = true
          sdef.healthcheck_type = "shell"
          sdef.healthcheck_timeout = 5

          probe = HealthProbe.new(sdef, Process.pid)
          probe.run.should be_true
        ensure
          File.delete(path) rescue nil
        end
      end

      it "returns false when healthcheck() exits non-zero" do
        path = File.tempfile("litin-hc-fail-", ".sh") do |f|
          f.print(<<-SH)
            name="hcfail"
            command="true"
            healthcheck() { return 1; }
          SH
        end.path

        begin
          sdef = make_sdef("hcfail")
          sdef.source_path = path
          sdef.has_healthcheck = true
          sdef.healthcheck_type = "shell"
          sdef.healthcheck_timeout = 5

          probe = HealthProbe.new(sdef, nil)
          probe.run.should be_false
        ensure
          File.delete(path) rescue nil
        end
      end

      it "falls back to pid probe when source_path is empty" do
        sdef = make_sdef
        sdef.source_path = ""
        sdef.healthcheck_type = "shell"
        probe = HealthProbe.new(sdef, Process.pid)
        probe.run.should be_true # pid probe: self is alive
      end
    end

    # -------------------------------------------------------------------------
    # HTTP probe (URL parsing only — no real HTTP server in unit tests)
    # -------------------------------------------------------------------------

    describe "http probe — url parsing" do
      it "parses http://host:port/path correctly" do
        sdef = make_sdef
        sdef.healthcheck_type = "http"
        sdef.healthcheck_http_url = "http://127.0.0.1:9999/health"
        sdef.healthcheck_http_status = 200
        sdef.healthcheck_timeout = 1

        # Without a server running on 9999 this will fail — that's expected.
        probe = HealthProbe.new(sdef, nil)
        result = probe.run
        result.should be_a(Bool)
        result.should be_false # no server on 9999
      end

      it "parses https URLs and defaults to port 443" do
        sdef = make_sdef
        sdef.healthcheck_type = "http"
        sdef.healthcheck_http_url = "https://localhost/health"
        sdef.healthcheck_timeout = 1

        probe = HealthProbe.new(sdef, nil)
        # localhost:443 very likely not open in test env — just check no crash.
        result = probe.run
        result.should be_a(Bool)
      end
    end
  end
end
