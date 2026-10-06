# frozen_string_literal: true

require "socket"
require "zlib"
require "json"

# A tiny in-process HTTP/1.1 server with keep-alive, for transport tests.
# Responses come from a handler block; requests are recorded with their
# decompressed bodies.
class FakeServer
  Request = Struct.new(:http_method, :path, :headers, :body, :raw_body) do
    def json = JSON.parse(body)
  end

  attr_reader :port

  def initialize(&handler)
    @server = TCPServer.new("127.0.0.1", 0)
    @port = @server.addr[1]
    @handler = handler || ->(request) { FakeServer.accept(request) }
    @requests = []
    @connections = 0
    @mutex = Mutex.new
    @thread = Thread.new { accept_loop }
  end

  def self.accept(request)
    events = request.path.end_with?("/batch") ? request.json["events"] : [request.json]
    accepted = events.each_with_index.map { |event, index| { "index" => index, "id" => event["event_id"] } }
    batch = { "accepted" => accepted, "rejected" => [] }
    body = request.path.end_with?("/batch") ? batch : { "id" => events.first["event_id"] }
    [202, {}, JSON.generate(body)]
  end

  def endpoint = "http://127.0.0.1:#{@port}"
  def requests = @mutex.synchronize { @requests.dup }
  def connections = @mutex.synchronize { @connections }

  def handler=(handler)
    @mutex.synchronize { @handler = handler }
  end

  def stop
    @server.close
    @thread.join(1)
  rescue IOError
    nil
  end

  private

  def accept_loop
    loop do
      client = @server.accept
      @mutex.synchronize { @connections += 1 }
      Thread.new(client) { |socket| serve(socket) }
    end
  rescue IOError, SystemCallError
    nil
  end

  def serve(socket)
    while (request = read_request(socket))
      @mutex.synchronize { @requests << request }
      status, headers, body = @mutex.synchronize { @handler }.call(request)
      write_response(socket, status, headers, body)
    end
  rescue IOError, SystemCallError
    nil
  ensure
    socket.close
  end

  def read_request(socket)
    line = socket.gets
    return nil unless line

    http_method, path = line.split
    headers = read_headers(socket)
    raw = socket.read(headers.fetch("content-length", "0").to_i).to_s
    body = headers["content-encoding"] == "gzip" ? Zlib.gunzip(raw) : raw
    Request.new(http_method, path, headers, body, raw)
  end

  def read_headers(socket)
    headers = {}
    while (line = socket.gets) && line != "\r\n"
      name, value = line.split(":", 2)
      headers[name.downcase] = value.strip
    end
    headers
  end

  def write_response(socket, status, headers, body)
    lines = ["HTTP/1.1 #{status} Status", "Content-Type: application/json", "Content-Length: #{body.bytesize}"]
    headers.each { |name, value| lines << "#{name}: #{value}" }
    socket.write("#{lines.join("\r\n")}\r\n\r\n#{body}")
  end
end
