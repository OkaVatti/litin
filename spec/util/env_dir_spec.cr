# spec/util/env_dir_spec.cr

require "spec"
require "../../src/util/env_dir"

module Litin::Util::EnvDir
  describe ".read" do
    it "returns empty hash for non-existent directory" do
      result = EnvDir.read("/tmp/litin-test-nonexistent-#{Random.rand(99999)}")
      result.should be_empty
    end

    it "reads key-value pairs from a directory" do
      dir = File.tempname("litin-envdir-test")
      Dir.mkdir(dir)

      begin
        File.write(File.join(dir, "PORT"), "8080\n")
        File.write(File.join(dir, "LOG_LEVEL"), "info")
        File.write(File.join(dir, "DATABASE_URL"), "postgres://localhost/mydb\nextra line")

        result = EnvDir.read(dir)

        result["PORT"].should eq("8080")
        result["LOG_LEVEL"].should eq("info")
        # Only the first line is used.
        result["DATABASE_URL"].should eq("postgres://localhost/mydb")
      ensure
        FileUtils.rm_rf(dir)
      end
    end

    it "ignores hidden files (starting with '.')" do
      dir = File.tempname("litin-envdir-hidden")
      Dir.mkdir(dir)

      begin
        File.write(File.join(dir, ".ignored"), "secret")
        File.write(File.join(dir, "VISIBLE"), "yes")

        result = EnvDir.read(dir)
        result.has_key?(".ignored").should be_false
        result["VISIBLE"].should eq("yes")
      ensure
        FileUtils.rm_rf(dir)
      end
    end

    it "ignores subdirectories" do
      dir = File.tempname("litin-envdir-subdir")
      Dir.mkdir(dir)

      begin
        Dir.mkdir(File.join(dir, "subdir"))
        File.write(File.join(dir, "KEY"), "value")

        result = EnvDir.read(dir)
        result.has_key?("subdir").should be_false
        result["KEY"].should eq("value")
      ensure
        FileUtils.rm_rf(dir)
      end
    end

    it "strips trailing newlines and whitespace from values" do
      dir = File.tempname("litin-envdir-strip")
      Dir.mkdir(dir)

      begin
        File.write(File.join(dir, "TRIMMED"), "  hello world  \n")
        result = EnvDir.read(dir)
        result["TRIMMED"].should eq("  hello world")
      ensure
        FileUtils.rm_rf(dir)
      end
    end
  end

  describe ".merge_into" do
    it "overlays env dir values over base" do
      dir = File.tempname("litin-envdir-merge")
      Dir.mkdir(dir)

      begin
        File.write(File.join(dir, "OVERRIDE"), "new_value")
        File.write(File.join(dir, "EXTRA"), "added")

        base = {"OVERRIDE" => "old_value", "KEEP" => "unchanged"}
        result = EnvDir.merge_into(base, dir)

        result["OVERRIDE"].should eq("new_value")
        result["KEEP"].should eq("unchanged")
        result["EXTRA"].should eq("added")
      ensure
        FileUtils.rm_rf(dir)
      end
    end
  end
end
