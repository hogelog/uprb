# frozen_string_literal: true

module Uprb
  module RequireTracker
    class << self
      attr_reader :mapping

      def start
        install_require_hook
        @mapping = {}
      end

      def stop
        recorded = @mapping
        @mapping = nil
        return recorded
      end
    end

    SO_EXTS = %w[.so .o]

    class << self
      def record_require(name)
        return if !@mapping || @mapping[name]

        path = find_loaded_feature(name)
        @mapping[name] = path if path
      end

      private

      def install_require_hook
        return if defined?(@require_hook_installed) && @require_hook_installed

        if Kernel.private_method_defined?(:uprb_original_require)
          @require_hook_installed = true
          return
        end

        Kernel.module_eval do
          alias_method :uprb_original_require, :require
          alias_method :uprb_original_require_relative, :require_relative

          def require(name)
            required = uprb_original_require(name)
            Uprb::RequireTracker.record_require(name)
            required
          end

          def require_relative(path)
            caller_path = caller_locations(1, 1).first.path
            absolute_path = File.expand_path(path, File.dirname(caller_path))
            required = uprb_original_require(absolute_path)
            Uprb::RequireTracker.record_require(absolute_path)
            required
          end

          private :require, :uprb_original_require
          private :require_relative, :uprb_original_require_relative
        end

        @require_hook_installed = true
      end

      def find_loaded_feature(name)
        extname = File.extname(name)
        if SO_EXTS.include?(extname)
          target_name = name.delete_suffix(extname)
          suffixes = Gem.dynamic_library_suffixes
        else
          target_name = name
          suffixes = Gem.suffixes
        end
        suffixes.each do |suffix|
          $LOADED_FEATURES.find do |f|
            return f if /(?:\A|#{File::SEPARATOR})#{target_name}#{suffix}\z/.match?(f)
          end
        end

        nil
      end

      def absolute_path?(name)
        name.start_with?(File::SEPARATOR) ||
          (File::ALT_SEPARATOR && name.start_with?(File::ALT_SEPARATOR))
      end
    end
  end
end
