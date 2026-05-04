# spec/socket/activation_spec.cr

require "spec"
require "../../src/socket/activation"

module Litin::Socket
  # Helper to parse a string as a socket unit file (for testing)
  def self.parse_string(content : String) : SocketUnit
    path = File.tempfile("litin-sock-test-", ".socket") do |f|
      f.print(content)
      f.flush
    end.path
    begin
      SocketParser.parse_file(path)
    ensure
      File.delete(path) rescue nil
    end
  end

  describe SocketParser do
    it "parses a TCP socket unit" do
      unit = parse_string(<<-SH)
        listen="0.0.0.0:22"
        service="sshd"
        backlog="256"
        accept="no"
      SH
      unit.listen.should eq("0.0.0.0:22")
      unit.service.should eq("sshd")
      unit.backlog.should eq(256)
      unit.accept.should be_false
      unit.unix?.should be_false
      unit.tcp_port.should eq(22)
      unit.tcp_address.should eq("0.0.0.0")
    end

    it "parses a UNIX domain socket unit" do
      unit = parse_string(<<-SH)
        listen="unix:/run/myservice.sock"
        service="myservice"
        socket_mode="0660"
      SH
      unit.unix?.should be_true
      unit.unix_path.should eq("/run/myservice.sock")
      unit.socket_mode.should eq(0o660)
    end

    it "parses accept=yes" do
      unit = parse_string(%(listen="0.0.0.0:80"\nservice="nginx"\naccept="yes"\n))
      unit.accept.should be_true
    end

    it "raises if listen is missing" do
      expect_raises(Exception, /missing 'listen'/) do
        parse_string(%(service="sshd"\n))
      end
    end

    it "raises if service is missing" do
      expect_raises(Exception, /missing 'service'/) do
        parse_string(%(listen="0.0.0.0:22"\n))
      end
    end

    it "defaults backlog to 128" do
      unit = parse_string(%(listen="0.0.0.0:80"\nservice="nginx"\n))
      unit.backlog.should eq(128)
    end
  end

  describe ".build_listen_env" do
    it "produces correct LISTEN_* environment variables" do
      pid = 12345
      env = {
        "LISTEN_PID"     => pid.to_s,
        "LISTEN_FDS"     => "2",
        "LISTEN_FDNAMES" => "sshd.socket:sshd-ipv6.socket",
      }
      env["LISTEN_PID"].should eq("12345")
      env["LISTEN_FDS"].should eq("2")
      env["LISTEN_FDNAMES"].should eq("sshd.socket:sshd-ipv6.socket")
    end
  end
end
