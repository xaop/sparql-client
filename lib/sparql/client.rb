require 'net/http/persistent'
require 'rdf' # @see http://rubygems.org/gems/rdf
require 'rdf/ntriples'

module SPARQL
  ##
  # A SPARQL client for RDF.rb.
  #
  # @see http://www.w3.org/TR/rdf-sparql-protocol/
  # @see http://www.w3.org/TR/rdf-sparql-json-res/
  class Client
    autoload :Query,      'sparql/client/query'
    autoload :Repository, 'sparql/client/repository'
    autoload :VERSION,    'sparql/client/version'

    class ClientError < StandardError; end
    class MalformedQuery < ClientError; end
    class ServerError < StandardError; end

    RESULT_BOOL = 'text/boolean'.freeze # Sesame-specific
    RESULT_JSON = 'application/sparql-results+json'.freeze
    RESULT_XML  = 'application/sparql-results+xml'.freeze
    ACCEPT_JSON = {'Accept' => RESULT_JSON}.freeze
    ACCEPT_XML  = {'Accept' => RESULT_XML}.freeze

    DEFAULT_METHOD = "post"

    attr_reader :url
    attr_reader :options

    ##
    # @param  [String, #to_s]          url
    # @param  [Hash{Symbol => Object}] options
    # @option options [Hash] :headers
    def initialize(options = {}, &block)
      @options = options
      @url = RDF::URI.new(options[:url].to_s)
      @update_url = options[:update_url] ? RDF::URI.new(options[:update_url].to_s) : @url
      @query_parameter = options[:query_parameter] ? options[:query_parameter].to_sym : :query
      @update_query_parameter = options[:update_query_parameter] ? options[:update_query_parameter].to_sym : @query_parameter
      #@headers = {'Accept' => "#{RESULT_JSON}, #{RESULT_XML}, text/plain"}
      @headers = {
        'Accept' => [RESULT_JSON, RESULT_XML, RDF::Format.content_types.keys.map(&:to_s)].join(', ')
      }.merge @options[:headers] || {}
      @proxy_uri = options[:http_proxy]
      @http = http_klass(@url.scheme)

      if block_given?
        case block.arity
          when 1 then block.call(self)
          else instance_eval(&block)
        end
      end
    end

    ##
    # Executes a boolean `ASK` query.
    #
    # @return [Query]
    def ask(*args)
      call_query_method(:ask, *args)
    end

    ##
    # Executes a tuple `SELECT` query.
    #
    # @param  [Array<Symbol>] variables
    # @return [Query]
    def select(*args)
      call_query_method(:select, *args)
    end

    ##
    # Executes a `DESCRIBE` query.
    #
    # @param  [Array<Symbol, RDF::URI>] variables
    # @return [Query]
    def describe(*args)
      call_query_method(:describe, *args)
    end

    ##
    # Executes a graph `CONSTRUCT` query.
    #
    # @param  [Array<Symbol>] pattern
    # @return [Query]
    def construct(*args)
      call_query_method(:construct, *args)
    end

    ##
    # @private
    def call_query_method(meth, *args)
      client = self
      result = Query.send(meth, *args)
      (class << result; self; end).send(:define_method, :execute) do
        client.query(self)
      end
      result
    end

    ##
    # A mapping of blank node results for this client
    # @private
    def nodes
      @nodes ||= {}
    end

    ##
    # Executes a SPARQL query and returns parsed results.
    #
    # @param  [String, #to_s]          url
    # @param  [Hash{Symbol => Object}] options
    # @option options [String] :content_type
    # @option options [Hash] :headers
    # @return [Array<RDF::Query::Solution>]
    def query(query, options = {})
      parse_response(response(query, options), options)
    end

    def update_query(query, options = {})
      parse_response(response(query, options.merge(:type => :update)), options)
    end

    ##
    # Executes a SPARQL query and returns the Net::HTTP::Response of the result.
    #
    # @param [String, #to_s]   url
    # @param  [Hash{Symbol => Object}] options
    # @option options [String] :content_type
    # @option options [Hash] :headers
    # @return [String]
    def response(query, options = {})
      @headers['Accept'] = options[:content_type] if options[:content_type]
      method = options[:method] || self.options[:method] || DEFAULT_METHOD
      send(method, query, options[:headers] || {}, options[:type]) do |response|
        case response
          when Net::HTTPBadRequest  # 400 Bad Request
            raise MalformedQuery.new(response.body)
          when Net::HTTPClientError # 4xx
            raise ClientError.new(response.body)
          when Net::HTTPServerError # 5xx
            raise ServerError.new(response.body)
          when Net::HTTPSuccess     # 2xx
            response
        end
      end

    end

    ##
    # @param  [Net::HTTPSuccess] response
    # @param  [Hash{Symbol => Object}] options
    # @return [Object]
    def parse_response(response, options = {})
      case content_type = options[:content_type] || response.content_type
        when RESULT_BOOL # Sesame-specific
          response.body == 'true'
        when RESULT_JSON
          self.class.parse_json_bindings(response.body, nodes)
        when RESULT_XML
          self.class.parse_xml_bindings(response.body, nodes)
        else
          parse_rdf_serialization(response, options)
      end
    end

    ##
    # @param  [String, Hash] json
    # @return [Enumerable<RDF::Query::Solution>]
    # @see    http://www.w3.org/TR/rdf-sparql-json-res/#results
    def self.parse_json_bindings(json, nodes = {})
      require 'json' unless defined?(::JSON)
      json = JSON.parse(json.to_s) unless json.is_a?(Hash)

      case
        when json['boolean']
          json['boolean']
        when json['results']
          json['results']['bindings'].map do |row|
            row = row.inject({}) do |cols, (name, value)|
              cols.merge(name.to_sym => parse_json_value(value))
            end
            RDF::Query::Solution.new(row)
          end
      end
    end

    ##
    # @param  [Hash{String => String}] value
    # @return [RDF::Value]
    # @see    http://www.w3.org/TR/rdf-sparql-json-res/#variable-binding-results
    def self.parse_json_value(value, nodes = {})
      case value['type'].to_sym
        when :bnode
          nodes[id = value['value']] ||= RDF::Node.new(id)
        when :uri
          RDF::URI.new(value['value'])
        when :literal
          RDF::Literal.new(value['value'], :language => value['xml:lang'])
        when :'typed-literal'
          RDF::Literal.new(value['value'], :datatype => value['datatype'])
        else nil
      end
    end

    ##
    # @param  [String, REXML::Element] xml
    # @return [Enumerable<RDF::Query::Solution>]
    # @see    http://www.w3.org/TR/rdf-sparql-json-res/#results
    def self.parse_xml_bindings(xml, nodes = {})
      xml.force_encoding(::Encoding::UTF_8) if xml.respond_to?(:force_encoding)
      require 'rexml/document' unless defined?(::REXML::Document)
      xml = REXML::Document.new(xml).root unless xml.is_a?(REXML::Element)

      case
        when boolean = xml.elements['boolean']
          boolean.text == 'true'
        when results = xml.elements['results']
          results.elements.map do |result|
            row = {}
            result.elements.each do |binding|
              name  = binding.attributes['name'].to_sym
              value = binding.select { |node| node.kind_of?(::REXML::Element) }.first
              row[name] = parse_xml_value(value, nodes)
            end
            RDF::Query::Solution.new(row)
          end
      end
    end

    ##
    # @param  [REXML::Element] value
    # @return [RDF::Value]
    # @see    http://www.w3.org/TR/rdf-sparql-json-res/#variable-binding-results
    def self.parse_xml_value(value, nodes = {})
      case value.name.to_sym
        when :bnode
          nodes[id = value.text] ||= RDF::Node.new(id)
        when :uri
          RDF::URI.new(value.text)
        when :literal
          RDF::Literal.new(value.text, {
            :language => value.attributes['xml:lang'],
            :datatype => value.attributes['datatype'],
          })
        else nil
      end
    end

    ##
    # @param  [Net::HTTPSuccess] response
    # @param  [Hash{Symbol => Object}] options
    # @return [RDF::Enumerable]
    def parse_rdf_serialization(response, options = {})
      options = {:content_type => response.content_type} unless options[:content_type]
      if reader = RDF::Reader.for(options)
        reader.new(response.body)
      end
    end

    ##
    # Outputs a developer-friendly representation of this object to `stderr`.
    #
    # @return [void]
    def inspect!
      warn(inspect)
    end

    ##
    # Returns a developer-friendly representation of this object.
    #
    # @return [String]
    def inspect
      sprintf("#<%s:%#0x(%s)>", self.class.name, __id__, url.to_s)
    end

    protected

    ##
    # Returns an HTTP class or HTTP proxy class based on environment http_proxy & https_proxy settings
    # @return [Net::HTTP::Proxy]
    def http_klass(scheme)
      proxy_uri = nil
      case scheme
        when "http"
          proxy_uri = URI.parse(ENV['http_proxy']) unless ENV['http_proxy'].nil?
        when "https"
          proxy_uri = URI.parse(ENV['https_proxy']) unless ENV['https_proxy'].nil?
      end
      proxy_uri = URI.parse(@proxy_uri) if @proxy_uri
      klass = Net::HTTP::Persistent.new(self.class.to_s, proxy_uri)
      klass.keep_alive = 120	# increase to 2 minutes
      klass
    end

    ##
    # Performs an HTTP GET request against the SPARQL endpoint.
    #
    # @param  [String, #to_s]          query
    # @param  [Hash{String => String}] headers
    # @yield  [response]
    # @yieldparam [Net::HTTPResponse] response
    # @return [Net::HTTPResponse]
    def get(query, headers = {}, type, &block)
      url = self.url.dup
      parameter = type == :update ? @update_query_parameter : @query_parameter
      url.query_values = (url.query_values || {}).merge({parameter => query.to_s})

      request = Net::HTTP::Get.new(url.request_uri, @headers.merge(headers))
      request.basic_auth url.user, url.password if url.user && !url.user.empty?
      response = @http.request ::URI.parse(url.to_s), request
      if block_given?
        block.call(response)
      else
        response
      end
    end

    ##
    # Performs an HTTP GET request against the SPARQL endpoint.
    #
    # @param  [String, #to_s]          query
    # @param  [Hash{String => String}] headers
    # @yield  [response]
    # @yieldparam [Net::HTTPResponse] response
    # @return [Net::HTTPResponse]
    def post(query, headers = {}, type, &block)
      url = type == :update ? @update_url.dup : @url.dup
      parameter = type == :update ? @update_query_parameter : @query_parameter
      form_data = (url.query_values || {}).merge({parameter => query.to_s})
      url.query_values = nil

      request = Net::HTTP::Post.new(url.request_uri, @headers.merge(headers))
      request.set_form_data(form_data)
      request.basic_auth url.user, url.password if url.user && !url.user.empty?
      retry_counter = 0
      begin
        response = @http.request ::URI.parse(url.to_s), request
      rescue Net::HTTP::Persistent::Error => e
        if retry_counter < 2 && /too many connection resets/ === e.message
          retry_counter += 1
          puts "RETRYING (#{retry_counter}) AFTER CONNECTION RESET"
          puts caller.map { |l| "  #{l}" }.join("\n")
          retry
        else
          raise e
        end
      end
      if block_given?
        block.call(response)
      else
        response
      end
    end
  end # Client
end # SPARQL
