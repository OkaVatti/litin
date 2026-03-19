# spec/core/ipc_spec.cr

require "spec"
require "../../src/core/ipc"

module Litin::IPC
  describe Request do
    it "serialises and deserialises via JSON" do
      req = Request.new(
        action: "start",
        args: ["sshd", "nginx"],
        options: {"json" => "true", "target" => "default"}
      )
      json = req.to_json
      req2 = Request.from_json(json)

      req2.action.should eq("start")
      req2.args.should eq(["sshd", "nginx"])
      req2.options["json"].should eq("true")
      req2.options["target"].should eq("default")
    end

    it "defaults args and options to empty collections" do
      req = Request.new(action: "list")
      req.args.should be_empty
      req.options.should be_empty
    end
  end

  describe Response do
    it ".ok builds a success response with done=true by default" do
      r = Response.ok("all good")
      r.ok.should be_true
      r.done.should be_true
      r.payload.should eq("all good")
    end

    it ".ok with done: false marks a streaming frame" do
      r = Response.ok("partial", done: false)
      r.ok.should be_true
      r.done.should be_false
    end

    it ".err builds a failure response" do
      r = Response.err("something went wrong")
      r.ok.should be_false
      r.done.should be_true
      r.payload.should eq("something went wrong")
    end

    it ".ok can carry structured data" do
      data = JSON::Any.new({"state" => JSON::Any.new("ready")})
      r = Response.ok(data: data)
      r.data.should_not be_nil
      r.data.not_nil!["state"].as_s.should eq("ready")
    end

    it "round-trips through JSON serialisation" do
      original = Response.ok("test payload", done: false)
      json = original.to_json
      restored = Response.from_json(json)

      restored.ok.should eq(original.ok)
      restored.done.should eq(original.done)
      restored.payload.should eq(original.payload)
    end
  end

  describe "Client / Connection over a real UNIX socket" do
    it "sends a request and receives a response" do
      sock_path = "/tmp/litin-ipc-test-#{Random.rand(99999)}.sock"
      File.delete(sock_path) rescue nil

      received_action = nil.as(String?)
      server_done = Channel(Nil).new

      # Mini litind: accept one connection, read one request, send one response.
      spawn do
        server = UNIXServer.new(sock_path)
        client = server.accept
        conn = Connection.new(client)
        req = conn.read_request
        received_action = req.try(&.action)
        conn.send_response(Response.ok("echo: #{req.try(&.action)}"))
        conn.close
        server.close
        server_done.send(nil)
      end

      # Give the server fiber a moment to bind.
      sleep 50.milliseconds

      client = Client.new(sock_path)
      responses = [] of Response
      client.request("ping", ["arg1"], {"opt" => "val"}) do |r|
        responses << r
      end
      client.close

      server_done.receive

      received_action.should eq("ping")
      responses.size.should eq(1)
      responses[0].ok.should be_true
      responses[0].payload.should eq("echo: ping")

      File.delete(sock_path) rescue nil
    end

    it "streams multiple frames before done" do
      sock_path = "/tmp/litin-ipc-stream-#{Random.rand(99999)}.sock"
      File.delete(sock_path) rescue nil

      server_done = Channel(Nil).new

      spawn do
        server = UNIXServer.new(sock_path)
        client = server.accept
        conn = Connection.new(client)
        _req = conn.read_request
        # Send 3 partial frames then a final done frame.
        3.times do |i|
          conn.send_response(Response.new(ok: true, done: false, payload: "line #{i}"))
        end
        conn.send_response(Response.ok("", done: true))
        conn.close
        server.close
        server_done.send(nil)
      end

      sleep 50.milliseconds

      client = Client.new(sock_path)
      collected = [] of String
      client.request("logs", ["svc"], {"follow" => "false"}) do |r|
        collected << r.payload unless r.payload.empty?
      end
      client.close

      server_done.receive

      collected.should eq(["line 0", "line 1", "line 2"])

      File.delete(sock_path) rescue nil
    end
  end
end
