# spec/spec_helper.cr
#
# Shared spec infrastructure for Litin.
#
# Included by all spec files via `require "./spec_helper"` (optional;
# most spec files require their dependencies directly).

require "spec"
require "file_utils"

# Ensure the test environment has the directories that some tests
# write into.
{% if flag?(:ci) %}
  LITIN_TEST_TMP = "/tmp/litin-test-#{Time.utc.to_unix}"
{% else %}
  LITIN_TEST_TMP = "/tmp/litin-test-#{Random.rand(99999)}"
{% end %}

Dir.mkdir_p(LITIN_TEST_TMP)

# Register a cleanup hook so temp dirs are removed after the suite.
at_exit { FileUtils.rm_rf(LITIN_TEST_TMP) rescue nil }

# Helper: create a temporary directory under LITIN_TEST_TMP.
def tmp_dir(name : String = "dir") : String
  path = File.join(LITIN_TEST_TMP, "#{name}-#{Random.rand(9999)}")
  Dir.mkdir_p(path)
  path
end

# Helper: write a minimal service file to a temp directory and return
# the path to service.sh.
def write_service(name : String, content : String) : String
  dir = tmp_dir(name)
  path = File.join(dir, "service.sh")
  File.write(path, content)
  path
end
