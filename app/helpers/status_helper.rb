module StatusHelper
  STATUS_GROUPS = {
    "core" => "Core",
    "relay" => "TURN relay",
    "certificates" => "TLS certificates",
    "donations" => "Donations",
    "integrity" => "Build integrity"
  }.freeze

  STATUS_LABELS = { "ok" => "Operational", "degraded" => "Degraded", "down" => "Down" }.freeze

  def status_headline(status)
    { "ok" => "All systems operational", "degraded" => "Some systems degraded" }.fetch(status, "Major outage")
  end

  def status_groups(report)
    report["components"].group_by { |component| component["group"] }
      .sort_by { |group, _| STATUS_GROUPS.keys.index(group) || STATUS_GROUPS.size }
  end

  def status_group_title(group)
    STATUS_GROUPS.fetch(group, group.to_s.humanize)
  end

  def status_label(status)
    STATUS_LABELS.fetch(status, status.to_s.humanize)
  end

  def status_text_class(status)
    { "ok" => "text-signal-green", "degraded" => "text-amber-400" }.fetch(status, "text-red-400")
  end

  def status_dot_class(status)
    { "ok" => "bg-signal-green", "degraded" => "bg-amber-400" }.fetch(status, "bg-red-400")
  end
end
