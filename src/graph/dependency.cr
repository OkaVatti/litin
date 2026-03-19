# src/graph/dependency.cr
#
# Dependency graph for Litin services.
#
# The graph is directed: an edge from A to B means "A must start after B"
# (i.e. A depends on B).  The adjacency map @adj[name] is the set of
# names that `name` directly depends on.
#
# Topological sort (Kahn's algorithm):
#   1. Compute in-degree[n] = number of services that depend on n
#      (i.e. how many entries in @adj point TO n, not the size of @adj[n]).
#   2. Seed the ready queue with nodes whose in-degree is 0.
#   3. Each iteration: emit all currently-ready nodes as one StartWave,
#      then decrement the in-degree of every node that had an edge INTO
#      an emitted node.  New zero-in-degree nodes join the next wave.
#
# "in-degree" here means "how many other nodes are waiting on me to
# finish so they can start" — equivalently, how many OUTGOING edges
# from OTHER nodes point to me.  A node with in-degree 0 has no
# dependents blocking it, so it can start immediately.
#
# Wait — we want start ORDER, not "who am I blocking".  Let's be precise:
#   pending[n]  = number of n's direct dependencies still unresolved.
#   A node is "ready" when pending[n] == 0 (all its deps are resolved).
#   @adj[n]     = { things n waits for } (outgoing from n).
#   pending[n]  = @adj[n].size initially.
#
# When a wave is emitted (resolved), for every resolved node r we scan
# all other nodes and decrement pending[x] for any x where r ∈ @adj[x].
# Nodes that reach pending == 0 join the next wave.

require "../config/service_definition"

