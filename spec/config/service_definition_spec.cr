# spec/config/service_definition_spec.cr

require "spec"
require "../../src/config/service_definition"

module Litin::Config
  # Helper at module level — Crystal does not allow def inside describe blocks.
  private def self.fresh_sdef(name : String = "testsvc") : ServiceDefinition
    s = ServiceDefinition.new
    s.name = name
    s.command = "/usr/bin/test"
    s
  end

  describe ServiceDefinition do
    # -------------------------------------------------------------------------
    # validate
    # -------------------------------------------------------------------------

    describe "#validate" do
      it "returns empty array for a minimal valid definition" do
        fresh_sdef.validate.should be_empty
      end

      it "errors when name is empty" do
        s = ServiceDefinition.new
        s.command = "/bin/true"
        s.validate.should contain("name is empty")
      end

      it "errors when both command and run_script are nil" do
        s = ServiceDefinition.new
        s.name = "nocommand"
        errs = s.validate
        errs.any? { |e| e.includes?("command") }.should be_true
      end

      it "errors when type=forking and pid_file is nil" do
        s = fresh_sdef
        s.type = ServiceType::Forking
        s.validate.any? { |e| e.includes?("pid_file") }.should be_true
      end

      it "passes for forking with pid_file set" do
        s = fresh_sdef
        s.type = ServiceType::Forking
        s.pid_file = "/run/test.pid"
        s.validate.should be_empty
      end

      it "errors when restart_sec is negative" do
        s = fresh_sdef
        s.restart_sec = -1
        s.validate.any? { |e| e.includes?("restart_sec") }.should be_true
      end

      it "errors when timeout_start is zero" do
        s = fresh_sdef
        s.timeout_start = 0
        s.validate.any? { |e| e.includes?("timeout_start") }.should be_true
      end

      it "errors for http healthcheck without url" do
        s = fresh_sdef
        s.healthcheck_type = "http"
        s.healthcheck_http_url = nil
        s.validate.any? { |e| e.includes?("healthcheck_http_url") }.should be_true
      end

      it "errors for tcp healthcheck with port 0" do
        s = fresh_sdef
        s.healthcheck_type = "tcp"
        s.healthcheck_tcp_port = 0
        s.validate.any? { |e| e.includes?("healthcheck_tcp_port") }.should be_true
      end
    end

    describe "#valid?" do
      it "returns true for a valid definition" do
        fresh_sdef.valid?.should be_true
      end

      it "returns false for an invalid definition" do
        s = ServiceDefinition.new
        s.valid?.should be_false
      end
    end

    # -------------------------------------------------------------------------
    # Dependency helpers
    # -------------------------------------------------------------------------

    describe "#requires" do
      it "returns names from Require dependencies only" do
        s = fresh_sdef
        s.dependencies << Dependency.new(Dependency::Kind::Require, ["network", "localfs"])
        s.dependencies << Dependency.new(Dependency::Kind::Want, ["logger"])
        s.dependencies << Dependency.new(Dependency::Kind::After, ["boot"])
        s.requires.sort.should eq(["localfs", "network"])
      end

      it "returns empty when no hard deps" do
        fresh_sdef.requires.should be_empty
      end
    end

    describe "#after_names" do
      it "includes require, want, and after deps" do
        s = fresh_sdef
        s.dependencies << Dependency.new(Dependency::Kind::Require, ["a"])
        s.dependencies << Dependency.new(Dependency::Kind::Want, ["b"])
        s.dependencies << Dependency.new(Dependency::Kind::After, ["c"])
        s.dependencies << Dependency.new(Dependency::Kind::Before, ["d"])
        names = s.after_names.sort
        names.should contain("a")
        names.should contain("b")
        names.should contain("c")
        names.should_not contain("d")
      end
    end

    describe "#before_names" do
      it "returns only Before dep targets" do
        s = fresh_sdef
        s.dependencies << Dependency.new(Dependency::Kind::Before, ["nginx"])
        s.dependencies << Dependency.new(Dependency::Kind::Require, ["boot"])
        s.before_names.should eq(["nginx"])
      end
    end

    describe "#conflicts_with" do
      it "returns names from Conflicts deps" do
        s = fresh_sdef
        s.dependencies << Dependency.new(Dependency::Kind::Conflicts, ["dropbear"])
        s.conflicts_with.should eq(["dropbear"])
      end
    end

    # -------------------------------------------------------------------------
    # CgroupLimits
    # -------------------------------------------------------------------------

    describe CgroupLimits do
      it "any? is false when all fields are nil/false" do
        CgroupLimits.new.any?.should be_false
      end

      it "any? is true when memory_max is set" do
        c = CgroupLimits.new
        c.memory_max = "256M"
        c.any?.should be_true
      end

      it "any? is true when oom_group is true" do
        c = CgroupLimits.new
        c.oom_group = true
        c.any?.should be_true
      end
    end

    # -------------------------------------------------------------------------
    # to_s
    # -------------------------------------------------------------------------

    describe "#to_s" do
      it "includes name, type, and restart policy" do
        s = fresh_sdef("myapp")
        s.type = ServiceType::Forking
        s.restart = RestartPolicy::Always
        str = s.to_s
        str.should contain("myapp")
        str.should contain("forking")
        str.should contain("always")
      end
    end
  end
end
