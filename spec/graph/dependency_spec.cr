# spec/graph/dependency_spec.cr

require "spec"
require "../../src/config/service_definition"
require "../../src/graph/dependency"

module Litin::Graph
  # Helper: build a minimal ServiceDefinition with given name and deps.
  private def make_service(
    name : String,
    requires : Array(String) = [] of String,
    after : Array(String) = [] of String,
    before : Array(String) = [] of String,
    conflicts : Array(String) = [] of String,
  ) : Config::ServiceDefinition
    sdef = Config::ServiceDefinition.new
    sdef.name = name

    requires.each do |dep|
      sdef.dependencies << Config::Dependency.new(
        Config::Dependency::Kind::Require, [dep]
      )
    end
    after.each do |dep|
      sdef.dependencies << Config::Dependency.new(
        Config::Dependency::Kind::After, [dep]
      )
    end
    before.each do |dep|
      sdef.dependencies << Config::Dependency.new(
        Config::Dependency::Kind::Before, [dep]
      )
    end
    conflicts.each do |dep|
      sdef.dependencies << Config::Dependency.new(
        Config::Dependency::Kind::Conflicts, [dep]
      )
    end

    sdef
  end

  describe DependencyGraph do
    it "produces a single wave for independent services" do
      graph = DependencyGraph.new
      graph.add_all([
        make_service("alpha"),
        make_service("beta"),
        make_service("gamma"),
      ])
      waves = graph.start_order
      # All three have no dependencies — they can all start in wave 1.
      waves.size.should eq(1)
      waves[0].sort.should eq(["alpha", "beta", "gamma"])
    end

    it "respects a linear require chain" do
      graph = DependencyGraph.new
      graph.add_all([
        make_service("c", requires: ["b"]),
        make_service("b", requires: ["a"]),
        make_service("a"),
      ])
      waves = graph.start_order
      # a must come before b, b before c.
      first_wave = waves[0]
      second_wave = waves[1]? || [] of String
      third_wave = waves[2]? || [] of String

      first_wave.should contain("a")
      second_wave.should contain("b")
      third_wave.should contain("c")
    end

    it "raises CycleError on a cycle" do
      graph = DependencyGraph.new
      graph.add_all([
        make_service("x", requires: ["y"]),
        make_service("y", requires: ["x"]),
      ])
      expect_raises(CycleError) { graph.start_order }
    end

    it "stop_order is the reverse of start_order" do
      graph = DependencyGraph.new
      graph.add_all([
        make_service("b", requires: ["a"]),
        make_service("a"),
      ])
      start = graph.start_order.flatten
      stop = graph.stop_order.flatten
      stop.should eq(start.reverse)
    end

    it "required_by returns transitive requirements" do
      graph = DependencyGraph.new
      graph.add_all([
        make_service("nginx", requires: ["network", "localfs"]),
        make_service("network", requires: ["udev"]),
        make_service("localfs"),
        make_service("udev"),
      ])
      deps = graph.required_by("nginx").sort
      deps.should contain("network")
      deps.should contain("localfs")
      deps.should contain("udev")
    end

    it "dependents_of returns reverse dependencies" do
      graph = DependencyGraph.new
      graph.add_all([
        make_service("sshd", requires: ["network"]),
        make_service("nginx", requires: ["network"]),
        make_service("network"),
      ])
      deps = graph.dependents_of("network").sort
      deps.should contain("sshd")
      deps.should contain("nginx")
    end

    it "conflicts_for returns mutual exclusions" do
      graph = DependencyGraph.new
      graph.add_all([
        make_service("sshd", conflicts: ["dropbear"]),
        make_service("dropbear"),
      ])
      graph.conflicts_for("sshd").should contain("dropbear")
      graph.conflicts_for("dropbear").should contain("sshd")
    end

    it "to_dot produces valid DOT output" do
      graph = DependencyGraph.new
      graph.add_all([
        make_service("b", requires: ["a"]),
        make_service("a"),
      ])
      dot = graph.to_dot
      dot.should contain("digraph litin")
      dot.should contain("\"a\"")
      dot.should contain("\"b\"")
    end

    it "ignores dependencies on unknown services" do
      graph = DependencyGraph.new
      # "phantom" is not in the graph — should not raise.
      graph.add_all([
        make_service("sshd", requires: ["phantom"]),
      ])
      waves = graph.start_order
      waves.flatten.should contain("sshd")
    end
  end
end
