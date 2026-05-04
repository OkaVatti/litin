# src/config/target.cr
#
# Target definitions for Litin.
#
# A target is a named group of services representing a desired system
# state. Targets behave like services with type=oneshot and no command:
# they are "reached" when all their hard dependencies are ready.

require "./service_definition"

module Litin
  module Config
    class TargetDefinition
      property name : String = ""
      property description : String = ""
      property source_path : String = ""
      property dependencies : Array(Dependency)
      property wants : Array(String)

      def initialize
        @dependencies = [] of Dependency
        @wants = [] of String
      end
    end

    class TargetLoader
      TARGETS_DIR = "/etc/litin/targets"

      PREDEFINED = {
        "boot"       => "Minimal system (filesystems, basic devices)",
        "basic"      => "Basic system services",
        "network"    => "Network interfaces configured",
        "multi-user" => "Multi-user system",
        "default"    => "Default target",
        "graphical"  => "Graphical login",
        "rescue"     => "Single-user rescue mode",
        "shutdown"   => "System shutdown",
      }

      def self.load_all(dir : String = TARGETS_DIR) : Array(TargetDefinition)
        result = [] of TargetDefinition

        PREDEFINED.each do |name, desc|
          t = TargetDefinition.new
          t.name = name
          t.description = desc
          result << t
        end

        return result unless Dir.exists?(dir)

        Dir.each_child(dir) do |entry|
          next unless entry.ends_with?(".target")
          path = File.join(dir, entry)
          next if File.directory?(path)

          begin
            t = parse_target_file(path)
            # Use #chomp to remove a specific suffix (not #rstrip which strips chars).
            t.name = entry.chomp(".target") if t.name.empty?
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

        scalar_re = /^[ \t]*([A-Za-z_][A-Za-z0-9_]*)[ \t]*=[ \t]*(?:"([^"\\]*)"|'([^'\\]*)'|([^\s#]+))/
        dep_re = /^[ \t]*(require|need|want|use|after|before|conflicts|part_of)\s+(.+)/

        in_depend = false
        dep_depth = 0

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
            if m = line.match(dep_re)
              keyword = m[1]
              targets = m[2].split(/\s+/).reject(&.empty?)
              kind = case keyword
                     when "require", "need" then Dependency::Kind::Require
                     when "want", "use"     then Dependency::Kind::Want
                     when "after"           then Dependency::Kind::After
                     when "before"          then Dependency::Kind::Before
                     when "conflicts"       then Dependency::Kind::Conflicts
                     else                        Dependency::Kind::PartOf
                     end
              t.dependencies << Dependency.new(kind, targets)
            end
            next
          end

          if m = line.match(scalar_re)
            key = m[1]
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

    struct TargetStatus
      getter name : String
      getter description : String
      getter wants : Array(String)

      def initialize(@name, @description, @wants)
      end

      def to_s(io : IO)
        io << name.ljust(20) << "  " << description
      end
    end
  end
end
