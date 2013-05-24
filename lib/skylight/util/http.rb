require 'json'
require 'net/http'

module Skylight
  module Util
    class HTTP
      CONTENT_ENCODING = 'content-encoding'.freeze
      CONTENT_LENGTH   = 'content-length'.freeze
      CONTENT_TYPE     = 'content-type'.freeze
      ACCEPT           = 'Accept'.freeze
      APPLICATION_JSON = 'application/json'.freeze
      AUTHORIZATION    = 'authorization'.freeze
      DEFLATE          = 'deflate'.freeze
      GZIP             = 'gzip'.freeze

      include Logging

      attr_accessor :authentication, :config

      def initialize(config, service = :report)
        @config = config
        @ssl  = config["#{service}.ssl"]
        @host = config["#{service}.host"]
        @port = config["#{service}.port"]
        @deflate = config["#{service}.deflate"]
        @authentication = config[:'authentication']
      end

      def get(endpoint, hdrs = {})
        request = build_request(Net::HTTP::Get, endpoint, hdrs)
        execute(request)
      rescue Exception => e
        error "http GET failed; msg=%s", e.message
        t { e.backtrace.join("\n") }
        nil
      end

      def post(endpoint, body, hdrs = {})
        unless body.respond_to?(:to_str)
          hdrs[CONTENT_TYPE] = APPLICATION_JSON
          body = body.to_json
        end

        request = build_request(Net::HTTP::Post, endpoint, hdrs, body.bytesize)
        execute(request, body)
      rescue Exception => e
        error "http POST failed; msg=%s", e.message
        t { e.backtrace.join("\n") }
        nil
      end

    private

      def build_request(type, endpoint, hdrs, length=nil)
        headers = {}

        headers[CONTENT_LENGTH]   = length.to_s if length
        headers[AUTHORIZATION]    = authentication if authentication
        headers[ACCEPT]           = APPLICATION_JSON
        headers[CONTENT_ENCODING] = GZIP if @deflate

        hdrs.each do |k, v|
          headers[k] = v
        end

        type.new(endpoint, headers)
      end

      def execute(req, body=nil)
        t { fmt "executing HTTP request; host=%s; port=%s; body=%s",
              @host, @port, body && body.bytesize }

        if body
          body = Gzip.compress(body) if @deflate
          req.body = body
        end

        http = Net::HTTP.new @host, @port

        if @ssl
          http.use_ssl = true
          http.verify_mode = OpenSSL::SSL::VERIFY_PEER
        end

        http.start do |client|
          res = client.request(req)

          unless res.code =~ /2\d\d/
            debug "server responded with #{res.code}"
            t { fmt "body=%s", res.body }
          end

          Response.new(res.code.to_i, res, res.body)
        end
      end

      class Response
        attr_reader :status, :headers, :body

        def initialize(status, headers, body)
          @status  = status
          @headers = headers

          if headers[CONTENT_TYPE] == APPLICATION_JSON
            @body = JSON.parse(body)
          else
            @body = body
          end
        end

        def success?
          status >= 200 && status < 300
        end

        def to_s
          body.to_s
        end

        def get(key)
          return nil unless Hash === body

          res = body
          key.split('.').each do |part|
            return unless res = res[part]
          end
          res
        end

        def respond_to_missing?(name, include_all=false)
          super || body.respond_to?(name, include_all)
        end

        def method_missing(name, *args, &blk)
          if respond_to_missing?(name)
            body.send(name, *args, &blk)
          else
            super
          end
        end
      end

    end
  end
end