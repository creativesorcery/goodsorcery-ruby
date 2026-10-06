# frozen_string_literal: true

module GoodSorcery
  module Event
    # Builds the event hash for one exception in the caller's thread, already
    # within the server's size limits (INGEST_API.md). Filtering and
    # before_send happen afterwards, in EventPipeline.
    class Builder
      NOTIFIER = { "name" => NOTIFIER_NAME, "version" => VERSION }.freeze
      MAX_TRANSACTION_LENGTH = 1_000

      def initialize(config)
        @config = config
        @sanitizer = Sanitizer.new
        @exception_section = build_exception_section(config)
        @request_section = RequestSection.new(config.request_extractor, @sanitizer)
        @runtime = RuntimeContext.new
      end

      def build(exception, options, scope)
        event = header(options)
        event["exception"] = @exception_section.build(exception)
        event.merge!(scope_sections(options, scope))
        event["context"] = context(exception, options, scope)
        event["fingerprint"] = Fields.fingerprint(options[:fingerprint])
        event["notifier"] = NOTIFIER.dup
        event.compact
      end

      private

      def build_exception_section(config)
        paths = Backtrace::Paths.new(config.root)
        code_context = Backtrace::CodeContext.new(Backtrace::LineCache.new(paths))
        ExceptionSection.new(paths: paths, code_context: code_context, send_code_context: config.send_code_context)
      end

      def header(options)
        {
          "event_id" => Fields.event_id,
          "occurred_at" => Fields.timestamp,
          "level" => Fields.level(options[:level]),
          "release" => @config.release
        }
      end

      def scope_sections(options, scope)
        {
          "transaction" => Fields.text(options[:transaction] || scope.transaction, MAX_TRANSACTION_LENGTH),
          "request" => @request_section.build(scope),
          "user" => UserSection.build(options[:user] || scope.user),
          "breadcrumbs" => breadcrumbs(scope),
          "tags" => presence(TagSet.merge(@config.tags, scope.tags, options[:tags]))
        }
      end

      def presence(hash)
        hash.empty? ? nil : hash
      end

      def breadcrumbs(scope)
        crumbs = scope.breadcrumbs.to_a.last(100)
        crumbs.empty? ? nil : crumbs.map(&:dup)
      end

      def context(exception, options, scope)
        context = @runtime.to_h
        causes = CauseChain.new(exception).to_a
        context["cause"] = causes unless causes.empty?
        context.merge!(@sanitizer.sanitize(scope.context)) if scope.context.any?
        context.merge!(@sanitizer.sanitize(options[:context])) if options[:context].is_a?(Hash)
        context
      end
    end
  end
end
