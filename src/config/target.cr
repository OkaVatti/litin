# src/config/target.cr
#
# Target definitions for Litin.
#
# A target is a named group of services representing a desired system
# state. Targets behave like services with type=oneshot and no command:
# they are "reached" when all their hard dependencies are ready.
#
# Predefined target names and their roles:
#
#   boot.target       — filesystems mounted, basic devices ready
#   basic.target      — kernel services, udev, early network
#   network.target    — network interfaces configured
#   multi-user.target — all normal system services running
#   default.target    — symlink/alias for the default runlevel
#   graphical.target  — multi-user plus display manager
#   rescue.target     — single-user recovery mode
#   shutdown.target   — system is shutting down
#
# Target files live in /etc/litin/targets/ with a .target suffix.
# The "wants" convention mirrors systemd: a target.wants/ directory
# contains symlinks to service definitions that belong to that target.

require "./service_definition"

module Litin
  module Config
    class TargetDefinition
      property name        : String = ""
      property description : String = ""
      property source_path : String = ""
      property dependencies : Array(Dependency)

      # Services explicitly listed as members of this target.
      property wants : Array(String)

      def initialize
        @dependencies = [] of Dependency
        @wants        = [] of String
      end
    end

    class TargetLoader
      TARGETS_DIR = "/etc/litin/targets"

      PREDEFINED = {
        "boot"        => "Minimal system (filesystems, basic devices)",
        "basic"       => "Basic system services",
        "network"     => "Network interfaces configured",
        "multi-user"  => "Multi-user system",
        "default"     => "Default target",
        "graphical"   => "Graphical login",
        "rescue"      => "Single-user rescue mode",
        "shutdown"    => "System shutdown",
      }

      def self.load_all(dir : String = TARGETS_DIR) : Array(TargetDefinition)
        result = [] of TargetDefinition

        # Load predefined targets first.
        PREDEFINED.each do |name, desc|
          t             = TargetDefinition.new
          t.name        = name
          t.description = desc
          result << t
        end

        return result unless Dir.exists?(dir)

        # Load user-defined target files.
        Dir.each_child(dir) do |entry|
          next unless entry.ends_with?(".target")
          path = File.join(dir, entry)
          next if File.directory?(path)

          begin
            t = parse_target_file(path)
            t.name = entry.rstrip(".target") if t.name.empty?
            # Merge with predefined if it exists.
            existing = result.find { |x| x.name == t.name }
            if existing
              existing.description = t.description unless t.description.empty?
              existing.dependencies.concat(t.dependencies)
            else
              result << t
            end
          rescue ex
            STDERR.puts "[target loader] skipping #{path}: #{ex.message}"
          end
        end

        # For each target, scan its .wants/ directory.
        result.each do |target|
          wants_dir = File.join(dir, "#{target.name}.wants")
          next unless Dir.exists?(wants_dir)

          Dir.each_child(wants_dir) do |entry|
            target.wants << entry unless target.wants.includes?(entry)
          end
        end

        result
      end

      private def self.parse_target_file(path : String) : TargetDefinition
        t = TargetDefinition.new
        t.source_path = path

        SCALAR_RE = /^[ \t]*([A-Za-z_][A-Za-z0-9_]*)[ \t]*=[ \t]*(?:"([^"\\]*)"|'([^'\\]*)'|([^\s#]+))/
        DEP_RE    = /^[ \t]*(require|need|want|use|after|before|conflicts|part_of)\s+(.+)/

        in_depend  = false
        dep_depth  = 0

        File.each_line(path) do |raw|
          line = raw.strip
          next if line.empty? || line.starts_with?('#')

          if line =~ /^depend\s*\(\s*\)\s*\{?/
            in_depend = true
            dep_depth = line.count('{') - line.count('}')
            next
          end

          if in_depend
            dep_depth += line.count('{') - line.count('}')
            if dep_depth <= 0
              in_depend = false
              next
            end
            if m = line.match(DEP_RE)
              keyword = m[1]
              targets = m[2].split(/\s+/).reject(&.empty?)
              kind    = case keyword
                        when "require", "need"  then Dependency::Kind::Require
                        when "want",    "use"   then Dependency::Kind::Want
                        when "after"            then Dependency::Kind::After
                        when "before"           then Dependency::Kind::Before
                        when "conflicts"        then Dependency::Kind::Conflicts
                        else                         Dependency::Kind::PartOf
                        end
              t.dependencies << Dependency.new(kind, targets)
            end
            next
          end

          if m = line.match(SCALAR_RE)
            key   = m[1]
            value = (m[2]? || m[3]? || m[4]? || "").strip
            case key
            when "name"        then t.name = value
            when "description" then t.description = value
            end
          end
        end

        t
      end
    end

    # ---------------------------------------------------------------------------
    # Target status summary for list-targets
    # ---------------------------------------------------------------------------

    struct TargetStatus
      getter name        : String
      getter description : String
      getter wants       : Array(String)   # service names

      def initialize(@name, @description, @wants)
      end

      def to_s(io : IO)
        io << name.ljust(20) << "  " << description
      end
    end
  end
end