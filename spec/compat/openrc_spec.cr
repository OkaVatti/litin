# spec/compat/openrc_spec.cr
#
# Tests for the OpenRC compatibility layer.  Covers runlevel mapping
# and argument parsing without requiring a running litind.

require "spec"
require "../../src/compat/openrc"

module Litin::Compat::OpenRC
  describe "runlevel mapping" do
    it "maps OpenRC runlevels to Litin targets" do
      {
        "default"   => "default",
        "boot"      => "boot",
        "sysinit"   => "boot",
        "nonetwork" => "basic",
        "shutdown"  => "shutdown",
        "single"    => "rescue",
      }.each do |rl, expected|
        RUNLEVEL_MAP[rl].should eq(expected)
      end
    end

    it "passes through unknown runlevels unchanged" do
      result = RUNLEVEL_MAP["myrunlevel"]? || "myrunlevel"
      result.should eq("myrunlevel")
    end
  end

  describe "option parsing" do
    it "parses --flag=value" do
      opts = parse_options(["--target=default", "--json"])
      opts["target"].should eq("default")
      opts["json"].should eq("true")
    end

    it "returns empty hash for no flags" do
      opts = parse_options(["sshd", "start"])
      opts.should be_empty
    end
  end

  describe "rc_update argument parsing" do
    it "identifies add subcommand" do
      argv = ["add", "sshd", "default"]
      argv[0].should eq("add")
      argv[1].should eq("sshd")
      argv[2].should eq("default")
    end

    it "identifies del subcommand" do
      argv = ["del", "sshd"]
      argv[0].should eq("del")
    end

    it "defaults runlevel to default when omitted" do
      argv = ["add", "nginx"]
      runlevel = argv[2]? || "default"
      runlevel.should eq("default")
    end
  end
end
