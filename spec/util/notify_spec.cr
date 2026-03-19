# spec/util/notify_spec.cr

require "spec"
require "../../src/util/notify"

module Litin::Util::Notify
  describe ".send" do
    it "returns false when NOTIFY_SOCKET is unset" do
      ENV.delete("NOTIFY_SOCKET")
      Notify.send("READY=1").should be_false
    end

    it "returns false when NOTIFY_SOCKET points to a non-existent socket" do
      ENV["NOTIFY_SOCKET"] = "/tmp/litin-notify-nonexistent-#{Random.rand}.sock"
      result = Notify.send("READY=1")
      result.should be_false
      ENV.delete("NOTIFY_SOCKET")
    end

    it "sends a payload to a listening UNIX socket and it is received" do
      sock_path = "/tmp/litin-notify-test-#{Random.rand(99999)}.sock"
      File.delete(sock_path) rescue nil

      received = Channel(String).new(1)

      # Start a minimal server that accepts one connection and reads a line.
      server = UNIXServer.new(sock_path)
      spawn do
        client = server.accept?
        if client
          line = client.gets.to_s
          received.send(line)
          client.close
        end
        server.close
      end

      sleep 20.milliseconds

      ENV["NOTIFY_SOCKET"] = sock_path
      result = Notify.send("READY=1")
      ENV.delete("NOTIFY_SOCKET")

      result.should be_true

      select
      when msg = received.receive
        msg.should contain("READY=1")
      when timeout(3.seconds)
        raise "timed out waiting for notify message"
      end

      File.delete(sock_path) rescue nil
    end

    it "sends READY=1 via .ready convenience method" do
      sock_path = "/tmp/litin-notify-ready-#{Random.rand(99999)}.sock"
      File.delete(sock_path) rescue nil

      received = Channel(String).new(1)
      server = UNIXServer.new(sock_path)
      spawn do
        client = server.accept?
        received.send(client.try(&.gets).to_s)
        client.try(&.close)
        server.close
      end
      sleep 20.milliseconds

      ENV["NOTIFY_SOCKET"] = sock_path
      Notify.ready
      ENV.delete("NOTIFY_SOCKET")

      select
      when msg = received.receive
        msg.should eq("READY=1")
      when timeout(3.seconds)
        raise "timed out"
      end

      File.delete(sock_path) rescue nil
    end

    it "sends STATUS= message correctly" do
      sock_path = "/tmp/litin-notify-status-#{Random.rand(99999)}.sock"
      File.delete(sock_path) rescue nil

      received = Channel(String).new(1)
      server = UNIXServer.new(sock_path)
      spawn do
        client = server.accept?
        received.send(client.try(&.gets).to_s)
        client.try(&.close)
        server.close
      end
      sleep 20.milliseconds

      ENV["NOTIFY_SOCKET"] = sock_path
      Notify.status("Listening on :8080")
      ENV.delete("NOTIFY_SOCKET")

      select
      when msg = received.receive
        msg.should eq("STATUS=Listening on :8080")
      when timeout(3.seconds)
        raise "timed out"
      end

      File.delete(sock_path) rescue nil
    end
  end

  describe ".watchdog_interval" do
    it "returns nil when WATCHDOG_USEC is not set" do
      ENV.delete("WATCHDOG_USEC")
      Notify.watchdog_interval.should be_nil
    end

    it "converts microseconds to seconds" do
      ENV["WATCHDOG_USEC"] = "30000000" # 30 seconds
      result = Notify.watchdog_interval
      ENV.delete("WATCHDOG_USEC")
      result.should_not be_nil
      result.not_nil!.should be_close(30.0, 0.001)
    end

    it "returns nil for zero" do
      ENV["WATCHDOG_USEC"] = "0"
      Notify.watchdog_interval.should be_nil
      ENV.delete("WATCHDOG_USEC")
    end

    it "returns nil for non-numeric value" do
      ENV["WATCHDOG_USEC"] = "notanumber"
      Notify.watchdog_interval.should be_nil
      ENV.delete("WATCHDOG_USEC")
    end
  end

  describe ".send_multi" do
    it "returns false for an empty message array" do
      ENV.delete("NOTIFY_SOCKET")
      Notify.send_multi([] of String).should be_false
    end

    it "joins messages with newlines" do
      sock_path = "/tmp/litin-notify-multi-#{Random.rand(99999)}.sock"
      File.delete(sock_path) rescue nil

      received = Channel(String).new(1)
      server = UNIXServer.new(sock_path)
      spawn do
        client = server.accept?
        if client
          # Read all data until EOF.
          buf = String::Builder.new
          loop do
            ch = client.read_byte
            break unless ch
            buf << ch.chr
          end
          received.send(buf.to_s)
          client.close
        end
        server.close
      end
      sleep 20.milliseconds

      ENV["NOTIFY_SOCKET"] = sock_path
      Notify.send_multi(["READY=1", "STATUS=initialised"])
      ENV.delete("NOTIFY_SOCKET")

      select
      when msg = received.receive
        msg.should contain("READY=1")
        msg.should contain("STATUS=initialised")
      when timeout(3.seconds)
        raise "timed out"
      end

      File.delete(sock_path) rescue nil
    end
  end
end
