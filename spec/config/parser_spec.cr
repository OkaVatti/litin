# spec/config/parser_spec.cr

require "spec"
require "../../src/config/parser"

module Litin::Config
  # Helper at module level — Crystal does not allow def inside describe blocks.
  private def self.parse_string(content : String) : ServiceDefinition
    path = File.tempfile("litin-test-", ".sh") do |f|
      f.print(content)
    end.path

    begin
      Parser.parse_file(path)
    ensure
      File.delete(path) rescue nil
    end
  end

  describe Parser do
    it "parses name and description" do
      sdef = parse_string(<<-SH)
        name="myservice"
        description="My test service"
        command="/usr/bin/myservice -D"
      SH
      sdef.name.should eq("myservice")
      sdef.description.should eq("My test service")
    end

    it "parses command" do
      sdef = parse_string(%(command="/usr/sbin/sshd -D -e"\n))
      sdef.command.should eq("/usr/sbin/sshd -D -e")
    end

    it "parses service type" do
      sdef = parse_string(%(type="forking"\n))
      sdef.type.should eq(ServiceType::Forking)
    end

    it "defaults type to simple" do
      sdef = parse_string(%(name="x"\n))
      sdef.type.should eq(ServiceType::Simple)
    end

    it "parses restart policy" do
      sdef = parse_string(%(restart="always"\n))
      sdef.restart.should eq(RestartPolicy::Always)
    end

    it "parses restart_sec" do
      sdef = parse_string(%(restart_sec="3"\n))
      sdef.restart_sec.should eq(3)
    end

    it "parses user and group" do
      sdef = parse_string(%(user="nobody"\ngroup="nogroup"\n))
      sdef.user.should eq("nobody")
      sdef.group.should eq("nogroup")
    end

    it "parses cgroup limits" do
      sdef = parse_string(<<-SH)
        cgroup_memory_max="256M"
        cgroup_pids_max="64"
        cgroup_cpu_max="50000 100000"
      SH
      sdef.cgroup.memory_max.should eq("256M")
      sdef.cgroup.pids_max.should eq("64")
      sdef.cgroup.cpu_max.should eq("50000 100000")
    end

    it "parses depend() block with require" do
      sdef = parse_string(<<-SH)
        name="sshd"
        depend() {
          require network
          want logger
          after firewall
        }
      SH
      req = sdef.dependencies.select { |d| d.kind == Dependency::Kind::Require }
      req.flat_map(&.targets).should contain("network")

      want = sdef.dependencies.select { |d| d.kind == Dependency::Kind::Want }
      want.flat_map(&.targets).should contain("logger")

      after = sdef.dependencies.select { |d| d.kind == Dependency::Kind::After }
      after.flat_map(&.targets).should contain("firewall")
    end

    it "parses multiple targets in one require line" do
      sdef = parse_string(<<-SH)
        depend() {
          require network localfs
        }
      SH
      req = sdef.dependencies.select { |d| d.kind == Dependency::Kind::Require }
      names = req.flat_map(&.targets)
      names.should contain("network")
      names.should contain("localfs")
    end

    it "parses conflicts dependency" do
      sdef = parse_string(<<-SH)
        depend() {
          conflicts dropbear
        }
      SH
      conf = sdef.dependencies.select { |d| d.kind == Dependency::Kind::Conflicts }
      conf.flat_map(&.targets).should contain("dropbear")
    end

    it "detects hook function flags" do
      sdef = parse_string(<<-SH)
        pre_start() {
          mkdir -p /run/myservice
        }
        post_stop() {
          rm -f /run/myservice.pid
        }
        reload() {
          kill -HUP "$MAINPID"
        }
      SH
      sdef.has_pre_start.should be_true
      sdef.has_post_stop.should be_true
      sdef.has_reload.should be_true
      sdef.has_pre_stop.should be_false
    end

    it "does not detect absent hooks" do
      sdef = parse_string(%(name="x"\n))
      sdef.has_pre_start.should be_false
      sdef.has_healthcheck.should be_false
    end

    it "ignores unknown keys silently and infers name from directory" do
      sdef = parse_string(%(my_custom_var="foo"\n))
      # Parser infers name from parent directory when name is not set explicitly.
      sdef.name.should_not be_empty
    end

    it "parses target field" do
      sdef = parse_string(%(target="boot"\n))
      sdef.target.should eq("boot")
    end

    it "handles single-quoted values" do
      sdef = parse_string(%(name='quoted'\n))
      sdef.name.should eq("quoted")
    end
  end

  describe Parser, ".parse_array_value" do
    it "parses a parenthesised list" do
      result = Parser.parse_array_value(%((  "FOO=bar" "BAZ=qux"  )))
      result.should eq(["FOO=bar", "BAZ=qux"])
    end

    it "handles a plain scalar value" do
      result = Parser.parse_array_value("FOO=bar")
      result.should eq(["FOO=bar"])
    end

    it "handles an empty list" do
      result = Parser.parse_array_value("()")
      result.should be_empty
    end
  end
end
