# spec/integration/supervisor_spec.cr

# Become a child subreaper so that the global reaper can collect children
# even though we are not PID 1.
require "../../src/core/libc"
LibC.prctl(LibC::PR_SET_CHILD_SUBREAPER, 1_u64, 0_u64, 0_u64, 0_u64)

private TEMP_LOG_DIR = "/tmp/litin-integration-logs-#{Random.rand(99_999)}"
Dir.mkdir_p(TEMP_LOG_DIR) rescue nil
ENV["LITIN_LOG_DIR"] = TEMP_LOG_DIR

require "spec"
require "file_utils"
require "../../src/config/service_definition"
require "../../src/service/state"
require "../../src/service/supervisor"

Litin::Service.start_reaper

module Litin::Service
  def self.make_sdef_with_script(
    name : String,
    command : String,
    type : Config::ServiceType = Config::ServiceType::Simple,
    restart : Config::RestartPolicy = Config::RestartPolicy::No,
    extra_script : String? = nil,
    hook_flags : Hash(String, Bool) = {} of String => Bool,
  ) : {Config::ServiceDefinition, String}
    dir = File.tempname("litin-sup-test-#{name}")
    Dir.mkdir_p(dir)

    path = File.join(dir, "service.sh")
    script_content = extra_script || "#!/bin/sh\n# service: #{name}\n"
    File.write(path, script_content)

    sdef = Config::ServiceDefinition.new
    sdef.name = name
    sdef.command = command
    sdef.type = type
    sdef.restart = restart
    sdef.source_path = path
    sdef.timeout_start = 5
    sdef.timeout_stop = 3

    sdef.has_pre_start = hook_flags["pre_start"]? || false
    sdef.has_post_start = hook_flags["post_start"]? || false
    sdef.has_pre_stop = hook_flags["pre_stop"]? || false
    sdef.has_post_stop = hook_flags["post_stop"]? || false
    sdef.has_reload = hook_flags["reload"]? || false
    sdef.has_healthcheck = hook_flags["healthcheck"]? || false

    {sdef, dir}
  end

  describe Supervisor do
    it "runs a simple service and reaches Ready" do
      sdef, dir = make_sdef_with_script(
        "simple-pass",
        "true",
        type: Config::ServiceType::Simple,
        restart: Config::RestartPolicy::No,
      )

      state_ch = Channel(ServiceRecord).new(64)
      rec = ServiceRecord.new(sdef.name, sdef)
      sup = Supervisor.new(rec, REAPER_CHANNEL, state_ch)

      sup.start_fiber
      sleep 2.seconds
      sup.request_stop rescue nil
      sleep 500.milliseconds

      trans = rec.transitions.map(&.to)
      trans.should contain(State::Starting)
      trans.should contain(State::Ready)

      FileUtils.rm_rf(dir)
    end

    it "marks a service Failed when the command is not found" do
      sdef, dir = make_sdef_with_script(
        "notfound",
        "/usr/bin/this-command-does-not-exist-litin-test",
        restart: Config::RestartPolicy::No,
      )

      state_ch = Channel(ServiceRecord).new(64)
      rec = ServiceRecord.new(sdef.name, sdef)
      sup = Supervisor.new(rec, REAPER_CHANNEL, state_ch)

      sup.start_fiber
      sleep 5.seconds
      sup.request_stop rescue nil
      sleep 500.milliseconds

      trans = rec.transitions.map(&.to)
      (trans.includes?(State::Failed) || rec.state.terminal?).should be_true,
        "Expected service to reach Failed or a terminal state. Transitions: #{trans.inspect}"

      FileUtils.rm_rf(dir)
    end

    it "restarts a failed service when restart=on-failure" do
      sdef, dir = make_sdef_with_script(
        "restart-test",
        "false",
        restart: Config::RestartPolicy::OnFailure,
      )
      sdef.restart_sec = 0

      state_ch = Channel(ServiceRecord).new(64)
      rec = ServiceRecord.new(sdef.name, sdef)
      sup = Supervisor.new(rec, REAPER_CHANNEL, state_ch)

      sup.start_fiber
      sleep 8.seconds
      sup.request_stop
      sleep 500.milliseconds

      starting_count = rec.transitions.count { |t| t.to == State::Starting }
      starting_count.should be >= 2,
        "Expected at least 2 Starting transitions, got #{starting_count}. Transitions: #{rec.transitions.map(&.to).inspect}"

      rec.restart_count.should be >= 1

      FileUtils.rm_rf(dir)
    end

    it "stops a running service on request_stop" do
      sdef, dir = make_sdef_with_script(
        "long-running",
        "sleep 60",
        restart: Config::RestartPolicy::No,
      )

      state_ch = Channel(ServiceRecord).new(32)
      rec = ServiceRecord.new(sdef.name, sdef)
      sup = Supervisor.new(rec, REAPER_CHANNEL, state_ch)

      sup.start_fiber

      deadline = Time.utc + 5.seconds
      until rec.state == State::Ready || Time.utc > deadline
        sleep 100.milliseconds
      end
      rec.state.should eq(State::Ready)

      sup.request_stop

      deadline = Time.utc + 10.seconds
      until rec.state == State::Inactive || Time.utc > deadline
        sleep 200.milliseconds
      end
      rec.state.should eq(State::Inactive)
      rec.admin_stopped.should be_true

      FileUtils.rm_rf(dir)
    end

    it "runs pre_start hook before exec" do
      marker = "/tmp/litin-hook-test-#{Random.rand(99_999)}"
      File.delete(marker) rescue nil

      full_script = <<-SH
        name="hook-test"
        command="true"
        pre_start() {
          touch "#{marker}"
          return 0
        }
      SH

      sdef, dir = make_sdef_with_script(
        "hook-test",
        "true",
        type: Config::ServiceType::Simple,
        restart: Config::RestartPolicy::No,
        extra_script: full_script,
        hook_flags: {"pre_start" => true},
      )

      state_ch = Channel(ServiceRecord).new(64)
      rec = ServiceRecord.new(sdef.name, sdef)
      sup = Supervisor.new(rec, REAPER_CHANNEL, state_ch)

      sup.start_fiber
      sleep 1.second
      sup.request_stop rescue nil
      sleep 500.milliseconds

      File.exists?(marker).should be_true
      File.delete(marker) rescue nil
      FileUtils.rm_rf(dir)
    end
  end
end
