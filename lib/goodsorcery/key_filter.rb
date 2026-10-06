# frozen_string_literal: true

module GoodSorcery
  # Masks (or removes) values under sensitive keys, at any depth.
  #
  # Strings and symbols match a whole key, case-insensitively, with "-" and
  # "_" treated as equal ("secret_key" matches "Secret-Key" but not
  # "my_secret_key"). Regexps match any part of a key, in its own spelling
  # or with "-" read as "_" (so /_key/ catches the "X-Access-Key" header).
  # Patterns are compiled once, when the filter is built.
  class KeyFilter
    FILTERED = "[FILTERED]"
    MAX_DEPTH = 16

    def initialize(patterns, mode: :mask)
      regexps, names = Array(patterns).partition { |pattern| pattern.is_a?(Regexp) }
      @names = names.to_h { |name| [normalize(name), true] }
      @pattern = regexps.empty? ? nil : Regexp.union(regexps)
      @remove = mode == :remove
    end

    def filter_key?(key)
      name = key.to_s
      @names.key?(normalize(name)) || pattern_match?(name)
    end

    # Returns a filtered copy of +value+ (hashes and arrays are rebuilt).
    def filter(value, depth = 0)
      case value
      when Hash then filter_hash(value, depth)
      when Array then value.map { |item| filter(item, depth + 1) }
      else value
      end
    end

    # Masks sensitive parameters in a URL's query string ("user[password]=x"
    # is matched on "password" as well). +extra+ (an ExtraFilterProbe) also
    # applies the extra filters, such as Rails' filter_parameters.
    def filter_url(url, extra = nil)
      return url unless url.is_a?(String) && url.include?("?")

      base, query = url.split("?", 2)
      query, fragment = query.split("#", 2)
      filtered = "#{base}?#{filter_query(query, extra)}"
      fragment ? "#{filtered}##{fragment}" : filtered
    end

    private

    def filter_hash(hash, depth)
      return Sanitizer::TRUNCATED if depth > MAX_DEPTH

      hash.each_with_object({}) do |(key, value), out|
        filter_entry(out, key, value, depth)
      end
    end

    def filter_entry(out, key, value, depth)
      return out[key] = filter(value, depth + 1) unless filter_key?(key)

      out[key] = FILTERED unless @remove
    end

    def filter_query(query, extra)
      query.split("&").filter_map { |pair| filter_query_pair(pair, extra) }.join("&")
    end

    def filter_query_pair(pair, extra)
      key = pair.split("=", 2).first.to_s
      return pair unless sensitive_query_key?(key, extra)

      @remove ? nil : "#{key}=#{FILTERED}"
    end

    def sensitive_query_key?(key, extra)
      decoded = decode(key)
      parts = decoded.scan(/[^\[\]]+/)
      return true if [decoded, *parts].any? { |name| filter_key?(name) }

      extra ? extra.filters_path?(parts) : false
    end

    def decode(key)
      URI.decode_www_form_component(key)
    rescue ArgumentError
      key
    end

    def pattern_match?(name)
      return false unless @pattern
      return true if @pattern.match?(name)

      name.include?("-") && @pattern.match?(name.tr("-", "_"))
    end

    def normalize(name)
      name.to_s.downcase.tr("-", "_")
    end
  end
end
