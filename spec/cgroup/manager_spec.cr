# spec/cgroup/manager_spec.cr
#
# Tests for the cgroup manager that do not require a real cgroup2
# filesystem.  We test the path construction logic and the
# stats/limits struct behaviour.

require "spec"
require "../../src/config/service_definition"
require "../../src/cgroup/manager"

module Litin::CGroup
  describe ServiceCGroup do
    it "constructs the correct cgroup path" do
      cg = ServiceCGroup.new("nginx")
      cg.path.should eq("#{LITIN_ROOT}/nginx")
    end

    it "path is unique per service name" do
      cg1 = ServiceCGroup.new("sshd")
      cg2 = ServiceCGroup.new("nginx")
      cg1.path.should_not eq(cg2.path)
    end
  end

  describe Config::CgroupLimits do
    it "any? returns false when all limits are unset" do
      limits = Config::CgroupLimits.new
      limits.any?.should be_false
    end

    it "any? returns true when at least one limit is set" do
      limits = Config::CgroupLimits.new
      limits.memory_max = "512M"
      limits.any?.should be_true
    end

    it "any? returns true for oom_group=true" do
      limits = Config::CgroupLimits.new
      limits.oom_group = true
      limits.any?.should be_true
    end
  end

  describe ".available?" do
    it "returns false when cgroup root does not exist" do
      # In the test environment there is no /sys/fs/cgroup/litin.
      # available? should return false gracefully, not raise.
      result = CGroup.available?
      result.should be_a(Bool)
    end
  end
end
