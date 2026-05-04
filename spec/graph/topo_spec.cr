# spec/graph/topo_spec.cr
#
# Focused tests for the topological sort correctness.
# Uses anonymous ServiceDefinition objects to keep fixtures small.

require "spec"
require "../../src/config/service_definition"
require "../../src/graph/dependency"

module Litin::Graph
  # Helper: build a minimal ServiceDefinition with explicit require/after deps.
  def self.svc(name : String, requires : Array(String) = [] of String,
               after : Array(String) = [] of String,
               before : Array(String) = [] of String,
               conflicts : Array(String) = [] of String) : Config::ServiceDefinition
    s = Config::ServiceDefinition.new
    s.name = name
    s.command = "/bin/true"
    requires.each { |d| s.dependencies << Config::Dependency.new(Config::Dependency::Kind::Require, [d]) }
    after.each { |d| s.dependencies << Config::Dependency.new(Config::Dependency::Kind::After, [d]) }
    before.each { |d| s.dependencies << Config::Dependency.new(Config::Dependency::Kind::Before, [d]) }
    conflicts.each { |d| s.dependencies << Config::Dependency.new(Config::Dependency::Kind::Conflicts, [d]) }
    s
  end

  def self.build(sdefs : Array(Config::ServiceDefinition)) : DependencyGraph
    g = DependencyGraph.new
    g.add_all(sdefs)
    g
  end

  describe DependencyGraph do
    describe "#start_order" do
      it "single independent node produces one wave" do
        g = build([svc("a")])
        waves = g.start_order
        waves.size.should eq(1)
        waves[0].should eq(["a"])
      end

      it "three independent nodes produce one wave" do
        g = build([svc("a"), svc("b"), svc("c")])
        waves = g.start_order
        waves.size.should eq(1)
        waves[0].sort.should eq(["a", "b", "c"])
      end

      it "linear chain: a <- b <- c produces three sequential waves" do
        g = build([
          svc("a"),
          svc("b", requires: ["a"]),
          svc("c", requires: ["b"]),
        ])
        order = g.start_order.flatten
        order.index("a").not_nil!.should be < order.index("b").not_nil!
        order.index("b").not_nil!.should be < order.index("c").not_nil!
      end

      it "diamond dependency: a <- b, a <- c, b <- d, c <- d" do
        # d depends on both b and c; b and c both depend on a.
        # Expected: wave1=[a], wave2=[b,c], wave3=[d]
        g = build([
          svc("a"),
          svc("b", requires: ["a"]),
          svc("c", requires: ["a"]),
          svc("d", requires: ["b", "c"]),
        ])
        waves = g.start_order
        order = waves.flatten

        order.index("a").not_nil!.should be < order.index("b").not_nil!
        order.index("a").not_nil!.should be < order.index("c").not_nil!
        order.index("b").not_nil!.should be < order.index("d").not_nil!
        order.index("c").not_nil!.should be < order.index("d").not_nil!

        # b and c must be in the same wave (both depend only on a).
        b_wave = waves.index { |w| w.includes?("b") }
        c_wave = waves.index { |w| w.includes?("c") }
        b_wave.should eq(c_wave)
      end

      it "before constraint is honoured without require" do
        # x must start before y (ordering only, no readiness dependency).
        g = build([
          svc("x", before: ["y"]),
          svc("y"),
        ])
        order = g.start_order.flatten
        order.index("x").not_nil!.should be < order.index("y").not_nil!
      end

      it "after constraint is honoured without require" do
        g = build([
          svc("p"),
          svc("q", after: ["p"]),
        ])
        order = g.start_order.flatten
        order.index("p").not_nil!.should be < order.index("q").not_nil!
      end

      it "stop_order is the strict reverse of start_order" do
        g = build([
          svc("a"),
          svc("b", requires: ["a"]),
          svc("c", requires: ["b"]),
        ])
        start = g.start_order.flatten
        stop = g.stop_order.flatten
        stop.should eq(start.reverse)
      end

      it "raises CycleError on a two-node cycle" do
        g = build([
          svc("x", requires: ["y"]),
          svc("y", requires: ["x"]),
        ])
        expect_raises(CycleError) { g.start_order }
      end

      it "raises CycleError on a three-node cycle" do
        g = build([
          svc("a", requires: ["c"]),
          svc("b", requires: ["a"]),
          svc("c", requires: ["b"]),
        ])
        expect_raises(CycleError) { g.start_order }
      end

      it "cycle error message contains the cycle nodes" do
        g = build([
          svc("x", requires: ["y"]),
          svc("y", requires: ["x"]),
        ])
        ex = expect_raises(CycleError) { g.start_order }
        ex.message.not_nil!.should contain("x")
        ex.message.not_nil!.should contain("y")
      end

      it "handles a ten-node chain without O(n^2) degeneration" do
        nodes = (0...10).map { |i| svc("s#{i}", requires: i > 0 ? ["s#{i - 1}"] : [] of String) }
        g = build(nodes)
        order = g.start_order.flatten
        (0...10).each do |i|
          order.index("s#{i}").should eq(i)
        end
      end

      it "ignores dependency on unknown service without error" do
        g = build([svc("a", requires: ["phantom"])])
        waves = g.start_order
        waves.flatten.should contain("a")
      end

      it "produces correct waves for a mixed graph" do
        # boot <- network <- sshd
        # boot <- localfs <- nginx
        # nginx also requires network
        g = build([
          svc("boot"),
          svc("network", requires: ["boot"]),
          svc("localfs", requires: ["boot"]),
          svc("sshd", requires: ["network"]),
          svc("nginx", requires: ["network", "localfs"]),
        ])
        order = g.start_order.flatten

        order.index("boot").not_nil!.should be < order.index("network").not_nil!
        order.index("boot").not_nil!.should be < order.index("localfs").not_nil!
        order.index("network").not_nil!.should be < order.index("sshd").not_nil!
        order.index("network").not_nil!.should be < order.index("nginx").not_nil!
        order.index("localfs").not_nil!.should be < order.index("nginx").not_nil!
      end
    end

    describe "#required_by" do
      it "returns transitive hard dependencies" do
        g = build([
          svc("a"),
          svc("b", requires: ["a"]),
          svc("c", requires: ["b"]),
        ])
        deps = g.required_by("c").sort
        deps.should contain("a")
        deps.should contain("b")
        deps.should_not contain("c")
      end

      it "returns empty for a node with no deps" do
        g = build([svc("standalone")])
        g.required_by("standalone").should be_empty
      end

      it "returns empty for an unknown node" do
        g = build([svc("a")])
        g.required_by("unknown").should be_empty
      end
    end

    describe "#dependents_of" do
      it "returns direct hard dependents" do
        g = build([
          svc("network"),
          svc("sshd", requires: ["network"]),
          svc("nginx", requires: ["network"]),
        ])
        deps = g.dependents_of("network").sort
        deps.should contain("sshd")
        deps.should contain("nginx")
      end

      it "does not include soft (want/after) dependents" do
        g = build([
          svc("logger"),
          svc("sshd", after: ["logger"]),
        ])
        g.dependents_of("logger").should be_empty
      end
    end

    describe "#conflicts_for" do
      it "is symmetric" do
        g = build([
          svc("sshd", conflicts: ["dropbear"]),
          svc("dropbear"),
        ])
        g.conflicts_for("sshd").should contain("dropbear")
        g.conflicts_for("dropbear").should contain("sshd")
      end

      it "returns empty for unknown service" do
        g = build([svc("a")])
        g.conflicts_for("unknown").to_a.should be_empty
      end
    end

    describe "#to_dot" do
      it "produces valid DOT syntax" do
        g = build([svc("a"), svc("b", requires: ["a"])])
        dot = g.to_dot
        dot.should start_with("digraph litin")
        dot.should contain("\"a\"")
        dot.should contain("\"b\"")
        dot.should contain("->")
        dot.should end_with("}\n")
      end

      it "highlights the named node" do
        g = build([svc("a"), svc("b")])
        dot = g.to_dot(highlight: "a")
        dot.should contain("b3d9ff")
      end
    end
  end
end
