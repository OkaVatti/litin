# spec/config/global_spec.cr

require "spec"
require "../../src/config/global"

module Litin::Config
  describe GlobalConfig do
    def parse_string(content : String) : GlobalConfig
      path = File.tempfile("litin-global-test-", ".conf") do |f|
        f.print(content)
      end.path
      begin
        cfg = GlobalConfig.new
        cfg.read_file(path)
        cfg
      ensure
        File.delete(path) rescue nil
      end
    end

    it "returns defaults when no file exists" do
      cfg = GlobalConfig.load("/tmp/litin-nonexistent-config-#{Random.rand}")
      cfg.services_dir.should eq("/etc/litin/services")
      cfg.log_max_bytes.should eq(10 * 1024 * 1024_i64)
      cfg.shutdown_timeout.should eq(30)
      cfg.cgroup_enabled.should be_true
    end

    it "reads services_dir" do
      cfg = parse_string(%(services_dir="/srv/litin/services"\n))
      cfg.services_dir.should eq("/srv/litin/services")
    end

    it "reads log_max_bytes as integer" do
      cfg = parse_string(%(log_max_bytes="52428800"\n))
      cfg.log_max_bytes.should eq(52_428_800_i64)
    end

    it "reads cgroup_enabled=false" do
      cfg = parse_string(%(cgroup_enabled="false"\n))
      cfg.cgroup_enabled.should be_false
    end

    it "reads multiple keys" do
      cfg = parse_string(<<-CONF)
        services_dir="/etc/myinit/services"
        log_keep="5"
        shutdown_timeout="60"
        default_target="multi-user"
      CONF
      cfg.services_dir.should eq("/etc/myinit/services")
      cfg.log_keep.should eq(5)
      cfg.shutdown_timeout.should eq(60)
      cfg.default_target.should eq("multi-user")
    end

    it "ignores comment lines" do
      cfg = parse_string(<<-CONF)
        # This is a comment
        log_dir="/var/log/myinit"
        # Another comment
      CONF
      cfg.log_dir.should eq("/var/log/myinit")
    end

    it "ignores unknown keys" do
      cfg = parse_string(%(totally_unknown_key="whatever"\n))
      cfg.services_dir.should eq("/etc/litin/services") # unchanged default
    end

    it "reads single-quoted values" do
      cfg = parse_string(%(socket_path='/run/myinit/litind.sock'\n))
      cfg.socket_path.should eq("/run/myinit/litind.sock")
    end
  end
end
