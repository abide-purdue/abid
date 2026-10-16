require 'uri'

# Builds a driver's pickup order and a Google Maps link.
#
# Deliberately has no route optimiser. Drivers navigate with their own phone
# regardless, Google geocodes free-text addresses client-side (better than
# Nominatim, and free), and the alternative was OSRM's public demo server —
# rate-limited, unsupported, and explicitly not for production. A sensible
# order plus a working link beats an optimal order that 429s on a Sunday
# morning.
class RoutePlanner
  # Google's directions URL API caps intermediate waypoints.
  MAX_WAYPOINTS = 9

  Stop = Struct.new(:kind, :ride_id, :name, :label, :address, :lat, :lon, keyword_init: true) do
    def coords?
      lat.present? && lon.present?
    end

    # A street address first. It is what a driver can read aloud, check against
    # a building sign, and recognise as somewhere real — "40.428813,-86.912233"
    # is none of those, and Google resolves an address to the entrance rather
    # than to whichever rooftop point we geocoded.
    #
    # Coordinates remain the fallback, and they are not a lesser answer: for a
    # bare street or a complex with no single door they are the only honest
    # one. Better an exact point on Vine Street than a house number nobody
    # gave us.
    def maps_token
      return address if address.present?
      return format('%.6f,%.6f', lat.to_f, lon.to_f) if coords?

      label.to_s
    end
  end

  Plan = Struct.new(:stops, :maps_url, :truncated, keyword_init: true) do
    def pickups
      stops.select { |s| s.kind == :pickup }
    end

    def destination
      stops.find { |s| s.kind == :destination }
    end
  end

  def initialize(car, event:)
    @car = car
    @event = event
  end

  def call
    stops = pickup_stops
    destination = destination_stop
    all = destination ? stops + [destination] : stops

    Plan.new(
      stops: all,
      maps_url: maps_url(all),
      truncated: stops.size > MAX_WAYPOINTS
    )
  end

  private

  # The optimizer's order when it has run (rides.pickup_position), else zone
  # then name. Both deterministic on purpose: the same board must produce the
  # same order every time. (The digest is order-insensitive, so this ordering
  # is presentation, not state — but a DM that reshuffles between two renders
  # of the same roster would still read as caprice.)
  def pickup_stops
    return meeting_stops if @car.ride.meet_at_pickup

    @car.passengers
        .reject(&:riding_from_the_start?)
        .sort_by { |p| [p.pickup_position || 1 << 30, Location::ZONES.index(p.zone.to_s) || 99, p.display_name.to_s.downcase] }
        .map do |passenger|
          Stop.new(
            kind: :pickup,
            ride_id: passenger.id,
            name: passenger.display_name,
            label: passenger.address.presence || passenger.display_name,
            # Free text the coordinator typed wins over the location's own
            # address: "Hillenbrand, north door" and "Wiley, apt 412" are
            # corrections to where the pin sits, and overriding them with the
            # building's generic street number throws that knowledge away.
            address: passenger.pickup_maps_query,
            lat: passenger.pickup&.lat,
            lon: passenger.pickup&.lon
          )
        end
  end

  # Riders walk to a meeting-point vehicle, so every stop IS the vehicle's own
  # spot — the maps dedup collapses them to one waypoint, and the DM reads
  # "meets at Windsor Halls" beside each name instead of a class building the
  # van was never going to visit.
  def meeting_stops
    spot = @car.ride.pickup
    label = spot ? "meets at the #{spot.name}" : 'meets at the car'

    @car.passengers.sort_by { |p| p.display_name.to_s.downcase }.map do |passenger|
      Stop.new(
        kind: :pickup, ride_id: passenger.id, name: passenger.display_name,
        label: label, address: spot&.maps_query,
        lat: spot&.lat, lon: spot&.lon
      )
    end
  end

  def destination_stop
    location = @event.location
    return nil if location.nil?

    Stop.new(kind: :destination, ride_id: nil, name: location.name,
             label: location.name, address: location.maps_query,
             lat: location.lat, lon: location.lon)
  end

  # origin = first pickup, destination = the venue, everything else a waypoint.
  # The driver's own start is deliberately not included: most drivers have no
  # address on file, and their phone already knows where they are.
  def maps_url(stops)
    return nil if stops.size < 2

    # Two riders at the same address is one stop for the driver, not two — but
    # only the pickups may be collapsed. Deduping the whole list drops the
    # destination whenever someone is collected from the venue itself, which
    # silently reroutes the driver to a rider's flat.
    destination = stops.last
    pickups = stops[0..-2].uniq(&:maps_token)
    return nil if pickups.empty?

    origin = pickups.first
    waypoints = pickups[1..].to_a.first(MAX_WAYPOINTS)

    query = {
      api: 1,
      origin: origin.maps_token,
      destination: destination.maps_token,
      travelmode: 'driving'
    }
    query[:waypoints] = waypoints.map(&:maps_token).join('|') if waypoints.any?

    URI::HTTPS.build(host: 'www.google.com', path: '/maps/dir/',
                     query: URI.encode_www_form(query)).to_s
  end
end
