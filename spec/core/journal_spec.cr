# spec/core/journal_spec.cr

require "spec"
require "../../src/core/journal"

module Litin::Core
  describe Journal do
    def fresh : Journal
      Journal.new(capacity: 16, persist: false)
    end

    it "records events and reports size" do
      j = fresh
      j.size.should eq(0)
      j.info("hello")
      j.size.should eq(1)
    end

    it "evicts oldest events when capacity is exceeded" do
      j = Journal.new(capacity: 4, persist: false)
      8.times { |i| j.info("event #{i}") }
      j.size.should eq(4)

      events = j.query(limit: 10)
      events.map(&.msg).should eq(["event 4", "event 5", "event 6", "event 7"])
    end

    it "records state_change events with from/to fields" do
      j = fresh
      j.state_change("nginx", "inactive", "starting", "pid=1234", 1234)

      events = j.query(limit: 1)
      events.size.should eq(1)
      e = events[0]
      e.kind.should eq("state_change")
      e.service.should eq("nginx")
      e.from.should eq("inactive")
      e.to.should eq("starting")
      e.pid.should eq(1234)
    end

    it "records healthcheck events with ok flag" do
      j = fresh
      j.healthcheck("sshd", ok: true)
      j.healthcheck("sshd", ok: false, fails: 2)

      events = j.query(limit: 10)
      events[0].ok.should be_true
      events[1].ok.should be_false
      events[1].msg.should contain("2")
    end

    it "filters by service name" do
      j = fresh
      j.info("system event")
      j.state_change("nginx", "inactive", "starting")
      j.state_change("sshd", "inactive", "starting")

      nginx_events = j.query(service: "nginx")
      nginx_events.all? { |e| e.service == "nginx" }.should be_true
      nginx_events.size.should eq(1)
    end

    it "filters by kind" do
      j = fresh
      j.info("general")
      j.state_change("nginx", "starting", "ready")
      j.healthcheck("nginx", ok: true)

      sc_events = j.query(kind: "state_change")
      sc_events.all? { |e| e.kind == "state_change" }.should be_true
    end

    it "filters by since time" do
      j = fresh
      # Record an event and capture a timestamp between old and new.
      j.info("old event")
      boundary = Time.utc
      sleep 5.milliseconds
      j.info("new event")

      recent = j.query(since: boundary)
      recent.all? { |e| e.msg == "new event" }.should be_true
    end

    it "respects the limit parameter" do
      j = Journal.new(capacity: 100, persist: false)
      20.times { |i| j.info("evt #{i}") }

      result = j.query(limit: 5)
      result.size.should eq(5)
      result.last.msg.should eq("evt 19")
    end

    it "serialises events to JSON and back" do
      j = fresh
      j.state_change("nginx", "inactive", "ready", "pid=99", 99)
      events = j.query(limit: 1)
      json = events[0].to_json
      parsed = JournalEvent.from_json(json)
      parsed.service.should eq("nginx")
      parsed.kind.should eq("state_change")
      parsed.pid.should eq(99)
    end

    it "each_json yields one JSON string per event" do
      j = fresh
      j.info("a")
      j.info("b")
      lines = [] of String
      j.each_json { |l| lines << l }
      lines.size.should eq(2)
      lines.each { |l| JSON.parse(l).should be_truthy }
    end
  end
end
