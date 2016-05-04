# Supports 0.13+
module Skylight
  module Probes
    module Padrino
      class Probe
        def install
          ::Padrino::Routing::InstanceMethods.class_eval do
            private
              alias invoke_route_without_sk invoke_route

              def invoke_route(*args)
                invoke_route_without_sk(*args)
              ensure
                if @route
                  if instrumenter = Skylight::Instrumenter.instance
                    if trace = instrumenter.current_trace
                      # Set the endpoint name to the route name
                      trace.endpoint = "#{@route.verb} #{@route.original_path}"
                    end
                  end
                end
              end
          end
        end
      end
    end

    register("Padrino", "padrino", Padrino::Probe.new)
  end
end
