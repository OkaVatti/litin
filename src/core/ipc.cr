# src/core/ipc.cr
#
# IPC protocol between litinctl and litind.
#
# Transport: UNIX domain socket at /run/litin/litind.sock
# Framing:   newline-delimited JSON. Each message is one JSON object
#            followed by a single '\n'. The client sends a Request and
#            reads back one or more Response messages until it receives
#            a Response with done: true.
#
# This intentionally simple protocol keeps litinctl easy to script
# against (plain JSON on a socket) and avoids a custom binary format.

require "json"

module Litin
  module IPC
    SOCKET_PATH     = "/run/litin/litind.sock"
    CONNECT_TIMEOUT = 5.0 # seconds

    # ---------------------------------------------------------------------------
    # Request
    # ---------------------------------------------------------------------------

    enum Action
      Start
      Stop
      Restart
      Reload
      Status
      Enable
      Disable
      Mask
      Unmask
      List
      ListTargets
      Logs
      Deps
      Graph
      ReloadDaemon
      Shutdown
    end

    struct Request
      include JSON::Serializable

      property action : String
      property args : Array(String)
      property options : Hash(String, String)

      def initialize(@action, @args = [] of String, @options = {} of String => String)
      end
    end

    # ---------------------------------------------------------------------------
    # Response
    # ---------------------------------------------------------------------------

    # A single frame sent back from litind to litinctl.
    # Multiple frames may be sent for streaming output (e.g. logs).
    # The final frame always has done: true.
    struct Response
      include JSON::Serializable

      property ok : Bool         # true = success, false = error
      property done : Bool       # true = last frame for this request
      property payload : String  # human-readable or JSON depending on context
      property data : JSON::Any? # optional structured data

      def initialize(
        @ok : Bool = true,
        @done : Bool = false,
        @payload : String = "",
        @data : JSON::Any? = nil,
      )
      end

      def self.ok(payload : String = "", done : Bool = true, data : JSON::Any? = nil)
        new(ok: true, done: done, payload: payload, data: data)
      end

      def self.err(payload : String, done : Bool = true)
        new(ok: false, done: done, payload: payload)
      end
    end

    # ---------------------------------------------------------------------------
    # Client (used by litinctl)
    # ---------------------------------------------------------------------------

    class Client
      def initialize(@socket_path : String = SOCKET_PATH)
        @socket = UNIXSocket.new(@socket_path)
      end

      def send_request(req : Request) : Nil
        @socket.puts(req.to_json)
        @socket.flush
      end

      # Yields each Response frame until done: true.
      def each_response(& : Response ->) : Nil
        loop do
          line = @socket.gets
          break if line.nil?
          resp = Response.from_json(line)
          yield resp
          break if resp.done
        end
      end

      # Convenience: send a request and collect all response frames.
      def request(action : String, args : Array(String) = [] of String,
                  options : Hash(String, String) = {} of String => String,
                  & : Response ->) : Nil
        send_request(Request.new(action: action, args: args, options: options))
        each_response { |r| yield r }
      end

      def close
        @socket.close
      end
    end

    # ---------------------------------------------------------------------------
    # Server-side connection handler (used by litind)
    # ---------------------------------------------------------------------------

    class Connection
      getter socket : UNIXSocket

      def initialize(@socket)
      end

      def read_request : Request?
        line = @socket.gets
        return nil if line.nil? || line.empty?
        Request.from_json(line)
      rescue JSON::ParseException
        nil
      end

      def send_response(resp : Response) : Nil
        @socket.puts(resp.to_json)
        @socket.flush
      end

      def close
        @socket.close rescue nil
      end
    end
  end
end
