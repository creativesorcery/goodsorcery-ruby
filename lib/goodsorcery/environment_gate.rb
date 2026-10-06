# frozen_string_literal: true

module GoodSorcery
  # Decides whether reporting is on for the configured environment
  # (DESIGN.md 3.2) and explains why.
  class EnvironmentGate
    def initialize(config)
      @config = config
    end

    # Checked on every report and breadcrumb, so it builds no strings.
    def enabled?
      explicit = @config.enabled
      return explicit unless explicit.nil?

      allow_list = @config.enabled_environments
      return listed?(allow_list) if allow_list

      !listed?(@config.disabled_environments)
    end

    def reason
      decision.last
    end

    private

    def decision
      explicit = @config.enabled
      return [explicit, "config.enabled (or GOODSORCERY_ENABLED) is #{explicit}"] unless explicit.nil?
      return allow_list_decision if @config.enabled_environments

      deny_list_decision
    end

    def allow_list_decision
      included = names(@config.enabled_environments).include?(environment)
      verb = included ? "is" : "is not"
      [included, "environment #{environment.inspect} #{verb} in enabled_environments"]
    end

    def deny_list_decision
      excluded = names(@config.disabled_environments).include?(environment)
      verb = excluded ? "is" : "is not"
      [!excluded, "environment #{environment.inspect} #{verb} in disabled_environments"]
    end

    def environment
      @config.environment.to_s
    end

    def names(list)
      Array(list).map(&:to_s)
    end

    def listed?(list)
      name = environment
      Array(list).any? { |entry| entry.to_s == name }
    end
  end
end
