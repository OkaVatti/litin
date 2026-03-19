# src/config/parser.cr
#
# Hybrid service-definition parser.
#
# Parsing strategy
# ─────────────────
# Static metadata (name, command, user, type, restart, cgroup_* …) are
# extracted with a Crystal regex scanner.  No shell is invoked during
# parsing — the file is read once as text.
#
# Hook detection (pre_start, post_stop, reload, …) is done by scanning
# for lines matching /^hook_name\s*\(\s*\)/.
#
# The depend() function body is extracted by brace-depth tracking and
# then each line is matched against known dependency keywords.
#
# environment=() arrays are tokenised by a small hand-written tokeniser
# that handles the common cases:
#
#     environment=("KEY=val" "OTHER=val")   # parenthesised list
#     environment="KEY=val"                 # single value
#
# Variable expansion (e.g. command="$base -D") is NOT performed here.
# The supervisor passes the literal string to /bin/sh -c, which handles
# expansion at exec time.

require "./service_definition"

module Litin
  module Config
    class ParseError < Exception; end

    class Parser
      # Matches: KEY="value"  KEY='value'  KEY=value  (no spaces around =)
      SCALAR_RE = /^[ \t]*([A-Za-z_][A-Za-z0-9_]*)[ \t]*=[ \t]*(?:"([^"\\]*)"|'([^'\\]*)'|([^\s#"']+))/
      # Matches: KEY=("a" "b")  or  KEY=('a' 'b')
      ARRAY_OPEN_RE  = /^[ \t]*([A-Za-z_][A-Za-z0-9_]*)[ \t]*=[ \t]*\(/
      DEPEND_OPEN_RE = /^[ \t]*depend\s*\(\s*\)\s*\{?/
      HOOK_RE        = /^[ \t]*(pre_start|post_start|pre_stop|post_stop|reload|healthcheck)\s*\(\s*\)/
      CGROUP_PREFIX  = "cgroup_"

      def self.parse_file(path : String) : ServiceDefinition
        new(path).parse
      end

      def initialize(@path : String)
        @def = ServiceDefinition.new
        @def.source_path = @path
        @lines = [] of String
        @depend_lines = [] of String
      end

      def parse : ServiceDefinition
        raise ParseError.new("not found: #{@path}") unless File.exists?(@path)
        @lines = File.read_lines(@path)

        extract_depend_body
        process_lines

        if @def.name.empty?
          # Derive name from directory name (preferred) or filename.
          parent = File.basename(File.dirname(@path))
          @def.name = if parent == "." || parent.empty?
                        File.basename(@path, ".sh")
                      else
                        parent
                      end
        end

        @def
      end

      # -----------------------------------------------------------------------
      # Pass 1: pull out the depend() block
      # -----------------------------------------------------------------------

      private def extract_depend_body
        in_block = false
        depth = 0

        @lines.each do |raw|
          line = raw.strip

          unless in_block
            if line.match(DEPEND_OPEN_RE)
              in_block = true
              # Count any braces on the same opening line.
              depth = line.count('{') - line.count('}')
              depth = 1 if depth <= 0 # implicit: depend() { on next line
            end
            next
          end

          # Inside the block.
          depth += line.count('{') - line.count('}')
          if depth <= 0
            in_block = false
          else
            @depend_lines << line unless line.empty? || line.starts_with?('#')
          end
        end
      end

      # -----------------------------------------------------------------------
      # Pass 2: process all lines for scalars, arrays, and hook flags
      # -----------------------------------------------------------------------

      private def process_lines
        i = 0
        while i < @lines.size
          raw = @lines[i]
          line = raw.strip

          i += 1
          next if line.empty? || line.starts_with?('#')

          # Hook function definitions.
          if m = line.match(HOOK_RE)
            record_hook(m[1])
            next
          end

          # Array variable assignment spanning possibly multiple lines.
          if m = line.match(ARRAY_OPEN_RE)
            key = m[1]
            # Collect everything from the '(' to the matching ')'.
            raw_arr, lines_consumed = collect_array(@lines, i - 1)
            i += lines_consumed
            apply_array(key, raw_arr)
            next
          end

          # Scalar assignment.
          if m = line.match(SCALAR_RE)
            apply_scalar(m[1], m[2]? || m[3]? || m[4]? || "")
          end
        end

        parse_depend_body
      end

      # Collect characters from the '(' through the matching ')' across lines.
      # Returns [collected_string, extra_lines_consumed].
      private def collect_array(lines : Array(String), start_idx : Int32) : {String, Int32}
        buf = String::Builder.new
        depth = 0
        extra = 0

        lines[start_idx..].each_with_index do |raw, offset|
          raw.each_char do |ch|
            case ch
            when '(' then depth += 1
            when ')' then depth -= 1
            end
            buf << ch
            return {buf.to_s, offset} if depth == 0
          end
          buf << '\n'
          extra = offset + 1
        end

        {buf.to_s, extra}
      end

      private def apply_array(key : String, raw : String)
        case key
        when "environment"
          Parser.parse_array_value(raw).each { |v| @def.environment << v }
        end
        # Other array fields can be added here.
      end

      # -----------------------------------------------------------------------
      # Scalar field application
      # -----------------------------------------------------------------------

      private def apply_scalar(key : String, value : String)
        value = value.strip

        return apply_cgroup(key.lchop(CGROUP_PREFIX), value) if key.starts_with?(CGROUP_PREFIX)

        case key
        when "name"          then @def.name = value
        when "description"   then @def.description = value
        when "command"       then @def.command = value
        when "user"          then @def.user = value
        when "group"         then @def.group = value
        when "working_dir"   then @def.working_dir = value
        when "pid_file"      then @def.pid_file = value
        when "target"        then @def.target = value
        when "restart_sec"   then @def.restart_sec = value.to_i? || 5
        when "timeout_start" then @def.timeout_start = value.to_i? || 90
        when "timeout_stop"  then @def.timeout_stop = value.to_i? || 90
        when "type"
          @def.type = case value
                      when "simple"           then ServiceType::Simple
                      when "forking"          then ServiceType::Forking
                      when "oneshot"          then ServiceType::Oneshot
                      when "notify"           then ServiceType::Notify
                      when "socket-activated" then ServiceType::SocketActivated
                      else
                        warn "unknown type '#{value}' in #{@path}, defaulting to simple"
                        ServiceType::Simple
                      end
        when "restart"
          @def.restart = case value
                         when "no", "never"    then RestartPolicy::No
                         when "on-failure"     then RestartPolicy::OnFailure
                         when "always"         then RestartPolicy::Always
                         when "unless-stopped" then RestartPolicy::UnlessStopped
                         else
                           warn "unknown restart '#{value}' in #{@path}"
                           RestartPolicy::OnFailure
                         end
        when "environment"
          # Single-value form: environment="KEY=val"
          @def.environment << value unless value.empty?
          # Healthcheck configuration
        when "healthcheck_type"
          @def.healthcheck_type = value
        when "healthcheck_http_url"
          @def.healthcheck_http_url = value
        when "healthcheck_http_method"
          @def.healthcheck_http_method = value
        when "healthcheck_http_status"
          @def.healthcheck_http_status = value.to_i? || 200
        when "healthcheck_tcp_host"
          @def.healthcheck_tcp_host = value
        when "healthcheck_tcp_port"
          @def.healthcheck_tcp_port = value.to_i? || 0
        when "healthcheck_interval"
          @def.healthcheck_interval = value.to_i? || 30
        when "healthcheck_retries"
          @def.healthcheck_retries = value.to_i? || 3
        when "healthcheck_timeout"
          @def.healthcheck_timeout = value.to_i? || 5
        end
        # Unknown keys silently ignored — used only in hook bodies.
      end

      private def apply_cgroup(suffix : String, value : String)
        case suffix
        when "cpu_max"     then @def.cgroup.cpu_max = value
        when "memory_max"  then @def.cgroup.memory_max = value
        when "memory_low"  then @def.cgroup.memory_low = value
        when "pids_max"    then @def.cgroup.pids_max = value
        when "io_max"      then @def.cgroup.io_max = value
        when "cpuset_cpus" then @def.cgroup.cpuset_cpus = value
        when "oom_group"   then @def.cgroup.oom_group = (value == "1" || value == "true")
        end
      end

      private def record_hook(name : String)
        case name
        when "pre_start"   then @def.has_pre_start = true
        when "post_start"  then @def.has_post_start = true
        when "pre_stop"    then @def.has_pre_stop = true
        when "post_stop"   then @def.has_post_stop = true
        when "reload"      then @def.has_reload = true
        when "healthcheck" then @def.has_healthcheck = true
        end
      end

      # -----------------------------------------------------------------------
      # depend() body parsing
      # -----------------------------------------------------------------------

      private def parse_depend_body
        @depend_lines.each do |line|
          parts = line.split(/\s+/).reject(&.empty?)
          next if parts.size < 2

          keyword = parts[0]
          targets = parts[1..]

          kind = case keyword
                 when "require", "need" then Dependency::Kind::Require
                 when "want", "use"     then Dependency::Kind::Want
                 when "after"           then Dependency::Kind::After
                 when "before"          then Dependency::Kind::Before
                 when "conflicts"       then Dependency::Kind::Conflicts
                 when "part_of"         then Dependency::Kind::PartOf
                 else                        next
                 end

          @def.dependencies << Dependency.new(kind, targets)
        end
      end

      private def warn(msg : String)
        STDERR.puts "[litin parser] #{msg}"
      end

      # -----------------------------------------------------------------------
      # Public helper: parse shell array syntax
      # -----------------------------------------------------------------------

      # Converts  ("A=1" "B=2")  or  "A=1"  into  ["A=1", "B=2"].
      def self.parse_array_value(raw : String) : Array(String)
        s = raw.strip
        return [s] unless s.starts_with?('(')

        inner = s.lchop('(').rchop(')')
        result = [] of String
        token = String::Builder.new
        in_q = false
        q_char = '"'

        inner.each_char do |ch|
          if in_q
            if ch == q_char
              in_q = false
              t = token.to_s
              result << t unless t.empty?
              token = String::Builder.new
            else
              token << ch
            end
          elsif ch == '"' || ch == '\''
            in_q = true
            q_char = ch
          elsif ch == ' ' || ch == '\t' || ch == '\n' || ch == '\r'
            t = token.to_s
            result << t unless t.empty?
            token = String::Builder.new
          else
            token << ch
          end
        end

        t = token.to_s
        result << t unless t.empty?
        result
      end
    end

    # ==========================================================================
    # Loader — discovers and loads all service definitions from a directory tree
    # ==========================================================================

    class Loader
      SERVICES_DIR = "/etc/litin/services"
      MASKS_DIR    = "/etc/litin/masks"
      WANTS_GLOB   = "/etc/litin/targets/*.wants"

      def self.load_all(services_dir : String = SERVICES_DIR) : Array(ServiceDefinition)
        new(services_dir).load_all
      end

      def initialize(
        @services_dir : String = SERVICES_DIR,
        @masks_dir : String = MASKS_DIR,
      )
        @enabled_names = resolve_enabled_names
      end

      def load_all : Array(ServiceDefinition)
        result = [] of ServiceDefinition
        return result unless Dir.exists?(@services_dir)

        Dir.each_child(@services_dir) do |entry|
          path = File.join(@services_dir, entry)
          begin
            sdef = load_entry(path, entry)
            next unless sdef

            sdef.masked = masked?(entry)
            sdef.enabled = @enabled_names.includes?(entry)

            result << sdef
          rescue ex : ParseError
            STDERR.puts "[loader] skipping #{path}: #{ex.message}"
          rescue ex
            STDERR.puts "[loader] error loading #{path}: #{ex.class}: #{ex.message}"
          end
        end

        result.sort_by(&.name)
      end

      # -----------------------------------------------------------------------
      # Private helpers
      # -----------------------------------------------------------------------

      # Return the set of service names that are symlinked into any
      # *.wants/ directory under the targets root.
      private def resolve_enabled_names : Set(String)
        names = Set(String).new
        Dir.glob(File.join(WANTS_GLOB, "*")) do |link|
          names << File.basename(link)
        end
        names
      rescue
        Set(String).new
      end

      private def masked?(name : String) : Bool
        path = File.join(@masks_dir, name)
        return false unless File.exists?(path)
        # Masked entries are symlinks to /dev/null.
        File.symlink?(path) && File.real_path(path) == "/dev/null"
      rescue
        false
      end

      private def load_entry(path : String, name : String) : ServiceDefinition?
        if File.directory?(path)
          load_directory(path, name)
        elsif File.file?(path) && (name.ends_with?(".sh") || !name.includes?('.'))
          load_single_file(path, name)
        else
          nil
        end
      end

      # Directory-based service (preferred layout).
      #
      # Supported layouts:
      #   service.sh  — Litin-native definition (may also have run/finish)
      #   run         — Runit-compatible bare run script (no service.sh)
      #
      # Optional files in the directory:
      #   finish      — runs after service exits (Runit finish script)
      #   env/        — runit-compatible environment directory
      private def load_directory(path : String, name : String) : ServiceDefinition?
        service_sh = File.join(path, "service.sh")
        run_script = File.join(path, "run")
        finish_sh = File.join(path, "finish")

        sdef = if File.exists?(service_sh)
                 d = Parser.parse_file(service_sh)
                 d.name = name if d.name.empty?
                 d
               elsif File.exists?(run_script)
                 # Runit-style: synthesise a minimal definition.
                 d = ServiceDefinition.new
                 d.name = name
                 d.source_path = run_script
                 d.restart = RestartPolicy::Always # Runit default
                 d
               else
                 return nil
               end

        sdef.run_script = run_script if File.exists?(run_script) && File.executable?(run_script)
        sdef.finish_script = finish_sh if File.exists?(finish_sh) && File.executable?(finish_sh)
        sdef.source_path = path # point to the directory, not the script

        sdef
      end

      private def load_single_file(path : String, name : String) : ServiceDefinition?
        sdef = Parser.parse_file(path)
        sdef.name = File.basename(name, ".sh") if sdef.name.empty?
        sdef
      end
    end
  end
end
