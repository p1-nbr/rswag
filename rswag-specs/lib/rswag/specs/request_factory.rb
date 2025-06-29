# frozen_string_literal: true

require 'active_support'
require 'active_support/core_ext/hash/slice'
require 'active_support/core_ext/hash/conversions'
require 'json'

module Rswag
  module Specs
    class RequestFactory
      attr_accessor :example, :metadata, :params, :headers

      def initialize(metadata, example, config = ::Rswag::Specs.config)
        @config = config
        @example = example
        @metadata = metadata
        @params = to_indifferent_hash(example, :request_params)
        @headers = to_indifferent_hash(example, :request_headers)
      end

      def to_indifferent_hash(example, key)
        if example.respond_to?(key)
          example.send(key)
        else
          {}
        end.with_indifferent_access
      rescue NoMethodError
        raise ArgumentError, "#{key} must be a Hash"
      end

      def build_request
        openapi_spec = @config.get_openapi_spec(metadata[:openapi_spec])
        parameters = expand_parameters(metadata, openapi_spec, example)

        {}.tap do |request|
          add_verb(request, metadata)
          add_path(request, metadata, openapi_spec, parameters, example)
          add_headers(request, metadata, openapi_spec, parameters, example)
          add_payload(request, parameters, example)
        end
      end

      private

      def expand_parameters(metadata, openapi_spec, _example)
        operation_params = metadata[:operation][:parameters] || []
        path_item_params = metadata[:path_item][:parameters] || []
        security_params = derive_security_params(metadata, openapi_spec)

        # NOTE: Use of + instead of concat to avoid mutation of the metadata object
        (operation_params + path_item_params + security_params)
          .map { |prm| has_ref?(prm) ? resolve_parameter(prm, openapi_spec, schema_key: :schema) : prm }
          .uniq { |p| p[:name] }
          .reject do |p|
            p[:required] == false &&
              !headers.key?(p[:name]) &&
              !params.key?(p[:name])
          end
      end

      def has_ref?(object)
        return false unless object.is_a?(Hash)

        object[:$ref] || object.any? { |_, v| has_ref?(v) }
      end

      def resolve_parameter(object, openapi_spec, schema_key: nil)
        return object unless object.is_a?(Hash)

        ref = get_ref(object, schema_key)

        unless ref.nil?
          ref_obj = resolve_reference(ref, openapi_spec)
          unless ref_obj.nil?
            if schema_key.nil?
              object.merge!(ref_obj)
            else
              object[schema_key].merge!(ref_obj)
            end
          end
        end

        object.each do |key, val|
          object[key] = resolve_parameter(val, openapi_spec)
        end

        object
      end

      def get_ref(object, key)
        if key.nil?
          object.delete(:$ref)
        else
          object[key].delete(:$ref)
        end
      end

      def resolve_reference(ref, openapi_spec)
        return if ref.nil?

        raise "Invalid object reference '#{ref}'" unless valid_openapi_ref?(ref)

        ref_parts = ref_parts(ref)
        object = openapi_spec.dig(*ref_parts)
        raise "Cannot resolve referenced object '#{ref}'" if object.nil?

        object
      end

      def derive_security_params(metadata, openapi_spec)
        requirements = metadata[:operation][:security] || openapi_spec[:security] || []
        scheme_names = requirements.flat_map(&:keys)
        schemes = security_version(scheme_names, openapi_spec)

        schemes.map do |scheme|
          param = scheme[:type] == :apiKey ? scheme.slice(:name, :in) : { name: 'Authorization', in: :header }
          param.merge(schema: { type: :string }, required: requirements.one?)
        end
      end

      def security_version(scheme_names, openapi_spec)
        components = openapi_spec[:components] || {}
        (components[:securitySchemes] || {}).slice(*scheme_names).values
      end

      SECTIONS = %w[
        schemas
        parameters
        responses
        requestBodies
        headers
        securitySchemes
        links
        callbacks
        examples
      ].freeze
      REFERENCE_PATTERN = "#/components/(#{SECTIONS.join('|')})/[\\w.-]+".freeze

      def valid_openapi_ref?(ref)
        return false unless ref.is_a?(String) && !ref.empty?

        local_ref?(ref) || external_ref?(ref)
      end

      def local_ref?(ref)
        # Local reference: #/components/{type}/{name}
        ref.match?(/^#{REFERENCE_PATTERN}$/)
      end

      def external_ref?(ref)
        # External reference: {uri}#/components/{type}/{name}
        valid_uri?(ref) && ref.match?(/#{REFERENCE_PATTERN}/)
      end

      def valid_uri?(uri)
        URI.parse(uri)
        true
      rescue URI::InvalidURIError
        false
      end

      def ref_parts(ref)
        ref.sub(%r{#/}, '').split('/').map(&:to_sym)
      end

      def definition_version(openapi_spec)
        components = openapi_spec[:components] || {}
        components[:parameters]
      end

      def add_verb(request, metadata)
        request[:verb] = metadata[:operation][:verb]
      end

      def base_path_from_servers(openapi_spec, use_server = :default)
        return '' if openapi_spec[:servers].nil? || openapi_spec[:servers].empty?

        server = openapi_spec[:servers].first
        variables = {}
        server.fetch(:variables, {}).each_pair { |k, v| variables[k] = v[use_server] }
        base_path = server[:url].gsub(/\{(.*?)\}/) { variables[::Regexp.last_match(1).to_sym] }
        URI(base_path).path
      end

      def add_path(request, metadata, openapi_spec, parameters, _example)
        template = base_path_from_servers(openapi_spec) + metadata[:path_item][:template]

        request[:path] = template.tap do |path_template|
          parameters.select { |p| p[:in] == :path }.each do |p|
            begin
              param_value = params.fetch(p[:name]).to_s
            rescue KeyError
              raise ArgumentError, ("`#{p[:name]}`" \
                'parameter key present, but not defined within example group' \
                '(i. e `it` or `let` block)')
            end
            path_template.gsub!("{#{p[:name]}}", param_value)
          end

          parameters.select { |p| p[:in] == :query && params.key?(p[:name]) }.each_with_index do |p, i|
            path_template.concat(i.zero? ? '?' : '&')
            path_template.concat(build_query_string_part(p, params.fetch(p[:name]), openapi_spec))
          end
        end
      end

      SEPARATOR = {
        form: '&',
        matrix: ';',
        label: '.',
        spaceDelimited: '%20',
        pipeDelimited: '|'
      }.freeze
      def build_query_string_part(param, value, _openapi_spec)
        raise ArgumentError, "'type' is not supported field for Parameter" unless param[:type].nil?

        name = param[:name]
        escaped_name = CGI.escape(name.to_s)

        # NOTE: https://swagger.io/docs/specification/serialization/
        return unless param[:schema]

        style = param[:style]&.to_sym || :form
        explode = param[:explode].nil? || param[:explode]
        type = param.dig(:schema, :type)&.to_sym

        case type
        when :object
          case style
          when :deepObject
            { name => value }.to_query
          when :form
            return value.to_query(param[:name]) if explode

            "#{escaped_name}=" + value.to_a.flatten.map { |v| escape_value(v) }.join(',')

          end
        when :array
          value = value.to_a.flatten
          items_type = param.dig(:schema, :items, :type).to_sym
          separator = SEPARATOR[style]

          if explode
            # Special handling for different types with explode=true
            if items_type == :object && value.first.is_a?(Hash)
              # Use to_query directly for array of hashes
              param_vals = { param[:name] => {} }
              value.each_with_index { |v, idx| param_vals[param[:name]][idx.to_s] = v }
              query_string = param_vals.to_query
            else
              # For all other cases, generate array of values and join
              array_values = case items_type.to_sym
                             when :object, :array
                               value.map { |v| v.to_query(param[:name]) }
                             else
                               value.map { |v| { "#{param[:name]}[]" => escape_value(v) }.to_query }
                             end

              query_string = array_values.join(separator)
            end
            
            query_string
          else
            "#{escaped_name}=" + value.map { |v| escape_value(v) }.join(separator)
          end
        else
          "#{escaped_name}=#{escape_value(value)}"
        end
      end

      def escape_value(value)
        CGI.escape(value.to_s)
      end

      def add_headers(request, metadata, openapi_spec, parameters, example)
        tuples = parameters
                 .select { |p| p[:in] == :header }
                 .map { |p| [p[:name], headers.fetch(p[:name]).to_s] }

        # Accept header
        produces = metadata[:operation][:produces] || openapi_spec[:produces]
        if produces
          accept = headers.fetch('Accept', produces.first)
          tuples << ['Accept', accept]
        end

        # Content-Type header
        consumes = metadata[:operation][:consumes] || openapi_spec[:consumes]
        if consumes
          content_type = headers.fetch('Content-Type', consumes.first)
          tuples << ['Content-Type', content_type]
        end

        # Host header
        host = metadata[:operation][:host] || openapi_spec[:host]
        if host.present?
          host = example.respond_to?(:Host) ? example.send(:Host) : host
          tuples << ['Host', host]
        end

        # Rails test infrastructure requires rack-formatted headers
        rack_formatted_tuples = tuples.map do |pair|
          [
            case pair[0]
            when 'Accept' then 'HTTP_ACCEPT'
            when 'Content-Type' then 'CONTENT_TYPE'
            when 'Authorization' then 'HTTP_AUTHORIZATION'
            when 'Host' then 'HTTP_HOST'
            else pair[0]
            end,
            pair[1]
          ]
        end

        request[:headers] = Hash[rack_formatted_tuples]
      end

      def add_payload(request, parameters, example)
        content_type = request[:headers]['CONTENT_TYPE']
        return if content_type.nil?

        request[:payload] = if ['application/x-www-form-urlencoded', 'multipart/form-data'].include?(content_type)
                              build_form_payload(parameters, example)
                            elsif %r{\Aapplication/([0-9A-Za-z._-]+\+json\z|json\z)}.match?(content_type)
                              build_json_payload(parameters, example)
                            else
                              build_raw_payload(parameters, example)
                            end
      end

      def build_form_payload(parameters, _example)
        # See http://seejohncode.com/2012/04/29/quick-tip-testing-multipart-uploads-with-rspec/
        # Rather that serializing with the appropriate encoding (e.g. multipart/form-data),
        # Rails test infrastructure allows us to send the values directly as a hash
        # PROS: simple to implement, CONS: serialization/deserialization is bypassed in test
        tuples = parameters
                 .select { |p| p[:in] == :formData }
                 .map { |p| [p[:name], params.fetch(p[:name])] }
        Hash[tuples]
      end

      def build_raw_payload(parameters, _example)
        body_param = parameters.find { |p| p[:in] == :body }
        return nil unless body_param

        begin
          json_payload = params.fetch(body_param[:name].to_s)
        rescue KeyError
          raise(MissingParameterError, body_param[:name])
        end

        json_payload
      end

      def build_json_payload(parameters, example)
        build_raw_payload(parameters, example)&.to_json
      end

      def doc_version(doc)
        doc[:openapi]
      end
    end

    class MissingParameterError < StandardError
      attr_reader :body_param

      def initialize(body_param)
        @body_param = body_param
      end

      def message
        <<~MSG
          Missing parameter '#{body_param}'

          Please check your spec. It looks like you defined a body parameter,
          but did not declare usage via let. Try adding:

              let(:#{body_param}) {}
        MSG
      end
    end
  end
end
