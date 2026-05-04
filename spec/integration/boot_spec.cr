# spec/integration/boot_spec.cr
#
# End-to-end integration test: starts a real litind process against a
# temporary service tree, issues commands via the IPC socket, and
# verifies the responses.
#
# This test requires a working Crystal build and a /bin/sh.
# It does NOT require PID 1 or a real system.
#
# The test spawns litind with LITIND_SERVICES_DIR, LITIND_SOCKET_PATH,
# LITIND_LOG_DIR, and LITIND_CGROUP_ENABLED overriding the compiled-in
# defaults via environment variables.  litind must be pre-built at
# build/litind relative to the repo root.

require "spec"
require "file_utils"
require "../../src/core/ipc"

# Skip if litind binary is not built yet.
LITIND_BIN = ENV["LITIND_BIN"]? || File.join(__DIR__, "../../build/litind")

module Litin::Integration
  # -------------------------------------------------------------------------
  # Helpers – module methods to avoid dynamic def error
  # -------------------------------------------------------------------------

  # Write a minimal service.sh into a temporary service directory.
  def self.write_service(
    base_dir : String,
    name : String,
    content : String,
    enabled : Bool = true,
  ) : String
    svc_dir = File.join(base_dir, "services", name)
    Dir.mkdir_p(svc_dir)
    path = File.join(svc_dir, "service.sh")
    File.write(path, content)

    if enabled
      wants_dir = File.join(base_dir, "targets", "default.wants")
      Dir.mkdir_p(wants_dir)
      File.symlink(path, File.join(wants_dir, name)) rescue nil
    end

    path
  end

  # Create a unique temporary directory and return its path.
  def self.make_temp_dir(prefix : String) : String
    tmp = File.tempname(prefix, "")
    Dir.mkdir_p(tmp)
    tmp
  end

  # Spawn a litind instance, wait for its socket, yield an IPC client, then clean up.
  def self.with_litind(& : IPC::Client ->)
    tmp = make_temp_dir("litin-integration")
    socket_path = File.join(tmp, "litind.sock")
    log_dir = File.join(tmp, "logs")
    svc_dir = File.join(tmp, "services")

    Dir.mkdir_p(log_dir)
    Dir.mkdir_p(svc_dir)

    # Write a oneshot "boot" service that just does `true`.
    write_service(tmp, "boot-check", <<-SH, enabled: true)
      name="boot-check"
      description="Integration test boot check"
      command="true"
      type="oneshot"
      restart="no"
      target="default"
    SH

    env = ENV.to_h.merge({
      "LITIND_SERVICES_DIR"   => svc_dir,
      "LITIND_SOCKET_PATH"    => socket_path,
      "LITIND_LOG_DIR"        => log_dir,
      "LITIND_CGROUP_ENABLED" => "false",
    })

    proc = Process.new(
      command: LITIND_BIN,
      env: env,
      output: Process::Redirect::Pipe,
      error: Process::Redirect::Pipe
    )

    # Wait for the socket to appear (up to 10 seconds).
    deadline = Time.utc + 10.seconds
    until File.exists?(socket_path) || Time.utc > deadline
      sleep 100.milliseconds
    end

    raise "litind did not start (no socket at #{socket_path})" unless File.exists?(socket_path)

    client = IPC::Client.new(socket_path)

    begin
      yield client
    ensure
      client.close rescue nil
      proc.signal(Signal::TERM) rescue nil
      proc.wait rescue nil
      FileUtils.rm_rf(tmp)
    end
  end

  # -------------------------------------------------------------------------
  # Tests
  # -------------------------------------------------------------------------

  describe "litind boot and IPC" do
    pending "litind binary not built — set LITIND_BIN or run `make`" unless File.exists?(LITIND_BIN)

    it "responds to a 'list' request" do
      with_litind do |client|
        responses = [] of IPC::Response
        client.request("list", [] of String, {} of String => String) do |r|
          responses << r
        end
        responses.any? { |r| r.ok }.should be_true
      end
    end

    it "responds to a 'status' request with no args" do
      with_litind do |client|
        ok_count = 0
        client.request("status", [] of String, {} of String => String) do |r|
          ok_count += 1 if r.ok
        end
        ok_count.should be >= 1
      end
    end

    it "returns an error for an unknown service" do
      with_litind do |client|
        responses = [] of IPC::Response
        client.request("status", ["no-such-service"], {} of String => String) do |r|
          responses << r
        end
        responses.any? { |r| !r.ok && r.payload.includes?("no-such-service") }.should be_true
      end
    end

    it "returns an error for an unknown action" do
      with_litind do |client|
        responses = [] of IPC::Response
        client.request("frobnicate", [] of String, {} of String => String) do |r|
          responses << r
        end
        responses.any? { |r| !r.ok }.should be_true
      end
    end

    it "responds to list-targets" do
      with_litind do |client|
        responses = [] of IPC::Response
        client.request("list-targets", [] of String, {} of String => String) do |r|
          responses << r
        end
        responses.any? { |r| r.ok }.should be_true
      end
    end

    it "responds to deps for a known service" do
      with_litind do |client|
        responses = [] of IPC::Response
        client.request("deps", ["boot-check"], {} of String => String) do |r|
          responses << r
        end
        responses.any? { |r| r.ok }.should be_true
      end
    end

    it "gracefully handles a reload-daemon request" do
      with_litind do |client|
        responses = [] of IPC::Response
        client.request("reload-daemon", [] of String, {} of String => String) do |r|
          responses << r
        end
        responses.any? { |r| r.ok }.should be_true
      end
    end
  end
end
