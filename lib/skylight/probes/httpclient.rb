require 'skylight/formatters/http'

module Skylight
  module Probes
    module HTTPClientProbe
      class Probe
        def install
          ::HTTPClient.class_eval do
            # HTTPClient has request methods on the class object itself,
            # but the internally instantiate a client and perform the method
            # on that, so this instance method override will cover both
            # `HTTPClient.get(...)` and `HTTPClient.new.get(...)`

            alias do_request_without_sk do_request
            def do_request(method, uri, query, body, header, &block)
              opts = Formatters::HTTP.build_opts(method, uri.scheme, uri.host, uri.port, uri.path, uri.query)

              Skylight.instrument(opts) do
                do_request_without_sk(method, uri, query, body, header, &block)
              end
            end

            alias do_get_stream_without_sk do_get_stream
            def do_get_stream(req, proxy, conn)
              uri = req.header.request_uri
              method_name = req.header.request_method

              opts = Formatters::HTTP.build_opts(method_name, uri.scheme, uri.host, uri.port, uri.path, uri.query)

              Skylight.instrument(opts) do
                do_get_stream_without_sk(req, proxy, conn)
              end
            end
          end
        end
      end # class Probe
    end # module Probes::HTTPClient

    register("HTTPClient", "httpclient", HTTPClientProbe::Probe.new)
  end
end
