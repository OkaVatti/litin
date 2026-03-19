# src/util/env_dir.cr
#
# Runit-style env/ directory reader.
#
# An env directory contains one file per environment variable. The file
# name is the variable name; the file content (first line, newline
# stripped) is the value. Files beginning with '.' are ignored.
#
# This is fully compatible with the runit envdir(8) convention and
# with daemontools' envdir tool, so Runit service trees can be migrated
# without changes to their env/ directories.
#
# Usage:
#   env = Litin::Util::EnvDir.read("/etc/litin/services/myservice/env")
#   # => {"PORT" => "8080", "LOG_LEVEL" => "info"}

module Litin
  module Util
    module EnvDir
      # Read all KEY=value pairs from an env directory.
      # Returns an empty hash if the directory does not exist.
      def self.read(dir : String) : Hash(String, String)
        result = {} of String => String
        return result unless Dir.exists?(dir)

        Dir.each_child(dir) do |entry|
          # Skip hidden files and directories.
          next if entry.starts_with?('.')
          path = File.join(dir, entry)
          next if File.directory?(path)

          begin
            # Read first line only, strip trailing newline and whitespace.
            content = File.read(path)
            value = content.lines.first?.to_s.rstrip
            result[entry] = value
          rescue ex
            STDERR.puts "[env_dir] cannot read #{path}: #{ex.message}"
          end
        end

        result
      end

      # Merge env directory contents onto an existing environment hash.
      # Values from the directory override the base environment.
      def self.merge_into(base : Hash(String, String), dir : String) : Hash(String, String)
        base.merge(read(dir))
      end

      # Read a global env directory and a service-specific one, with the
      # service-specific values taking precedence.
      def self.read_layered(global_dir : String, service_dir : String) : Hash(String, String)
        global = read(global_dir)
        service = read(service_dir)
        global.merge(service)
      end
    end
  end
end
