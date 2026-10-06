# frozen_string_literal: true

# Bundler plugin entry point (`plugin "goodsorcery"` in a Gemfile).
require_relative "lib/goodsorcery/bundler_plugin"

GoodSorcery::BundlerPlugin.register
