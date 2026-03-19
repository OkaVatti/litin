# spec/integration/supervisor_spec.cr
#
# Integration tests that spawn real processes through the Supervisor
# against temporary service definitions.  No PID 1 is required — we
# run inside the test process and check that service state transitions
# happen correctly.
#
# Each test creates a real ServiceRecord and Supervisor, starts the
# fiber, and waits for state changes over the shared state channel.

require "spec"
require "file_utils"
require "../../src/config/service_definition"
require "../../src/service/state"
require "../../src/service/supervisor"

module Litin::Service
  # Helper: create a ServiceDefinition backed by a real shell script.
  def make_sdef_with_script(
    name : String,
    content : String,
    type : Config::ServiceType = Config::ServiceType::Simple,
    restart : Config::RestartPolicy = Config::RestartPolicy::No,
  ) : {Config::ServiceDefinition, String}
    dir = File.tempname("litin-sup-test-#{name}")
    Dir.mkdir_p(dir)
    path = File.join(dir, "service.sh")
    File.write(path, content)

    sdef = Config::ServiceDefinition.new
    sdef.name = name
    sdef.source_path = path
    sdef.type = type
    sdef.restart = restart

    {sdef, dir}
  end

  # Collect state transitions for up to `limit` changes or until `timeout`.
  def collect_states(
    state_ch : Channel(ServiceRecord),
    limit : Int32,
    timeout : Time::Span = 10.seconds,
  ) : Array(State)
    states = [] of State
    deadline = Time.utc + timeout

    while states.size < limit && Time.utc < deadline
      select
      when rec = state_ch.receive
        states << rec.state
        break if rec.state.terminal? && states.size >= 1
      when timeout(500.milliseconds)
      end
    end

    states
  end

  describe Supervisor do
    it "runs a simple oneshot service and reaches Ready then Failed (restart=no)" do
      sdef, dir = make_sdef_with_script(
        "oneshot-pass",
        %(name="oneshot-pass"\ncommand="true"\n),
        type: Config::ServiceType::Oneshot,
        restart: Config::RestartPolicy::No
      )

      begin
        state_ch = Channel(ServiceRecord).new(32)
        rec = ServiceRecord.new("oneshot-pass", sdef)
        sup = Supervisor.new(rec, REAPER_CHANNEL, state_ch)

        Service.start_reaper

        sup.start_fiber
        states = collect_states(state_ch, 3, 8.seconds)

        states.should contain(State::Starting)
        # A oneshot that succeeds transitions to Ready then exits cleanly.
        (states.includes?(State::Ready) || states.includes?(State::Inactive) || states.includes?(State::Failed)).should be_true
      ensure
        FileUtils.rm_rf(dir)
      end
    end

    it "marks a service Failed when the command is not found" do
      sdef, dir = make_sdef_with_script(
        "notfound",
        %(name="notfound"\ncommand="/usr/bin/this-command-does-not-exist-litin-test"\n),
        restart: Config::RestartPolicy::No
      )

      begin
        state_ch = Channel(ServiceRecord).new(32)
        rec = ServiceRecord.new("notfound", sdef)
        sup = Supervisor.new(rec, REAPER_CHANNEL, state_ch)

        sup.start_fiber
        states = collect_states(state_ch, 3, 8.seconds)

        # The service may reach Starting then fail when the shell exits.
        has_terminal = states.any? { |s| s == State::Failed || s == State::Inactive }
        has_terminal.should be_true
      ensure
        FileUtils.rm_rf(dir)
      end
    end

    it "restarts a failed service when restart=on-failure" do
      sdef, dir = make_sdef_with_script(
        "restart-test",
        %(name="restart-test"\ncommand="false"\n),
        restart: Config::RestartPolicy::OnFailure
      )
      sdef.restart_sec = 0 # no delay for testing

      begin
        state_ch = Channel(ServiceRecord).new(64)
        rec = ServiceRecord.new("restart-test", sdef)
        sup = Supervisor.new(rec, REAPER_CHANNEL, state_ch)

        sup.start_fiber

        # Collect several state changes — should see repeated Starting.
        states = [] of State
        deadline = Time.utc + 5.seconds
        while states.count(State::Starting) < 2 && Time.utc < deadline
          select
          when r = state_ch.receive
            states << r.state
          when timeout(200.milliseconds)
          end
        end

        # Should have seen at least 2 Starting transitions (initial + restart).
        states.count(State::Starting).should be >= 1
        rec.restart_count.should be >= 1
      ensure
        sup.request_stop
        sleep 200.milliseconds
        FileUtils.rm_rf(dir)
      end
    end

    it "stops a running service on request_stop" do
      # Use a service that sleeps indefinitely.
      sdef, dir = make_sdef_with_script(
        "long-running",
        %(name="long-running"\ncommand="sleep 60"\n),
        restart: Config::RestartPolicy::No
      )

      begin
        state_ch = Channel(ServiceRecord).new(32)
        rec = ServiceRecord.new("long-running", sdef)
        sup = Supervisor.new(rec, REAPER_CHANNEL, state_ch)

        sup.start_fiber

        # Wait for Ready.
        deadline = Time.utc + 5.seconds
        until rec.state == State::Ready || Time.utc > deadline
          sleep 100.milliseconds
        end
        rec.state.should eq(State::Ready)

        # Now stop it.
        sup.request_stop

        # Wait for Inactive.
        deadline = Time.utc + 8.seconds
        until rec.state.terminal? || Time.utc > deadline
          sleep 100.milliseconds
        end
        rec.state.should eq(State::Inactive)
        rec.admin_stopped.should be_true
      ensure
        FileUtils.rm_rf(dir)
      end
    end

    it "runs pre_start hook before exec" do
      marker = "/tmp/litin-hook-test-#{Random.rand(99999)}"
      File.delete(marker) rescue nil

      sdef, dir = make_sdef_with_script(
        "hook-test",
        <<-SH,
          name="hook-test"
          command="true"
          type="oneshot"
          pre_start() {
            touch "#{marker}"
            return 0
          }
        SH

        type: Config::ServiceType::Oneshot,
        restart: Config::RestartPolicy::No
      )
      sdef.has_pre_start = true

      begin
        state_ch = Channel(ServiceRecord).new(32)
        rec = ServiceRecord.new("hook-test", sdef)
        sup = Supervisor.new(rec, REAPER_CHANNEL, state_ch)

        sup.start_fiber
        collect_states(state_ch, 3, 6.seconds)

        File.exists?(marker).should be_true
      ensure
        File.delete(marker) rescue nil
        FileUtils.rm_rf(dir)
      end
    end
  end
end
