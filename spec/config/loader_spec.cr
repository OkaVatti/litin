# spec/config/loader_spec.cr
#
# Integration tests for Config::Loader.

require "spec"
require "file_utils"
require "../../src/config/parser"

module Litin::Config
  # Helpers at module level — Crystal does not allow def inside describe blocks.

  private def self.make_service_dir(
    base_dir : String,
    name : String,
    content : String,
    enabled : Bool = false,
    wants_dir : String? = nil,
  ) : String
    svc_dir = File.join(base_dir, name)
    Dir.mkdir_p(svc_dir)
    File.write(File.join(svc_dir, "service.sh"), content)

    if enabled && (wd = wants_dir)
      Dir.mkdir_p(wd)
      link = File.join(wd, name)
      File.symlink(File.join(svc_dir, "service.sh"), link) unless File.exists?(link)
    end

    svc_dir
  end

  describe Loader do
    it "loads a directory-based service" do
      base = File.tempname("litin-loader-test")
      Dir.mkdir_p(base)

      begin
        make_service_dir(base, "nginx", <<-SH)
          name="nginx"
          description="Nginx web server"
          command="/usr/sbin/nginx -g 'daemon off;'"
          type="simple"
          restart="on-failure"
          cgroup_memory_max="256M"
          depend() {
            require network
          }
        SH

        sdefs = Loader.load_all(base)
        sdefs.size.should eq(1)
        s = sdefs[0]
        s.name.should eq("nginx")
        s.description.should eq("Nginx web server")
        s.type.should eq(ServiceType::Simple)
        s.restart.should eq(RestartPolicy::OnFailure)
        s.cgroup.memory_max.should eq("256M")
        s.requires.should contain("network")
      ensure
        FileUtils.rm_rf(base)
      end
    end

    it "loads a Runit-style run-only directory" do
      base = File.tempname("litin-loader-runit")
      Dir.mkdir_p(base)

      begin
        svc_dir = File.join(base, "myapp")
        Dir.mkdir_p(svc_dir)
        run_path = File.join(svc_dir, "run")
        File.write(run_path, "#!/bin/sh\nexec /usr/bin/myapp\n")
        File.chmod(run_path, 0o755)

        sdefs = Loader.load_all(base)
        sdefs.size.should eq(1)
        s = sdefs[0]
        s.name.should eq("myapp")
        s.run_script.should eq(run_path)
        s.restart.should eq(RestartPolicy::Always)
      ensure
        FileUtils.rm_rf(base)
      end
    end

    it "loads a single .sh file service" do
      base = File.tempname("litin-loader-sh")
      Dir.mkdir_p(base)

      begin
        File.write(File.join(base, "cron.sh"), <<-SH)
          name="cron"
          command="/usr/sbin/cron -f"
          type="simple"
        SH

        sdefs = Loader.load_all(base)
        sdefs.size.should eq(1)
        sdefs[0].name.should eq("cron")
      ensure
        FileUtils.rm_rf(base)
      end
    end

    it "skips non-service entries" do
      base = File.tempname("litin-loader-skip")
      Dir.mkdir_p(base)

      begin
        File.write(File.join(base, "README.txt"), "not a service")
        Dir.mkdir_p(File.join(base, "empty_dir"))
        make_service_dir(base, "sshd", %(name="sshd"\ncommand="/usr/sbin/sshd -D"\n))

        sdefs = Loader.load_all(base)
        sdefs.map(&.name).should eq(["sshd"])
      ensure
        FileUtils.rm_rf(base)
      end
    end

    it "marks masked services" do
      base = File.tempname("litin-loader-mask")
      masks = File.tempname("litin-loader-masks")
      Dir.mkdir_p(base)
      Dir.mkdir_p(masks)

      begin
        make_service_dir(base, "nginx", %(name="nginx"\ncommand="/usr/sbin/nginx"\n))
        File.symlink("/dev/null", File.join(masks, "nginx"))

        loader = Loader.new(base, masks)
        sdefs = loader.load_all
        sdefs[0].masked.should be_true
      ensure
        FileUtils.rm_rf(base)
        FileUtils.rm_rf(masks)
      end
    end

    it "resolves enabled status from wants symlinks" do
      base = File.tempname("litin-loader-enabled")
      targets = File.tempname("litin-loader-targets")
      wants = File.join(targets, "default.wants")
      Dir.mkdir_p(base)
      Dir.mkdir_p(wants)

      begin
        svc_dir = make_service_dir(base, "sshd", %(name="sshd"\ncommand="/usr/sbin/sshd -D"\n))
        svc_file = File.join(svc_dir, "service.sh")
        File.symlink(svc_file, File.join(wants, "sshd"))

        loader = Loader.new(base)
        sdefs = loader.load_all
        sdefs.size.should eq(1)
        sdefs[0].name.should eq("sshd")
      ensure
        FileUtils.rm_rf(base)
        FileUtils.rm_rf(targets)
      end
    end

    it "parses environment=() arrays" do
      base = File.tempname("litin-loader-env")
      Dir.mkdir_p(base)

      begin
        make_service_dir(base, "webapp", <<-SH)
          name="webapp"
          command="/usr/bin/webapp"
          environment=("PORT=8080" "LOG_LEVEL=info" "DATABASE_URL=postgres://localhost/db")
        SH

        sdefs = Loader.load_all(base)
        s = sdefs[0]
        s.environment.should contain("PORT=8080")
        s.environment.should contain("LOG_LEVEL=info")
        s.environment.should contain("DATABASE_URL=postgres://localhost/db")
      ensure
        FileUtils.rm_rf(base)
      end
    end

    it "loads a service with a finish script" do
      base = File.tempname("litin-loader-finish")
      Dir.mkdir_p(base)

      begin
        svc_dir = File.join(base, "worker")
        Dir.mkdir_p(svc_dir)
        File.write(File.join(svc_dir, "service.sh"), %(name="worker"\ncommand="/usr/bin/worker"\n))
        finish = File.join(svc_dir, "finish")
        File.write(finish, "#!/bin/sh\necho done\n")
        File.chmod(finish, 0o755)

        sdefs = Loader.load_all(base)
        sdefs[0].finish_script.should eq(finish)
      ensure
        FileUtils.rm_rf(base)
      end
    end

    it "survives a parse error in one service without aborting others" do
      base = File.tempname("litin-loader-error")
      Dir.mkdir_p(base)

      begin
        bad = File.join(base, "broken")
        Dir.mkdir_p(bad)
        File.write(File.join(bad, "service.sh"), "this is not valid but also not a crash\n")
        make_service_dir(base, "good", %(name="good"\ncommand="/usr/bin/good"\n))

        sdefs = Loader.load_all(base)
        names = sdefs.map(&.name)
        names.should contain("good")
      ensure
        FileUtils.rm_rf(base)
      end
    end
  end
end
