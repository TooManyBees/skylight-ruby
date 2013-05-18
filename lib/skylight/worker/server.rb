require 'socket'

module Skylight
  module Worker
    # TODO:
    #   - Shutdown if no connections for over a minute
    class Server
      STANDALONE_ENV_KEY = 'SK_STANDALONE'.freeze
      STANDALONE_ENV_VAL = 'server'.freeze
      LOCKFILE_PATH      = 'SK_LOCKFILE_PATH'.freeze
      LOCKFILE_ENV_KEY   = 'SK_LOCKFILE_FD'.freeze
      SOCKFILE_PATH_KEY  = 'SK_SOCKFILE_PATH'.freeze
      UDS_SRV_FD_KEY     = 'SK_UDS_FD'.freeze
      KEEPALIVE_KEY      = 'SK_KEEPALIVE'.freeze

      include Util::Logging

      attr_reader \
        :pid,
        :tick,
        :keepalive,
        :lockfile_path,
        :sockfile_path

      def initialize(lockfile, srv, lockfile_path, sockfile_path, keepalive)

        unless lockfile && srv
          raise ArgumentError, "lockfile and unix domain server socket are required"
        end

        @pid              = Process.pid
        @run              = true
        @tick             = 1
        @socks            = []
        @server           = srv
        @lockfile         = lockfile
        @collector        = Collector.new
        @keepalive        = keepalive
        @connections      = {}
        @lockfile_path    = lockfile_path
        @sockfile_path    = sockfile_path
      end

      # Called from skylight.rb on require
      def self.boot
        if ENV[STANDALONE_ENV_KEY] == STANDALONE_ENV_VAL
          def fail(msg, code = 1)
            STDERR.ptus msg
            exit code
          end

          unless fd = ENV[LOCKFILE_ENV_KEY]
            fail "missing lockfile FD"
          end

          unless fd =~ /^\d+$/
            fail "invalid lockfile FD"
          end

          begin
            lockfile = IO.open(fd.to_i)
          rescue Exception => e
            fail "invalid lockfile FD: #{e.message}"
          end

          unless sockfile_path = ENV[SOCKFILE_PATH_KEY]
            fail "missing sockfile path"
          end

          unless lockfile_path = ENV[LOCKFILE_PATH]
            fail "missing lockfile path"
          end

          unless keepalive = ENV[KEEPALIVE_KEY]
            fail "missing keepalive"
          end

          unless keepalive =~ /^\d+$/
            fail "invalid keepalive"
          end

          srv = nil
          if fd = ENV[UDS_SRV_FD_KEY]
            srv = UNIXServer.for_fd(fd.to_i)
          end

          server = new(
            lockfile,
            srv,
            lockfile_path,
            sockfile_path,
            keepalive.to_i)

          server.run
        end
      end

      def self.exec(cmd, lockfile, srv, lockfile_path, sockfile_path, keepalive)
        env = {
          STANDALONE_ENV_KEY => STANDALONE_ENV_VAL,
          LOCKFILE_PATH      => lockfile_path,
          LOCKFILE_ENV_KEY   => lockfile.fileno.to_s,
          SOCKFILE_PATH_KEY  => sockfile_path,
          KEEPALIVE_KEY      => keepalive.to_s }

        if srv
          env[UDS_SRV_FD_KEY] = srv.fileno.to_s
        end

        opts = {}
        args = [env] + cmd + [opts]

        unless RUBY_VERSION < '1.9'
          [lockfile, srv].each do |io|
            next unless io
            fd = io.fileno.to_i
            opts[fd] = fd
          end
        end

        Kernel.exec(*args)
      end

      def run
        init
        work
      ensure
        cleanup
      end

    private

      def init
        trap('TERM') { @run = false }
        trap('INT')  { @run = false }

        info "starting skylight daemon"
        @collector.spawn
      end

      def work
        @socks << @server

        now = Time.now.to_i
        next_sanity_check_at = now + tick
        had_client_at = now

        trace "starting IO loop"
        begin
          # Wait for something to do
          r, _, _ = IO.select(@socks, [], [], tick)

          if r
            r.each do |sock|
              if sock == @server
                # If the server socket, accept
                # the incoming connection
                if client = accept
                  connect(client)
                end
              else
                # Client socket, lookup the associated connection
                # state machine.
                unless conn = @connections[sock]
                  # No associated connection, weird.. bail
                  client_close(sock)
                  next
                end

                begin
                  # Pop em while we got em
                  while msg = conn.read
                    handle(msg)
                  end
                rescue SystemCallError, EOFError
                  client_close(sock)
                rescue IpcProtoError => e
                  error "Server#work - IPC protocol exception: %s", e.message
                  client_close(sock)
                end
              end
            end
          end

          now = Time.now.to_i

          if @socks.length > 1
            had_client_at = now
          end

          if keepalive < now - had_client_at
            info "no clients for #{keepalive} sec - shutting down"
            @run = false
          elsif next_sanity_check_at <= now
            next_sanity_check_at = now + tick
            sanity_check
          end

        rescue SignalException => e
          error "Did not handle: #{e.class}"
          @run = false
        rescue WorkerStateError => e
          info "#{e.message} - shutting down"
          @run = false
        rescue Exception => e
          error "Loop exception: %s (%s)", e.message, e.class
          puts e.backtrace
          return false
        rescue Object => o
          error "Unknown object thrown: `%s`", o.to_s
          return false
        end while @run

        true # Successful return
      end

      # Handles an incoming message. Will be instances from
      # the Messages namespace
      def handle(msg)
        case msg
        when nil
          return
        when Messages::Hello
          if msg.newer?
            info "newer version of agent deployed - restarting; curr=%s; new=%s", VERSION, msg.version
            reload(msg)
          end
        when Messages::Trace
          @collector.submit(msg)
        when :unknown
          debug "received unknown message"
        else
          debug "recieved: %s", msg
        end
      end

      def reload(hello)
        # Close all client connections
        trace "closing all client connections"
        clients_close

        # Re-exec the process
        trace "re-exec"
        Server.exec(hello.cmd, @lockfile, @server, lockfile_path, sockfile_path, keepalive)
      end

      def accept
        @server.accept_nonblock
      rescue Errno::EWOULDBLOCK, Errno::EAGAIN, Errno::ECONNABORTED
      end

      def connect(sock)
        trace "client accepted"
        @socks << sock
        @connections[sock] = Connection.new(sock)
      end

      def cleanup
        # The lockfile is not deleted. There is no way to atomically ensure
        # that we are deleting the lockfile for the current process.
        cleanup_curr_sockfile
        close
        @lockfile.close
      end

      def close
        @server.close if @server
        clients_close
      end

      def clients_close
        @connections.keys.each do |sock|
          client_close(sock)
        end
      end

      def client_close(sock)
        trace "closing client connection; fd=%d", sock.fileno
        @connections.delete(sock)
        @socks.delete(sock)
        sock.close rescue nil
      end

      def sockfile
        "#{sockfile_path}/skylight-#{pid}.sock"
      end

      def sockfile?
        File.exist?(sockfile)
      end

      def cleanup_curr_sockfile
        File.unlink(sockfile) rescue nil
      end

      def sanity_check
        if !File.exist?(lockfile_path)
          raise WorkerStateError, "lockfile gone"
        end

        pid = File.read(lockfile_path) rescue nil

        unless pid
          raise WorkerStateError, "could not read lockfile"
        end

        unless pid == Process.pid.to_s
          raise WorkerStateError, "lockfile points to different process"
        end

        unless sockfile?
          raise WorkerStateError, "sockfile gone"
        end
      end
    end
  end
end