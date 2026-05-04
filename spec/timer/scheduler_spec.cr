require "spec"
require "../../src/timer/scheduler"

module Timer
  describe Util do
    describe ".parse_duration" do
      it "parses seconds" do
        d = Util.parse_duration("30s")
        d.should be_a(Time::Span)
        d.not_nil!.total_seconds.to_i.should eq(30)
      end

      it "parses minutes" do
        d = Util.parse_duration("5m")
        d.not_nil!.total_seconds.to_i.should eq(300)
      end

      it "parses hours" do
        d = Util.parse_duration("2h")
        d.not_nil!.total_seconds.to_i.should eq(7200)
      end

      it "parses days" do
        d = Util.parse_duration("1d")
        d.not_nil!.total_seconds.to_i.should eq(86400)
      end

      it "returns nil for garbage" do
        Util.parse_duration("notatime").should be_nil
      end

      it "returns nil for plain number (no unit)" do
        Util.parse_duration("30").should be_nil
      end
    end
  end

  describe TimerParser do
    describe ".parse" do
      it "parses a valid timer file with OnBootSec and OnUnitActiveSec" do
        content = <<-TIMER
        [Timer]
        Service=test-service
        OnBootSec=10s
        OnUnitActiveSec=1h
        TIMER

        path = File.tempfile("litin-timer-test-", ".timer") do |f|
          f.print(content)
          f.flush
        end.path

        begin
          unit = TimerParser.parse(path)
          unit.should_not be_nil
          u = unit.not_nil!
          u.service_name.should eq("test-service")
          u.on_boot_sec.should_not be_nil
          u.on_boot_sec.not_nil!.total_seconds.to_i.should eq(10)
          u.on_unit_active_sec.should_not be_nil
          u.on_unit_active_sec.not_nil!.total_seconds.to_i.should eq(3600)
        ensure
          File.delete(path) rescue nil
        end
      end

      it "parses a timer with only OnUnitActiveSec" do
        content = <<-TIMER
        [Timer]
        Service=periodic-svc
        OnUnitActiveSec=5m
        TIMER

        path = File.tempfile("litin-timer-test-", ".timer") do |f|
          f.print(content)
          f.flush
        end.path

        begin
          unit = TimerParser.parse(path)
          unit.should_not be_nil
          u = unit.not_nil!
          u.service_name.should eq("periodic-svc")
          u.on_boot_sec.should be_nil
          u.on_unit_active_sec.not_nil!.total_seconds.to_i.should eq(300)
        ensure
          File.delete(path) rescue nil
        end
      end

      it "returns nil for a file with no timer schedules" do
        content = <<-TIMER
        [Timer]
        Service=orphan
        TIMER

        path = File.tempfile("litin-timer-test-", ".timer") do |f|
          f.print(content)
          f.flush
        end.path

        begin
          unit = TimerParser.parse(path)
          unit.should be_nil
        ensure
          File.delete(path) rescue nil
        end
      end

      it "returns nil for a completely empty file" do
        path = File.tempfile("litin-timer-test-", ".timer") do |f|
          f.print("")
          f.flush
        end.path

        begin
          unit = TimerParser.parse(path)
          unit.should be_nil
        ensure
          File.delete(path) rescue nil
        end
      end
    end
  end
end
