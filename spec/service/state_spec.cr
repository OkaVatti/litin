# spec/service/state_spec.cr

require "spec"
require "../../src/config/service_definition"
require "../../src/service/state"

module Litin::Service
  private def self.make_record(name : String = "test") : ServiceRecord
    sdef = Config::ServiceDefinition.new
    sdef.name = name
    ServiceRecord.new(name, sdef)
  end

  describe ServiceRecord do
    it "starts in inactive state" do
      rec = make_record
      rec.state.should eq(State::Inactive)
    end

    it "records transitions" do
      rec = make_record
      rec.transition_to(State::Starting, "test start")
      rec.transition_to(State::Ready, "ready")
      rec.transitions.size.should eq(2)
      rec.transitions[0].from.should eq(State::Inactive)
      rec.transitions[0].to.should eq(State::Starting)
      rec.transitions[1].from.should eq(State::Starting)
      rec.transitions[1].to.should eq(State::Ready)
    end

    it "sets started_at when transitioning to Ready" do
      rec = make_record
      rec.transition_to(State::Starting)
      rec.started_at.should be_nil
      rec.transition_to(State::Ready)
      rec.started_at.should_not be_nil
    end

    it "sets stopped_at when transitioning to Inactive" do
      rec = make_record
      rec.transition_to(State::Starting)
      rec.transition_to(State::Ready)
      rec.transition_to(State::Stopping)
      rec.transition_to(State::Inactive)
      rec.stopped_at.should_not be_nil
    end

    it "calculates uptime while running" do
      rec = make_record
      rec.transition_to(State::Starting)
      rec.transition_to(State::Ready)
      sleep 10.milliseconds
      uptime = rec.uptime
      uptime.should_not be_nil
      uptime.not_nil!.total_milliseconds.should be >= 10
    end

    it "returns nil uptime when not running" do
      rec = make_record
      rec.uptime.should be_nil
    end

    it "State#running? is true for Ready and Degraded" do
      State::Ready.running?.should be_true
      State::Degraded.running?.should be_true
      State::Starting.running?.should be_true
      State::Inactive.running?.should be_false
      State::Failed.running?.should be_false
    end

    it "State#terminal? is true for terminal states" do
      State::Failed.terminal?.should be_true
      State::Inactive.terminal?.should be_true
      State::Disabled.terminal?.should be_true
      State::Masked.terminal?.should be_true
      State::Ready.terminal?.should be_false
    end

    it "status_line includes name and state" do
      rec = make_record("nginx")
      rec.transition_to(State::Starting)
      rec.transition_to(State::Ready)
      line = rec.status_line
      line.should contain("nginx")
      line.should contain("ready")
    end

    it "to_json_hash contains expected keys" do
      rec = make_record("sshd")
      hash = rec.to_json_hash
      hash.has_key?("name").should be_true
      hash.has_key?("state").should be_true
      hash.has_key?("restart_count").should be_true
      hash["name"].as_s.should eq("sshd")
    end
  end
end
