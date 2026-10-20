# frozen_string_literal: true

module HealthChecks
  # The in-page integrity audit compares loaded modules against the Propshaft
  # manifest; an empty manifest makes every page report a mismatch.
  class IntegrityManifestCheck < Check
    include IntegrityHelper

    def call
      JSON.parse(integrity_manifest_json).any? ? Result.ok : Result.down("manifest_missing")
    end
  end
end
