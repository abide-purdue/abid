# The DM a driver receives.
#
# Each driver only ever sees their own riders. Phone numbers and pickup
# addresses go out over Discord DMs, which is worth the fellowship knowing —
# but a driver stuck outside an apartment block at 6:15am needs a way to reach
# someone, and that is what users.phone is for.
class DriverBriefing
  def initialize(roster)
    @roster = roster # the jsonb snapshot from DispatchMessage
  end

  def to_text
    [headline, seats_line, rider_lines, with_driver_line, route_line, notes_line]
      .compact_blank
      .join("\n\n")
  end

  private

  def event
    @roster['event'] || {}
  end

  def driver
    @roster['driver'] || {}
  end

  def riders
    @roster['riders'] || []
  end

  def headline
    when_text = if event['starts_at']
                  Time.zone.parse(event['starts_at']).strftime('%A %-d %b, %-l:%M %p')
                else
                  'the next event'
                end
    "**#{event['name']}** — #{when_text}"
  end

  def seats_line
    count = riders.size
    return "You have nobody to collect for this one." if count.zero?

    seats = driver['seats']
    suffix = seats ? " (#{count} of #{seats} seats)" : ''
    "You're driving #{count} #{'person'.pluralize(count)}#{suffix}, in this order:"
  end

  def rider_lines
    return nil if riders.empty?

    riders.each_with_index.map do |rider, index|
      # `capitalize` would turn "juno wa" into "Juno wa".
      name = rider['name'].to_s.split.map(&:capitalize).join(' ')
      bits = ["#{index + 1}. #{name}"]
      bits << "(@#{rider['username']})" if rider['username'].present?
      # Not in the Discord, no phone on file: the host is how to reach them.
      bits << "(+1 of #{rider['guest_of'].to_s.split.map(&:capitalize).join(' ')})" if rider['guest_of'].present?
      bits << "— #{rider['pickup']}" if rider['pickup'].present?
      bits << "— #{rider['phone']}" if rider['phone'].present?
      line = bits.join(' ')
      line += "\n   note: #{rider['note']}" if rider['note'].present?
      line
    end.join("\n")
  end

  # A driver's own plus-ones ride from the start, so they are not a stop —
  # but they take seats, and the driver should see them counted.
  def with_driver_line
    names = @roster['with_driver'].to_a
    return nil if names.empty?

    "Riding with you from the start: #{names.join(', ')}"
  end

  def route_line
    return nil if @roster['maps_url'].blank?

    text = "Route: #{@roster['maps_url']}"
    if @roster['truncated']
      text += "\n(Google only takes #{RoutePlanner::MAX_WAYPOINTS} stops in a link — the rest are listed above.)"
    end
    text
  end

  def notes_line
    destination = event.dig('location', 'name')
    return nil if destination.blank?

    "Dropping at #{destination}."
  end
end
