require "spec"
require "../../src/compat/dinit"

module Litin::Compat::Dinit
  describe "dinitctl option parsing" do
    it "parses --reboot flag" do
      opts = parse_options(["--reboot"])
      opts["reboot"].should eq("true")
    end

    it "parses --poweroff flag" do
      opts = parse_options(["--poweroff"])
      opts["poweroff"].should eq("true")
    end

    it "parses --target=value" do
      opts = parse_options(["--target=default"])
      opts["target"].should eq("default")
    end

    it "returns empty hash for no flags" do
      opts = parse_options(["sshd"])
      opts.should be_empty
    end
  end

  describe "add-dep and rm-dep" do
    it "add-dep returns 1" do
      # Symbolic test: the function always returns 1.
      result = Dinit.dinitctl(["add-dep", "required", "a", "b"])
      result.should eq(1)
    end
  end
end
