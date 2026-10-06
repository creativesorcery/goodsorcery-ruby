# frozen_string_literal: true

require_relative "../integrations"

module GoodSorcery
  module Integrations
    # Rake: an exception that ends the rake process is reported with
    # transaction "rake <top-level tasks>" and context.rake (the failing task
    # and its arguments), then the queue is flushed (up to shutdown_timeout)
    # before Rake prints the error and exits.
    module Rake
      IVAR = :@__goodsorcery_rake_task

      def self.install
        ::Rake::Task.prepend(TaskExtension) unless ::Rake::Task <= TaskExtension
        ::Rake::Application.prepend(ApplicationExtension) unless ::Rake::Application <= ApplicationExtension
      end

      # Remembers the innermost task an exception escaped from.
      module TaskExtension
        def execute(args = nil)
          super
        rescue Exception => e # rubocop:disable Lint/RescueException
          FailedTask.remember(e, self, args)
          raise
        end
      end

      # Reports the exception before Rake displays it and exits.
      module ApplicationExtension
        def display_error_message(exception)
          FailedTask.report(exception, top_level_tasks)
          super
        end
      end

      # The task (name and arguments) an exception escaped from.
      module FailedTask
        module_function

        def remember(exception, task, args)
          return if exception.frozen? || exception.instance_variable_defined?(IVAR)

          arguments = args.respond_to?(:to_h) ? args.to_h : {}
          exception.instance_variable_set(IVAR, { "task" => task.name, "arguments" => arguments })
        rescue StandardError
          nil
        end

        def report(exception, top_level_tasks)
          rake = exception.instance_variable_defined?(IVAR) ? exception.instance_variable_get(IVAR) : nil
          GoodSorcery.notify(exception, transaction: transaction(top_level_tasks),
                                        context: rake ? { "rake" => rake } : nil)
          GoodSorcery.flush(GoodSorcery.configuration.shutdown_timeout)
        rescue StandardError
          nil
        end

        # Task arguments ("db:seed[a,b]") stay out of the transaction name;
        # they are sent, filtered, in context.rake.
        def transaction(top_level_tasks)
          names = Array(top_level_tasks).map { |name| name.to_s.sub(/\[.*\z/m, "") }
          "rake #{names.join(" ")}".strip
        end
      end
    end
  end
end
