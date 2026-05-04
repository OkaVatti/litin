# spec/log/capture_spec.cr

require "spec"
require "file_utils"
require "../../src/log/capture"

module Litin::Log
  private def self.temp_manager : {LogManager, String}
    dir = File.tempname("litin-log-test")
    Dir.mkdir(dir)
    {LogManager.new(dir), dir}
  end

  describe LogManager do
    it "creates log file on first write" do
      mgr, dir = temp_manager
      begin
        writer = mgr.open_writer("testservice")
        writer.write("hello\n".to_slice)
        writer.close

        log_path = File.join(dir, "testservice.log")
        File.exists?(log_path).should be_true
      ensure
        FileUtils.rm_rf(dir)
      end
    end

    it "tail returns last N lines" do
      mgr, dir = temp_manager
      begin
        log_path = File.join(dir, "tail-test.log")
        lines = (1..20).map { |i| "2025-01-01T00:00:#{i.to_s.rjust(2, '0')}Z  line #{i}" }
        File.write(log_path, lines.join("\n") + "\n")

        result = mgr.tail("tail-test", 5)
        result.size.should eq(5)
        result.last.should contain("line 20")
      ensure
        FileUtils.rm_rf(dir)
      end
    end

    it "tail returns all lines when fewer than N exist" do
      mgr, dir = temp_manager
      begin
        log_path = File.join(dir, "short.log")
        File.write(log_path, "line1\nline2\nline3\n")

        result = mgr.tail("short", 50)
        result.size.should eq(3)
      ensure
        FileUtils.rm_rf(dir)
      end
    end

    it "tail returns empty array for missing service" do
      mgr, dir = temp_manager
      begin
        result = mgr.tail("nonexistent", 10)
        result.should be_empty
      ensure
        FileUtils.rm_rf(dir)
      end
    end

    it "tail with n=0 returns all lines" do
      mgr, dir = temp_manager
      begin
        log_path = File.join(dir, "all.log")
        File.write(log_path, (1..30).map { |i| "line #{i}" }.join("\n") + "\n")

        result = mgr.tail("all", 0)
        result.size.should eq(30)
      ensure
        FileUtils.rm_rf(dir)
      end
    end

    it "rotate renames current log to .1" do
      mgr, dir = temp_manager
      begin
        log_path = File.join(dir, "rotate.log")
        File.write(log_path, "original content\n")

        mgr.rotate(log_path)

        File.exists?(log_path).should be_false
        File.exists?("#{log_path}.1").should be_true
        File.read("#{log_path}.1").should contain("original content")
      ensure
        FileUtils.rm_rf(dir)
      end
    end

    it "rotate shifts existing generations" do
      mgr, dir = temp_manager
      begin
        log_path = File.join(dir, "shift.log")
        File.write("#{log_path}.1", "gen1\n")
        File.write("#{log_path}.2", "gen2\n")
        File.write(log_path, "current\n")

        mgr.rotate(log_path)

        File.read("#{log_path}.1").should contain("current")
        File.read("#{log_path}.2").should contain("gen1")
        File.read("#{log_path}.3").should contain("gen2")
      ensure
        FileUtils.rm_rf(dir)
      end
    end
  end

  describe TimestampedWriter do
    it "prepends ISO8601 timestamps to log lines" do
      dir = File.tempname("litin-tsw-test")
      Dir.mkdir(dir)
      log_path = File.join(dir, "ts.log")

      begin
        writer = TimestampedWriter.new(log_path)
        writer.write("hello world\n".to_slice)
        writer.close

        content = File.read(log_path)
        content.should match(/^\d{4}-\d{2}-\d{2}T/)
        content.should contain("hello world")
      ensure
        FileUtils.rm_rf(dir)
      end
    end

    it "handles multi-line writes by timestamping each line" do
      dir = File.tempname("litin-tsw-multi")
      Dir.mkdir(dir)
      log_path = File.join(dir, "multi.log")

      begin
        writer = TimestampedWriter.new(log_path)
        writer.write("line one\nline two\nline three\n".to_slice)
        writer.close

        lines = File.read_lines(log_path).reject(&.empty?)
        lines.size.should eq(3)
        lines.each { |l| l.should match(/^\d{4}-\d{2}-\d{2}T/) }
      ensure
        FileUtils.rm_rf(dir)
      end
    end
  end
end
