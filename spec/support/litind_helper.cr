require "file_utils"
require "process"
require "../../src/core/ipc"

module LitinIntegrationHelper
  LITIND_BIN = ENV["LITIND_BIN"]? || File.join(__DIR__, "../../build/litind")

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
  def self.with_litind(& : Litin::IPC::Client ->)
    tmp = make_temp_dir("litin-integration")
    socket_path = File.join(tmp, "litind.sock")
    log_dir = File.join(tmp, "logs")
    svc_dir = File.join(tmp, "services")

    Dir.mkdir_p(log_dir)
    Dir.mkdir_p(svc_dir)

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

    deadline = Time.utc + 10.seconds
    until File.exists?(socket_path) || Time.utc > deadline
      sleep 100.milliseconds
    end

    raise "litind did not start (no socket at #{socket_path})" unless File.exists?(socket_path)

    client = Litin::IPC::Client.new(socket_path)

    begin
      yield client
    ensure
      client.close rescue nil
      proc.signal(Signal::TERM) rescue nil
      proc.wait rescue nil
      FileUtils.rm_rf(tmp)
    end
  end
end
