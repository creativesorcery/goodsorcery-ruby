# frozen_string_literal: true

require "logger"

module GoodSorcery
  # Prefixes and rate-limits the gem's own log lines. Never pass captured
  # error data or API keys to it: messages name classes, counts and statuses.
  class Log
    PREFIX = "[goodsorcery]"

    def initialize(&logger_source)
      @logger_source = logger_source
      @mutex = Mutex.new
      @last_logged = {}
    end

    def debug(message) = write(:debug, message)
    def info(message) = write(:info, message)
    def warn(message) = write(:warn, message)
    def error(message) = write(:error, message)

    # Logs +message+ only the first time +key+ is seen in this process.
    def warn_once(key, message)
      warn(message) if first_time?(key, Float::INFINITY)
    end

    # Logs +message+ at most once per +interval+ seconds for +key+.
    def warn_every(key, interval, message)
      warn(message) if first_time?(key, interval)
    end

    def forget(key)
      @mutex.synchronize { @last_logged.delete(key) }
    end

    private

    def first_time?(key, interval)
      now = Process.clock_gettime(Process::CLOCK_MONOTONIC)
      @mutex.synchronize do
        last = @last_logged[key]
        next false if last && (interval == Float::INFINITY || now - last < interval)

        @last_logged[key] = now
        true
      end
    end

    def write(level, message)
      @logger_source.call&.public_send(level, "#{PREFIX} #{message}")
    rescue StandardError
      nil
    end
  end
end
