require 'uri'
require_relative 'components'

# Shared bits between the board components: link building that preserves the
# current filter/selection/tab, and the "fit" pill styling from the design.
module BoardHelpers
  include PathHelper
  # Every board link round-trips the view state so a no-JS click doesn't drop
  # the search box contents or which person is open in the rail.
  def board_url(**overrides)
    query = {
      event_id: @board.event.id,
      q: @board.query.presence,
      tab: (@tab == :roster ? 'roster' : nil),
      sel: @board.selected_ride_id,
      focus: @board.focus_ride_id
    }.merge(overrides).compact

    path("/board?#{URI.encode_www_form(query)}")
  end

  def endpoint(action)
    path("/board/#{@board.event.id}/#{action}")
  end

  # "Also booked on the other service today" — shown wherever the person is,
  # because the dispatch-bar summary at the bottom is exactly the thing you do
  # not read while dragging riders around. Symbol plus tooltip, never colour
  # alone.
  # "+1 · Anna": this person is not in the Discord and rides with Anna.
  def guest_badge(ride)
    return unless ride.guest?

    host = ride.host_ride&.display_name
    span(
      title: host ? "Plus-one of #{host} — not in the Discord; rides in #{host}'s car" : 'Plus-one — not in the Discord',
      class: 'font-mono text-[10px] font-bold text-accent bg-accent-tint rounded-[4px] px-[4px] py-[1px] flex-none'
    ) { host ? "+1 · #{host}" : '+1' }
  end

  def elsewhere_badge(ride)
    labels = @board.elsewhere_for(ride)
    return if labels.blank?

    span(
      title: "#{ride.display_name} is #{labels.join(', and ')} today",
      aria_label: "also booked: #{labels.join(', ')}",
      role: 'img',
      class: 'font-mono text-[10px] font-bold text-warn-ink bg-warn-tint rounded-[4px] px-[4px] py-[1px] flex-none cursor-help'
    ) { '2×' }
  end

  FIT_PILLS = {
    full: 'bg-ink/[.07] text-ink/70',
    closest: 'bg-ink text-ink-invert',
    space: 'bg-accent-tint text-accent'
  }.freeze

  FIT_LABELS = {
    full: 'full',
    closest: 'closest',
    space: 'space'
  }.freeze

  def fit_pill_class(fit)
    "font-mono text-[9.5px] font-semibold tracking-[.06em] px-[7px] py-[3px] rounded-[5px] #{FIT_PILLS[fit]}"
  end

  # A small POST form, since the board's actions are all state changes and the
  # page has to keep working when the JS hasn't loaded.
  def action_form(path, method: 'post', **fields, &block)
    form(
      method: 'post',
      action: endpoint(path),
      data_board_form: true,
      class: fields.delete(:class) || 'contents'
    ) do
      input(type: 'hidden', name: '_method', value: method) unless method == 'post'
      input(type: 'hidden', name: 'q', value: @board.query) if @board.query.present?
      input(type: 'hidden', name: 'tab', value: 'roster') if @tab == :roster
      fields.each do |name, value|
        input(type: 'hidden', name: name.to_s, value: value.to_s)
      end
      yield
    end
  end

  # --- adding the regular drivers -------------------------------------------
  #
  # Lives here so two places can render it: the empty-board copy, and the
  # Roster tab next to "Add someone" — which is where adding people belongs.
  # It used to sit in the board header too, where a row of tag buttons crowded
  # the controls a coordinator actually reaches for every week.

  def add_drivers_button
    options = @board.driver_tag_options.select { |o| o[:count].positive? }
    return untagged_hint if options.empty? && @board.untagged_driver_count.positive?
    return if options.empty? && @board.untagged_driver_count.zero?

    div(class: 'flex items-center gap-1.5 flex-wrap') do
      options.each { |option| add_tagged_button(option) }
      add_everyone_button if options.none? { |o| o[:preferred] } || options.size > 1
    end
  end

  # One button per tag, so the choice is visible rather than implied by which
  # day it happens to be. The day's own tag is the solid one; the rest are there
  # because a retreat, a one-off, or a Friday the Sunday people are covering is
  # a real problem and guessing wrong costs a round of apologetic DMs.
  #
  # The count is how many this press would ADD, not how many carry the tag —
  # otherwise pressing it twice shows the same number and the second press
  # silently does nothing.
  def add_tagged_button(option)
    action_form('drivers', class: 'contents') do
      input(type: 'hidden', name: 'tag', value: option[:tag])
      button(
        type: 'submit',
        data_confirm: "Add the #{option[:count]} #{option[:tag]} drivers to this board?",
        class: option[:preferred] ? 'board-btn-solid whitespace-nowrap' : 'board-btn whitespace-nowrap'
      ) do
        plain option[:tag]
        whitespace
        span(class: 'opacity-70') { option[:count].to_s }
      end
    end
  end

  # The escape hatch for a board whose tags do not describe who is actually
  # driving tonight.
  def add_everyone_button
    count = @board.untagged_driver_count
    return if count.zero?

    action_form('drivers', class: 'contents') do
      input(type: 'hidden', name: 'tag', value: Components::BoardShell::ALL_DRIVERS)
      button(type: 'submit', class: 'board-btn whitespace-nowrap',
             data_confirm: "Add all #{count} available drivers to this board?") do
        plain 'All drivers'
        whitespace
        span(class: 'opacity-70') { count.to_s }
      end
    end
  end

  # Zero tagged drivers is the normal state on day one, and a button that simply
  # vanishes teaches nobody anything. Say which tag is empty and where to fix it,
  # rather than silently falling back to adding everybody — that fallback is what
  # the tag exists to stop.
  def untagged_hint
    div(class: 'flex items-center gap-1.5') do
      a(
        href: path('/users?filter=drivers' + (@board.driver_tag ? "&tag=#{@board.driver_tag}" : '')),
        title: @board.driver_tag ? "no available driver is tagged #{@board.driver_tag}" : 'no driver tags yet',
        class: 'board-btn no-underline text-ink/70 whitespace-nowrap'
      ) { @board.driver_tag ? "Tag the #{@board.driver_tag} drivers" : 'Tag some drivers' }
      add_everyone_button
    end
  end

end
