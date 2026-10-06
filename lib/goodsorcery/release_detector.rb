# frozen_string_literal: true

module GoodSorcery
  # Finds the running release without shelling out to git: the first present
  # deploy environment variable, else the Capistrano REVISION file.
  class ReleaseDetector
    ENV_NAMES = %w[
      GOODSORCERY_RELEASE KAMAL_VERSION HEROKU_SLUG_COMMIT HEROKU_BUILD_COMMIT
      RENDER_GIT_COMMIT GIT_COMMIT GIT_SHA SOURCE_VERSION
    ].freeze
    MAX_LENGTH = 64

    def initialize(root)
      @root = root
    end

    def release
      value = release_from_env || release_from_revision_file
      value&.strip&.slice(0, MAX_LENGTH)
    end

    private

    def release_from_env
      ENV_NAMES.each do |name|
        value = EnvFlag.present(name)
        return value if value
      end
      nil
    end

    def release_from_revision_file
      return unless @root

      path = File.join(@root.to_s, "REVISION")
      content = File.file?(path) ? File.read(path, 256).to_s.strip : ""
      content.empty? ? nil : content
    rescue SystemCallError
      nil
    end
  end
end
