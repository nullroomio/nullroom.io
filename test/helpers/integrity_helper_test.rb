require "test_helper"

class IntegrityHelperTest < ActiveSupport::TestCase
  include IntegrityHelper

  # ── integrity_manifest_json ──────────────────────────────────────────

  test "returns manifest JSON when file exists" do
    # Reset class variable cache for isolation
    IntegrityHelper.class_variable_set(:@@integrity_manifest, nil)

    manifest = { "application.js" => { "digested_path" => "application-abc123.js" } }
    manifest_path = Rails.root.join("public", "assets", ".manifest.json")

    FileUtils.mkdir_p(File.dirname(manifest_path))
    File.write(manifest_path, JSON.generate(manifest))

    result = integrity_manifest_json
    assert_equal manifest, JSON.parse(result)
  ensure
    FileUtils.rm_f(manifest_path)
    IntegrityHelper.class_variable_set(:@@integrity_manifest, nil)
  end

  test "returns empty JSON object when manifest is missing" do
    IntegrityHelper.class_variable_set(:@@integrity_manifest, nil)

    manifest_path = Rails.root.join("public", "assets", ".manifest.json")
    FileUtils.rm_f(manifest_path)

    assert_equal "{}", integrity_manifest_json
  ensure
    IntegrityHelper.class_variable_set(:@@integrity_manifest, nil)
  end

  test "returns empty JSON object when manifest is malformed" do
    IntegrityHelper.class_variable_set(:@@integrity_manifest, nil)

    manifest_path = Rails.root.join("public", "assets", ".manifest.json")
    FileUtils.mkdir_p(File.dirname(manifest_path))
    File.write(manifest_path, "not valid json </script>")

    assert_equal "{}", integrity_manifest_json
  ensure
    FileUtils.rm_f(manifest_path)
    IntegrityHelper.class_variable_set(:@@integrity_manifest, nil)
  end

  # ── commit_sha ───────────────────────────────────────────────────────

  test "returns COMMIT_SHA env var when set" do
    original = ENV["COMMIT_SHA"]
    ENV["COMMIT_SHA"] = "a1b2c3d4e5f6a1b2c3d4e5f6a1b2c3d4e5f6a1b2"

    assert_equal "a1b2c3d4e5f6a1b2c3d4e5f6a1b2c3d4e5f6a1b2", commit_sha
  ensure
    original ? ENV["COMMIT_SHA"] = original : ENV.delete("COMMIT_SHA")
  end

  test "returns dev when COMMIT_SHA is not set" do
    original = ENV.delete("COMMIT_SHA")

    assert_equal "dev", commit_sha
  ensure
    ENV["COMMIT_SHA"] = original if original
  end
end
