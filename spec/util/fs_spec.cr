# spec/util/fs_spec.cr

require "spec"
require "file_utils"
require "../../src/util/fs"

module Litin::Util::FS
  describe ".atomic_write" do
    it "writes content to the target path" do
      path = "/tmp/litin-fstest-#{Random.rand(99999)}"
      begin
        FS.atomic_write(path, "hello world\n")
        File.read(path).should eq("hello world\n")
      ensure
        File.delete(path) rescue nil
      end
    end

    it "replaces existing file atomically" do
      path = "/tmp/litin-fstest-replace-#{Random.rand(99999)}"
      begin
        File.write(path, "old content")
        FS.atomic_write(path, "new content")
        File.read(path).should eq("new content")
      ensure
        File.delete(path) rescue nil
      end
    end

    it "creates parent directories if needed" do
      dir = "/tmp/litin-fstest-dir-#{Random.rand(99999)}"
      path = File.join(dir, "nested", "file.txt")
      begin
        FS.atomic_write(path, "deep content")
        File.read(path).should eq("deep content")
      ensure
        FileUtils.rm_rf(dir)
      end
    end
  end

  describe ".read_pid / .write_pid" do
    it "round-trips the current PID" do
      path = "/tmp/litin-pid-#{Random.rand(99999)}"
      begin
        FS.write_pid(path)
        pid = FS.read_pid(path)
        pid.should eq(Process.pid)
      ensure
        File.delete(path) rescue nil
      end
    end

    it "returns nil for a missing PID file" do
      FS.read_pid("/tmp/litin-no-such-pid-file").should be_nil
    end

    it "returns nil for a file with non-numeric content" do
      path = "/tmp/litin-badpid-#{Random.rand(99999)}"
      begin
        File.write(path, "not a number\n")
        FS.read_pid(path).should be_nil
      ensure
        File.delete(path) rescue nil
      end
    end
  end

  describe ".ensure_dir" do
    it "creates a directory with the given mode" do
      path = "/tmp/litin-ensuredir-#{Random.rand(99999)}"
      begin
        FS.ensure_dir(path, 0o755)
        Dir.exists?(path).should be_true
      ensure
        Dir.delete(path) rescue nil
      end
    end

    it "does not raise if the directory already exists" do
      path = "/tmp/litin-existsdir-#{Random.rand(99999)}"
      Dir.mkdir_p(path)
      begin
        FS.ensure_dir(path) # should not raise
        Dir.exists?(path).should be_true
      ensure
        Dir.delete(path) rescue nil
      end
    end
  end

  describe ".remove_stale_socket" do
    it "removes an existing socket file" do
      path = "/tmp/litin-stalesock-#{Random.rand(99999)}.sock"
      begin
        File.write(path, "")
        FS.remove_stale_socket(path)
        File.exists?(path).should be_false
      ensure
        File.delete(path) rescue nil
      end
    end

    it "does nothing if the path does not exist" do
      path = "/tmp/litin-nosuchsocket-#{Random.rand(99999)}.sock"
      FS.remove_stale_socket(path) # should not raise
    end
  end
end