module Litin
  module Graph
    class CycleError < Exception
      getter cycle : Array(String)

      def initialize(@cycle)
        super("dependency cycle: #{cycle.join(" -> ")}")
      end
    end

    alias StartWave = Array(String)

    class DependencyGraph
      getter nodes : Hash(String, Config::ServiceDefinition)

      def initialize
        @nodes = {} of String => Config::ServiceDefinition
        # @adj[n] = set of service names that n directly depends on.
        @adj = {} of String => Set(String)
        # @conflicts[n] = set of service names that conflict with n.
        @conflicts = {} of String => Set(String)
      end

      def add(sdef : Config::ServiceDefinition) : Nil
        name = sdef.name
        @nodes[name] = sdef
        @adj[name] ||= Set(String).new
        @conflicts[name] ||= Set(String).new
      end

      def add_all(sdefs : Array(Config::ServiceDefinition)) : Nil
        sdefs.each { |s| add(s) }
        build_edges
      end

      # Rebuild the edge sets from the current node definitions.
      # Safe to call more than once (e.g. after daemon reload).
      def build_edges : Nil
        # Clear existing edges; keep the node map.
        @nodes.each_key { |n| @adj[n] = Set(String).new; @conflicts[n] = Set(String).new }

        @nodes.each do |name, sdef|
          # after_names returns require + want + after deps — all ordering constraints.
          sdef.after_names.each do |dep|
            next unless @nodes.has_key?(dep)
            @adj[name] << dep # name must start after dep
          end

          # before: dep must start after name  ⟹  add dep→name edge.
          sdef.before_names.each do |dep|
            next unless @nodes.has_key?(dep)
            @adj[dep] << name # dep must start after name
          end

          # Conflicts are symmetric.
          sdef.conflicts_with.each do |dep|
            next unless @nodes.has_key?(dep)
            @conflicts[name] << dep
            @conflicts[dep] << name
          end
        end
      end

      def conflicts_for(name : String) : Set(String)
        @conflicts[name]? || Set(String).new
      end

      # -----------------------------------------------------------------------
      # Topological sort — Kahn's algorithm with wave parallelism
      # -----------------------------------------------------------------------

      # Returns an ordered list of StartWaves.  Each wave is a set of
      # service names that can be started in parallel.  All services in
      # wave N have their dependencies satisfied by waves 0..N-1.
      #
      # Raises CycleError if the graph contains a cycle.
      def start_order : Array(StartWave)
        # pending[n] = number of direct dependencies of n not yet resolved.
        pending = {} of String => Int32
        @nodes.each_key { |n| pending[n] = (@adj[n]? || Set(String).new).size }

        # Build a reverse map: rev[dep] = set of nodes that directly depend on dep.
        rev = {} of String => Set(String)
        @nodes.each_key { |n| rev[n] = Set(String).new }
        @adj.each do |name, deps|
          deps.each do |dep|
            rev[dep] ||= Set(String).new
            rev[dep] << name
          end
        end

        waves = [] of StartWave
        resolved = Set(String).new
        ready = pending.select { |_, v| v == 0 }.keys.sort

        until ready.empty?
          wave = ready.sort
          waves << wave
          wave.each { |n| resolved << n }

          # For every node resolved in this wave, decrement the pending
          # count of every node that was waiting on it.
          next_ready = [] of String
          wave.each do |resolved_node|
            (rev[resolved_node]? || Set(String).new).each do |dependent|
              next if resolved.includes?(dependent)
              pending[dependent] -= 1
              if pending[dependent] == 0
                next_ready << dependent unless next_ready.includes?(dependent)
              end
            end
          end
          ready = next_ready.sort
        end

        # Any node still not in resolved is part of a cycle.
        unresolved = @nodes.keys.reject { |n| resolved.includes?(n) }
        unless unresolved.empty?
          raise CycleError.new(find_cycle(unresolved))
        end

        waves
      end

      # Stop order is the reverse of start order.
      def stop_order : Array(StartWave)
        start_order.reverse
      end

      # -----------------------------------------------------------------------
      # Transitive dependency helpers
      # -----------------------------------------------------------------------

      # Returns the set of service names that `name` transitively requires
      # (hard dependencies only, BFS).
      def required_by(name : String) : Array(String)
        return [] of String unless @nodes.has_key?(name)

        visited = Set(String).new
        queue = [name]

        while svc = queue.shift?
          next if visited.includes?(svc)
          visited << svc
          (@nodes[svc]?.try(&.requires) || [] of String).each do |dep|
            queue << dep if @nodes.has_key?(dep) && !visited.includes?(dep)
          end
        end

        visited.delete(name)
        visited.to_a.sort
      end

      # Returns all services that have a hard dependency on `name`.
      def dependents_of(name : String) : Array(String)
        @nodes.each_with_object([] of String) do |(n, sdef), acc|
          acc << n if sdef.requires.includes?(name)
        end.sort
      end

      # -----------------------------------------------------------------------
      # Cycle detection (DFS, for error reporting only)
      # -----------------------------------------------------------------------

      private def find_cycle(suspects : Array(String)) : Array(String)
        visited = Set(String).new
        rec_stack = [] of String

        suspects.each do |start|
          next if visited.includes?(start)
          cycle = dfs_cycle(start, visited, rec_stack)
          return cycle unless cycle.empty?
        end

        suspects
      end

      private def dfs_cycle(
        node : String,
        visited : Set(String),
        rec_stack : Array(String),
      ) : Array(String)
        visited << node
        rec_stack << node

        (@adj[node]? || Set(String).new).each do |dep|
          if !visited.includes?(dep)
            result = dfs_cycle(dep, visited, rec_stack)
            return result unless result.empty?
          elsif rec_stack.includes?(dep)
            idx = rec_stack.index(dep).not_nil!
            return rec_stack[idx..] + [dep]
          end
        end

        rec_stack.pop
        [] of String
      end

      # -----------------------------------------------------------------------
      # DOT graph export
      # -----------------------------------------------------------------------

      def to_dot(highlight : String? = nil) : String
        io = String::Builder.new
        io << "digraph litin {\n"
        io << "  rankdir=LR;\n"
        io << "  node [shape=box, style=filled, fontname=\"sans-serif\"];\n"

        @nodes.each_key do |name|
          colour = name == highlight ? "\"#b3d9ff\"" : "\"#f5f5f5\""
          io << "  \"#{name}\" [fillcolor=#{colour}];\n"
        end

        @adj.each do |from, deps|
          deps.each { |dep| io << "  \"#{from}\" -> \"#{dep}\";\n" }
        end

        # Conflict edges (dashed red, bidirectional).
        seen = Set(String).new
        @conflicts.each do |a, bs|
          bs.each do |b|
            pair = [a, b].sort.join(":")
            next if seen.includes?(pair)
            seen << pair
            io << "  \"#{a}\" -> \"#{b}\" [style=dashed, color=red, dir=both];\n"
          end
        end

        io << "}\n"
        io.to_s
      end
    end
  end
end
