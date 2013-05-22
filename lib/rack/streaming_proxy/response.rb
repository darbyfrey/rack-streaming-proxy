class Rack::StreamingProxy::Response
  include Rack::Utils # For HeaderHash

  class Error           < RuntimeError; end
  class ConnectionError < Error;        end
  class HttpServerError < Error;        end

  attr_reader :status, :headers

  def initialize(piper)
    @piper = piper
  end

  def receive
    # wait for the status and headers to come back from the child
    if @status = read_from_remote
      Rack::StreamingProxy::Proxy.log :debug, "Parent received: Status = #{@status}."

      if Rack::StreamingProxy::Proxy.raise_on_5xx && @status.to_s =~ /^5..$/
        Rack::StreamingProxy::Proxy.log :error, "Parent received #{@status} status!"
        finish
        raise HttpServerError
      else
        @body_permitted = read_from_remote
        Rack::StreamingProxy::Proxy.log :debug, "Parent received: Reponse has body? = #{@body_permitted}."

        @headers = HeaderHash.new(read_from_remote)

        finish unless @body_permitted # If there is a body, finish will be called inside each.
      end

    else
      Rack::StreamingProxy::Proxy.log :error, "Parent received unexpected nil status!"
      finish
      raise ConnectionError
    end

  end

  # This method is called by Rack itself, to iterate over the proxied contents.
  def each
    if @body_permitted
      chunked = @headers['Transfer-Encoding'] == 'chunked'
      term = '\r\n'

      while chunk = read_from_remote
        break if chunk == :done
        if chunked
          size = bytesize(chunk)
          next if size == 0
          yield [size.to_s(16), term, chunk, term].join
        else
          yield chunk
        end
      end

      finish

      yield ['0', term, '', term].join if chunked
    end
  end

private

  # parent needs to wait for the child, or it results in the child process becoming defunct, resulting in zombie processes!
  # This is very important. See: http://siliconisland.ca/2013/04/26/beware-of-the-zombie-process-apocalypse/
  def finish
    Rack::StreamingProxy::Proxy.log :debug, "Parent process #{Process.pid} waiting for child process #{@piper.pid} to exit."
    @piper.wait
  end

  def read_from_remote
    @piper.gets
  end

end