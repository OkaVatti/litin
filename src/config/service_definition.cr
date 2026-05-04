# src/config/service_definition.cr
#
# ServiceDefinition holds every piece of metadata extracted from a
# Litin service file. All fields are optional at the struct level;
# the parser validates required combinations (e.g. command XOR run).
#
# This struct is intentionally pure data — no logic, no I/O.
# The supervisor and dependency graph operate on these structs.

module Litin
  module Config
    # How the supervisor decides the service is "ready".
    enum ServiceType
      Simple          # ready immediately after exec
      Forking         # ready when pid_file appears and parent exits
      Oneshot         # ready after successful exit (does not stay running)
      Notify          # ready when service writes READY=1 to notify socket
      SocketActivated # ready on first connection to its socket
    end

    # When the supervisor should restart a service after it exits.
    enum RestartPolicy
      No            # never restart
      OnFailure     # restart only on non-zero exit / signal death
      Always        # always restart
      UnlessStopped # restart unless the admin explicitly stopped it
    end

    # A single dependency declaration from the depend() function.
    struct Dependency
      enum Kind
        Require   # hard: must be ready before we start
        Want      # soft: start if available, but don't block on failure
        After     # ordering only: start after this, no readiness requirement
        Before    # ordering only: listed service starts after us
        Conflicts # mutual exclusion
        PartOf    # group membership / target membership
      end

      getter kind    : Kind
      getter targets : Array(String) # service or target names

      def initialize(@kind, @targets)
      end
    end

    # Resource limits to apply via cgroup v2.
    struct CgroupLimits
      property cpu_max     : String? # "MAX PERIOD" e.g. "20000 100000"
      property memory_max  : String?
      property memory_low  : String?
      property pids_max    : String?
      property io_max      : String?
      property cpuset_cpus : String?
      property oom_group   : Bool

      def initialize
        @oom_group = false
      end

      def any? : Bool
        !cpu_max.nil? || !memory_max.nil? || !memory_low.nil? ||
          !pids_max.nil? || !io_max.nil? || !cpuset_cpus.nil? || oom_group
      end
    end

    # The fully parsed service definition.
    class ServiceDefinition
      # --- Identity ---
      property name        : String = ""
      property description : String = ""
      property source_path : String = "" # path to service.sh or single file

      # --- Execution ---
      property command      : String?        # command string (shell-expanded at exec time)
      property run_script   : String?        # path to 'run' executable (alternative to command)
      property finish_script : String?       # path to 'finish' executable
      property user         : String?
      property group        : String?
      property working_dir  : String?
      property environment  : Array(String)  # "KEY=value" pairs
      property pid_file     : String?        # for forking type

      # --- Behaviour ---
      property type           : ServiceType   = ServiceType::Simple
      property restart        : RestartPolicy = RestartPolicy::OnFailure
      property restart_sec    : Int32         = 5
      property timeout_start  : Int32         = 90
      property timeout_stop   : Int32         = 90

      # --- Dependencies ---
      property dependencies : Array(Dependency)

      # --- Resources ---
      property cgroup : CgroupLimits

      # --- Placement ---
      property target : String = "default"

      # --- Hook presence flags ---
      # We do not store the hook bodies here; hooks are exec'd via the
      # shell at runtime. These flags tell the supervisor which hooks
      # are defined so it does not waste a subprocess call on absent ones.
      property has_pre_start   : Bool = false
      property has_post_start  : Bool = false
      property has_pre_stop    : Bool = false
      property has_post_stop   : Bool = false
      property has_reload      : Bool = false
      property has_healthcheck : Bool = false

      # --- Metadata ---
      property enabled  : Bool = false # whether symlinked into a target
      property masked   : Bool = false

      def initialize
        @environment  = [] of String
        @dependencies = [] of Dependency
        @cgroup       = CgroupLimits.new
      end

      # Returns the list of service names this definition requires (hard deps).
      def requires : Array(String)
        @dependencies
          .select { |d| d.kind == Dependency::Kind::Require }
          .flat_map(&.targets)
      end

      # Returns all names this service must start after (hard + soft + ordering).
      def after_names : Array(String)
        @dependencies
          .select { |d| d.kind.in?(Dependency::Kind::Require, Dependency::Kind::Want, Dependency::Kind::After) }
          .flat_map(&.targets)
      end

      # Returns services this service must start before.
      def before_names : Array(String)
        @dependencies
          .select { |d| d.kind == Dependency::Kind::Before }
          .flat_map(&.targets)
      end

      # Returns services this service conflicts with.
      def conflicts_with : Array(String)
        @dependencies
          .select { |d| d.kind == Dependency::Kind::Conflicts }
          .flat_map(&.targets)
      end

      def to_s(io : IO)
        io << "ServiceDefinition(#{name}, type=#{type.to_s.downcase}, restart=#{restart.to_s.downcase.gsub('_','-')}, target=#{target})"
      end

      # Validate the definition and return a list of error strings.
      # An empty return means the definition is valid.
      def validate : Array(String)
        errors = [] of String
        errors << "name is empty"                               if name.empty?
        errors << "neither command nor run_script is set"       if command.nil? && run_script.nil?
        errors << "pid_file required for type=forking"          if type == ServiceType::Forking && pid_file.nil?
        errors << "healthcheck_tcp_port must be > 0 for type=tcp" \
          if healthcheck_type == "tcp" && healthcheck_tcp_port <= 0
        errors << "healthcheck_http_url must be set for type=http" \
          if healthcheck_type == "http" && (healthcheck_http_url.nil? || healthcheck_http_url.not_nil!.empty?)
        errors << "restart_sec must be >= 0" if restart_sec < 0
        errors << "timeout_start must be > 0" if timeout_start <= 0
        errors << "timeout_stop must be > 0"  if timeout_stop <= 0
        errors
      end

      def valid? : Bool
        validate.empty?
      end
    end
  end
end